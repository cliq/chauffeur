#!/usr/bin/env python3
"""Codex hook probe: runs the real Codex binary in `exec` mode against a local mock
Responses server (no credentials, no paid inference) and records hook payloads and
model-bound requests. Usage: codex_hook_probe.py MODE, where MODE is one of plain,
bypass, selective, selective_map, selective_merge, mixed_bypass, config_bypass or
persisted. Output goes to $PROBE_ROOT/MODE (default /tmp/chauffeur-codex-hooks)."""
import os,json,pathlib,subprocess,threading,http.server,sys
ROOT=pathlib.Path(os.environ.get('PROBE_ROOT','/tmp/chauffeur-codex-hooks'));ROOT.mkdir(parents=True,exist_ok=True)
BIN=os.environ.get('CODEX_BIN','/opt/homebrew/Caskroom/codex/0.155.1/bin/codex')
mode=sys.argv[1]; run=ROOT/mode;run.mkdir(exist_ok=True);home=run/'home';home.mkdir(exist_ok=True);work=run/'work';work.mkdir(exist_ok=True)
hook=run/'hook.py'
hook.write_text('''import sys,json,pathlib
p=json.load(sys.stdin)
with pathlib.Path(__file__).with_name("markers.jsonl").open("a") as f:f.write(json.dumps(p)+"\\n")
e=p["hook_event_name"]
if e=="PostToolUse":print(json.dumps({"hookSpecificOutput":{"hookEventName":e,"additionalContext":"CHAUFFEUR_POST_CONTEXT_73921"}}))
elif e=="Stop" and not p.get("stop_hook_active"):print(json.dumps({"decision":"block","reason":"CHAUFFEUR_STOP_CONTEXT_84732"}))
else:print("{}")
''')
requests=[]
class H(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):self.send_response(200);self.end_headers();self.wfile.write(b'{"data":[]}')
 def do_POST(self):
  body=self.rfile.read(int(self.headers.get('Content-Length',0)))
  if self.headers.get('Content-Encoding')=='zstd':
   p=subprocess.run(['/opt/homebrew/bin/zstd','-d','--stdout'],input=body,capture_output=True);body=p.stdout
  try:b=json.loads(body)
  except: b={'unparsed':body.decode(errors='replace')}
  requests.append(b);(run/'requests.json').write_text(json.dumps(requests,indent=2))
  n=len(requests)
  if n==1:item={'type':'function_call','id':'fc_probe','call_id':'call_probe','name':'exec_command','arguments':json.dumps({'cmd':'printf probe-tool','max_output_tokens':20})}
  else:item={'type':'message','id':'msg_'+str(n),'role':'assistant','status':'completed','content':[{'type':'output_text','text':'probe final '+str(n),'annotations':[]}]}
  events=[{'type':'response.created','response':{'id':'resp_'+str(n),'object':'response','status':'in_progress','output':[]}}, {'type':'response.output_item.added','output_index':0,'item':item},{'type':'response.output_item.done','output_index':0,'item':item},{'type':'response.completed','response':{'id':'resp_'+str(n),'object':'response','status':'completed','output':[item],'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}}]
  out=''.join('event: '+e['type']+'\ndata: '+json.dumps(e)+'\n\n' for e in events).encode()
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(out)));self.end_headers();self.wfile.write(out)
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),H);threading.Thread(target=server.serve_forever,daemon=True).start()
config=f'''model = "gpt-5.4"
model_provider = "probe"
[model_providers.probe]
name = "Local hook probe"
base_url = "http://127.0.0.1:{server.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
request_max_retries = 0
stream_max_retries = 0
[features]
enable_request_compression = false
shell_snapshot = false
'''
(home/'config.toml').write_text(config)
cmd=[BIN,'exec','--skip-git-repo-check','--ephemeral','--json','-C',str(work),'-s','danger-full-access']
for event in ['SessionStart','UserPromptSubmit','PostToolUse','Stop','SessionEnd']:
 cmd+=['-c',f'hooks.{event}=[{{hooks=[{{type="command",command="/usr/bin/python3 {hook}",timeout=2}}]}}]']
if mode in ['bypass','mixed_bypass']:cmd+=['--dangerously-bypass-hook-trust']
if mode=='config_bypass':cmd+=['-c','bypass_hook_trust=true']
if mode.startswith('mixed') or mode in ['selective','selective_map','selective_merge','persisted']:
 other=run/'other.py';other.write_text('import pathlib;pathlib.Path(__file__).with_name("other-marker").write_text("ran")')
 (home/'hooks.json').write_text(json.dumps({'hooks':{'PostToolUse':[{'hooks':[{'type':'command','command':'/usr/bin/python3 '+str(other)}]}]}}))
if mode=='selective_merge':
 untrusted=run/'untrusted.py';untrusted.write_text('import pathlib;pathlib.Path(__file__).with_name("untrusted-marker").write_text("ran")')
 obj=json.loads((home/'hooks.json').read_text());obj['hooks']['PostToolUse'].append({'hooks':[{'type':'command','command':'/usr/bin/python3 '+str(untrusted)}]});(home/'hooks.json').write_text(json.dumps(obj))
notify=run/'notify.py';notify.write_text('import sys,pathlib; p=pathlib.Path(__file__).with_name("markers.jsonl");p.open("a").write("NOTIFY "+sys.argv[-1]+"\\n")')
cmd+=['-c','notify=["/usr/bin/python3",'+json.dumps(str(notify))+']']
cmd+=['Run printf probe-tool once and say done.']
env={k:v for k,v in os.environ.items() if not any(s in k for s in ['TOKEN','API_KEY','CODEX','CHAUFFEUR','CLAUDE'])};env['CODEX_HOME']=str(home)
(run/'command.json').write_text(json.dumps(cmd,indent=2))
if mode in ['selective','mixed_selective','selective_map','selective_merge','persisted']:
 subprocess.run(['/usr/bin/python3',str(pathlib.Path(__file__).with_name('codex_list_hooks.py')),mode],stdout=subprocess.DEVNULL,check=True)
 hooklist=json.loads((run/'hooks-list.json').read_text())['result']['data'][0]['hooks']
 if mode=='selective_merge':
  userhook=next(h for h in hooklist if h['source']=='user' and 'other.py' in h['command'])
  with (home/'config.toml').open('a') as f:f.write('\n[hooks.state.'+json.dumps(userhook['key'])+']\ntrusted_hash='+json.dumps(userhook['currentHash'])+'\n')
 if mode in ['selective_map','selective_merge']:
  cmd[2:2]=['-c','hooks.state={'+','.join(json.dumps(h['key'])+'={trusted_hash='+json.dumps(h['currentHash'])+'}' for h in hooklist if h['source']=='sessionFlags')+'}']
 elif mode=='persisted':
  with (home/'config.toml').open('a') as f:
   for h in hooklist:
    if h['source']=='sessionFlags':f.write('\n[hooks.state.'+json.dumps(h['key'])+']\ntrusted_hash='+json.dumps(h['currentHash'])+'\n')
 else:
  for h in hooklist:
   if h['source']=='sessionFlags':cmd[2:2]=['-c','hooks.state.'+json.dumps(h['key'])+'.trusted_hash='+json.dumps(h['currentHash'])]
 (run/'command.json').write_text(json.dumps(cmd,indent=2))
try:p=subprocess.run(cmd,cwd=work,env=env,capture_output=True,text=True,timeout=35);code=p.returncode;out=p.stdout;err=p.stderr
except subprocess.TimeoutExpired as e:code='timeout';out=(e.stdout or b'').decode();err=(e.stderr or b'').decode()
(run/'stdout').write_text(out);(run/'stderr').write_text(err)
print('mode',mode,'exit',code,'requests',len(requests));print('STDOUT',out[-9000:]);print('STDERR',err[-3500:]);print('MARKERS',(run/'markers.jsonl').read_text() if (run/'markers.jsonl').exists() else 'none')
server.shutdown()
