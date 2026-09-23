#!/usr/bin/env python3
"""Codex interactive (TUI) hook probe. Starts a local mock Responses server and a
stdio MCP server, writes an isolated CODEX_HOME, runs the hooks/list trust
preflight, and prints the tmux command that launches the real Codex TUI with
Chauffeur-shaped session hooks and whole-map selective trust. No credentials and
no paid inference.

  codex_tui_probe.py setup        # writes $PROBE_ROOT/tui, starts the mock, prints launch
  codex_tui_probe.py report       # summarizes hook payloads, notify and model requests

Mock behavior, keyed on the latest user prompt text:
  contains "shell" -> one exec_command call, then a final message
  contains "mcp"   -> one call to the probe MCP tool, then a final message
  otherwise        -> a final message
"""
import json, os, pathlib, subprocess, sys, time

ROOT = pathlib.Path(os.environ.get('PROBE_ROOT', '/tmp/cxt'))
BIN = os.environ.get('CODEX_BIN', '/opt/homebrew/bin/codex')
run = ROOT / 'tui'; home = run / 'home'; work = run / 'work'
HERE = pathlib.Path(__file__).resolve().parent

HOOK = '''import sys,json,pathlib
p=json.load(sys.stdin)
with pathlib.Path(__file__).with_name("markers.jsonl").open("a") as f:f.write(json.dumps(p)+"\\n")
e=p["hook_event_name"]
if e in("PostToolUse","UserPromptSubmit"):print(json.dumps({"hookSpecificOutput":{"hookEventName":e,"additionalContext":"CHAUFFEUR_"+e.upper()+"_CONTEXT"}}))
elif e=="Stop" and not p.get("stop_hook_active"):print(json.dumps({"decision":"block","reason":"CHAUFFEUR_STOP_CONTEXT"}))
'''

MOCK = r'''import json,sys,pathlib,http.server,subprocess
run=pathlib.Path(sys.argv[1]);log=run/'requests.jsonl'
def text(item):
  return ' '.join(c.get('text','') for c in item.get('content',[]) if isinstance(c,dict))
class H(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):self.send_response(200);self.end_headers();self.wfile.write(b'{"data":[]}')
 def do_POST(self):
  body=self.rfile.read(int(self.headers.get('Content-Length',0)))
  if self.headers.get('Content-Encoding')=='zstd':body=subprocess.run(['/opt/homebrew/bin/zstd','-d','--stdout'],input=body,capture_output=True).stdout
  b=json.loads(body);items=b.get('input',[])
  with log.open('a') as f:f.write(json.dumps(b)+'\n')
  last=items[-1] if items else {}
  users=[text(i) for i in items if i.get('role')=='user' and 'hook_prompt' not in text(i) and '<environment_context>' not in text(i)]
  prompt=users[-1].lower() if users else ''
  n=sum(1 for _ in log.open())
  tools=[t.get('name') or t.get('function',{}).get('name') for t in b.get('tools',[])]
  if last.get('type') in('function_call_output','custom_tool_call_output','mcp_tool_call_output') or last.get('role')=='developer' and 'CHAUFFEUR_POSTTOOLUSE' in text(last):
    item=None
  elif 'shell' in prompt:
    item={'type':'function_call','id':'fc_%d'%n,'call_id':'call_%d'%n,'name':'exec_command','arguments':json.dumps({'cmd':'printf probe-tool','max_output_tokens':20})}
  elif 'mcp' in prompt and last.get('type')=='tool_search_output':
    # MCP tools are deferred; call the one discovery returned.
    found=json.dumps(last);(run/'tool-search-output.json').write_text(json.dumps(last,indent=2))
    ns=next((t for t in last.get('tools',[]) if t.get('type')=='namespace'),None)
    fn=(ns or {}).get('tools',[{}])[0] if ns else next((t for t in last.get('tools',[]) if t.get('type')=='function'),{})
    item={'type':'function_call','id':'fc_%d'%n,'call_id':'call_%d'%n,'name':fn.get('name','ping'),'arguments':'{}'}
    if ns: item['namespace']=ns.get('name')
  elif 'mcp' in prompt:
    item={'type':'tool_search_call','id':'ts_%d'%n,'call_id':'ts_%d'%n,'execution':'client','status':'completed','arguments':{'query':'probe ping'}}
  else: item=None
  if item is None:
    item={'type':'message','id':'msg_%d'%n,'role':'assistant','status':'completed','content':[{'type':'output_text','text':'probe reply %d'%n,'annotations':[]}]}
  ev=[{'type':'response.created','response':{'id':'resp_%d'%n,'object':'response','status':'in_progress','output':[]}},{'type':'response.output_item.added','output_index':0,'item':item},{'type':'response.output_item.done','output_index':0,'item':item},{'type':'response.completed','response':{'id':'resp_%d'%n,'object':'response','status':'completed','output':[item],'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}}]
  out=''.join('event: '+e['type']+'\ndata: '+json.dumps(e)+'\n\n' for e in ev).encode()
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(out)));self.end_headers();self.wfile.write(out)
s=http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[2]) if len(sys.argv)>2 else 0),H);(run/'port').write_text(str(s.server_port));s.serve_forever()
'''

MCP = r'''import sys,json
for line in sys.stdin:
  m=json.loads(line);i=m.get('id');meth=m.get('method')
  if meth=='initialize':r={'protocolVersion':m['params'].get('protocolVersion','2025-06-18'),'capabilities':{'tools':{}},'serverInfo':{'name':'probe','version':'1'}}
  elif meth=='tools/list':r={'tools':[{'name':'ping','description':'Probe tool; returns pong.','inputSchema':{'type':'object','properties':{}},'annotations':{'readOnlyHint':True}}]}
  elif meth=='tools/call':r={'content':[{'type':'text','text':'pong'}]}
  elif i is None:continue
  else:r={}
  sys.stdout.write(json.dumps({'jsonrpc':'2.0','id':i,'result':r})+'\n');sys.stdout.flush()
'''

def hook_flags():
    flags = []
    for event in ['SessionStart', 'UserPromptSubmit', 'PostToolUse', 'Stop', 'SessionEnd']:
        flags += ['-c', f'hooks.{event}=[{{hooks=[{{type="command",command="/usr/bin/python3 {run / "hook.py"}",timeout=2}}]}}]']
    flags += ['-c', 'notify=["/usr/bin/python3",' + json.dumps(str(run / 'notify.py')) + ']']
    return flags

def env():
    e = {k: v for k, v in os.environ.items() if not any(s in k for s in ['TOKEN', 'API_KEY', 'CODEX', 'CHAUFFEUR', 'CLAUDE'])}
    e['CODEX_HOME'] = str(home); return e

def hooks_list(flags):
    start = time.monotonic()
    p = subprocess.Popen([BIN, 'app-server', '--stdio'] + flags, cwd=work, env=env(), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    for msg in [{'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'hook_probe', 'version': '1'}, 'capabilities': {'experimentalApi': True}}},
                {'method': 'initialized'}, {'id': 2, 'method': 'hooks/list', 'params': {'cwds': [str(work)]}}]:
        p.stdin.write(json.dumps(msg) + '\n'); p.stdin.flush()
    try:
        while True:
            r = json.loads(p.stdout.readline())
            if r.get('id') == 2: return r, time.monotonic() - start
    finally: p.terminate(); p.communicate(timeout=5)

def setup():
    subprocess.run(['rm', '-rf', str(run)]); home.mkdir(parents=True); work.mkdir()
    (run / 'hook.py').write_text(HOOK); (run / 'mock.py').write_text(MOCK); (run / 'mcp.py').write_text(MCP)
    (run / 'notify.py').write_text('import sys,pathlib; pathlib.Path(__file__).with_name("markers.jsonl").open("a").write("NOTIFY "+sys.argv[-1]+"\\n")')
    (run / 'other.py').write_text('import pathlib;pathlib.Path(__file__).with_name("trusted-user-marker").open("a").write("ran\\n")')
    (run / 'untrusted.py').write_text('import pathlib;pathlib.Path(__file__).with_name("untrusted-user-marker").open("a").write("ran\\n")')
    (home / 'hooks.json').write_text(json.dumps({'hooks': {'PostToolUse': [
        {'hooks': [{'type': 'command', 'command': '/usr/bin/python3 ' + str(run / 'other.py')}]},
        {'hooks': [{'type': 'command', 'command': '/usr/bin/python3 ' + str(run / 'untrusted.py')}]}]}}))
    subprocess.Popen(['/usr/bin/python3', str(run / 'mock.py'), str(run)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    while not (run / 'port').exists(): time.sleep(0.05)
    port = (run / 'port').read_text()
    (home / 'config.toml').write_text(f'''model = "gpt-5.4"
model_provider = "probe"
[model_providers.probe]
name = "Local hook probe"
base_url = "http://127.0.0.1:{port}/v1"
wire_api = "responses"
requires_openai_auth = false
request_max_retries = 0
stream_max_retries = 0
[features]
enable_request_compression = false
shell_snapshot = false
[mcp_servers.probe]
command = "/usr/bin/python3"
args = [{json.dumps(str(run / 'mcp.py'))}]
[mcp_servers.probe.tools.ping]
approval_mode = "approve"
[projects.{json.dumps(str(work))}]
trust_level = "trusted"
[notice]
hide_full_access_warning = true
''')
    flags = hook_flags()
    listed, elapsed = hooks_list(flags)
    hooks = listed['result']['data'][0]['hooks']
    (run / 'hooks-list.json').write_text(json.dumps(listed, indent=2))
    user = next(h for h in hooks if h['source'] == 'user' and 'other.py' in h['command'])
    with (home / 'config.toml').open('a') as f:
        f.write('\n[hooks.state.' + json.dumps(user['key']) + ']\ntrusted_hash=' + json.dumps(user['currentHash']) + '\n')
    trust = 'hooks.state={' + ','.join(json.dumps(h['key']) + '={trusted_hash=' + json.dumps(h['currentHash']) + '}' for h in hooks if h['source'] == 'sessionFlags') + '}'
    cmd = [BIN, '-C', str(work), '-s', 'danger-full-access', '-a', 'never', '-c', trust] + flags
    (run / 'command.json').write_text(json.dumps(cmd, indent=2))
    (run / 'launch.sh').write_text('#!/bin/sh\n' + ' '.join("'" + a.replace("'", "'\"'\"'") + "'" for a in cmd) + ' "$@"\n')
    os.chmod(run / 'launch.sh', 0o700)
    print('hooks/list seconds', round(elapsed, 3), 'entries', [(h['source'], h['eventName'] if 'eventName' in h else h.get('event'), h.get('trustStatus')) for h in hooks])
    print('env CODEX_HOME=' + str(home), str(run / 'launch.sh'))

def report():
    for line in (run / 'markers.jsonl').read_text().splitlines():
        if line.startswith('{'):
            p = json.loads(line)
            print(p['hook_event_name'], 'source=' + str(p.get('source')), 'session=' + str(p.get('session_id')), 'turn=' + str(p.get('turn_id')), 'tool=' + str(p.get('tool_name')), 'active=' + str(p.get('stop_hook_active')))
        else:
            n = json.loads(line[7:]); print('NOTIFY thread=' + n.get('thread-id', ''), 'turn=' + n.get('turn-id', ''), 'client=' + n.get('client', ''))
    for name in ['trusted-user-marker', 'untrusted-user-marker']:
        path = run / name; print(name, path.read_text().count('ran') if path.exists() else 0)
    for i, line in enumerate((run / 'requests.jsonl').read_text().splitlines()):
        b = json.loads(line)
        seen = [(it.get('role') or it.get('type'), t) for it in b.get('input', []) for t in ['CHAUFFEUR_USERPROMPTSUBMIT_CONTEXT', 'CHAUFFEUR_POSTTOOLUSE_CONTEXT', 'CHAUFFEUR_STOP_CONTEXT'] if t in json.dumps(it)]
        print('request', i, sorted(set(seen)))

{'setup': setup, 'report': report}[sys.argv[1]]()
