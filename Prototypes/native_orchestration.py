#!/usr/bin/env python3
"""Opt-in native MCP orchestration acceptance; contacts Codex and Claude.

Uses existing authenticated profiles with isolated runtime/repositories. Private
artifacts (including fixture session grants) stay under .local. Never prints them.
"""
from datetime import datetime, timezone
import argparse
import http.client
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import time
import uuid

REPO = Path(__file__).resolve().parents[1]
os.umask(0o077)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--codex-profile', type=Path, default=Path(os.environ.get('CODEX_HOME', Path.home()/'.codex')))
parser.add_argument('--claude-profile', type=Path, default=Path(os.environ.get('CLAUDE_CONFIG_DIR', Path.home()/'.claude')))
options = parser.parse_args()
root = Path('/tmp') / ('chauffeur-native-orchestration-'+uuid.uuid4().hex[:8])
root.mkdir(mode=0o700)
artifacts = REPO / '.local/native-orchestration'
artifacts.mkdir(parents=True, exist_ok=True, mode=0o700)
(artifacts/'fixture-path.txt').write_text(str(root))
runtime = None

def uid(): return str(uuid.uuid4()).upper()
def wait(probe, label, timeout=150):
    deadline = time.monotonic()+timeout
    last = None
    while time.monotonic()<deadline:
        try:
            value = probe()
            if value: return value
        except (OSError, ValueError, AssertionError) as error:
            last = str(error)
        approve_fixture_trust()
        time.sleep(.5)
    raise AssertionError(label+' timed out'+(': '+last if last else ''))
def approve_fixture_trust():
    # The probe owns this empty checkout and these private sockets. This is test
    # setup, not an automatic trust feature in the product.
    for sock in (root/'runtime').glob('tmux*.sock'):
        listing=subprocess.run(['tmux','-S',str(sock),'list-panes','-a','-F','#{session_name}'],capture_output=True,text=True)
        if listing.returncode: continue
        for sid in listing.stdout.splitlines():
            screen=subprocess.run(['tmux','-S',str(sock),'capture-pane','-p','-t',sid],capture_output=True,text=True).stdout
            keys=None
            if '1. Yes, continue' in screen and ('trust' in screen.lower() or 'working in' in screen.lower()): keys=['Enter']
            elif 'Yes, I trust this folder' in screen and 'No, exit' in screen: keys=['Down','Enter']
            if keys:
                subprocess.run(['tmux','-S',str(sock),'send-keys','-t',sid]+keys,check=True)
                time.sleep(.3)
def call(method, params=None):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(40); connection.connect(str(root/'runtime/runtime.sock'))
        data = json.dumps({'version':1,'id':uid(),'method':method,'params':params or {}}).encode()
        connection.sendall(struct.pack('!I',len(data))+data)
        def exact(n):
            result = b''
            while len(result)<n:
                part=connection.recv(n-len(result)); assert part; result+=part
            return result
        result=json.loads(exact(struct.unpack('!I',exact(4))[0]))
        assert not result.get('error'), result.get('error')
        return result.get('result')
def tool(token,name,args=None):
    connection=http.client.HTTPConnection('127.0.0.1',json.loads((root/'runtime/mcp-port.json').read_text()),timeout=40)
    connection.request('POST','/mcp',json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':name,'arguments':args or {}}}),{'Content-Type':'application/json','Accept':'application/json, text/event-stream','Authorization':'Bearer '+token})
    response=connection.getresponse(); body=json.loads(response.read()); connection.close()
    result=body['result']; assert not result.get('isError'), result
    return json.loads(result['content'][0]['text'])
def session(sid): return next((s for s in call('snapshot')['sessions'] if s['id']==sid),None)
def grant(sid): return wait(lambda: json.loads((root/(sid+'.private.json')).read_text())['token'],'session fixture grant',30)
def saved_capture(sid):
    try: return call('terminalSnapshot',{'sessionID':sid})
    except Exception: return None

log=(artifacts/'runtime.private.log').open('w')
try:
    profiles={'codex':options.codex_profile.resolve(strict=True),'claude':options.claude_profile.resolve(strict=True)}
    wrappers={}
    for kind in profiles:
        native=shutil.which(kind); assert native
        wrapper=root/(kind+'-fixture')
        wrapper.write_text('#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\n'
          +'if "--version" not in sys.argv and "--help" not in sys.argv:\n'
          +' p=Path('+repr(str(root))+')/(os.environ["CHAUFFEUR_SESSION_ID"]+".private.json")\n'
          +' p.write_text(json.dumps({"token":os.environ["CHAUFFEUR_SESSION_TOKEN"],"args":sys.argv[1:]}));p.chmod(0o600)\n'
          +'os.execv('+repr(native)+', ['+repr(native)+']+sys.argv[1:])\n')
        wrapper.chmod(0o700); wrappers[kind]=str(wrapper)
    binary=Path(os.environ.get('CHAUFFEUR_RUNTIME_BINARY',REPO/'.build/debug/ChauffeurRuntime')).resolve()
    runtime=subprocess.Popen([str(binary),'--data-dir',str(root)],stdout=log,stderr=log)
    wait(lambda:call('status').get('mcpEndpoint'),'runtime',30)
    team,project,folder,group=uid(),uid(),uid(),uid(); presets={kind:uid() for kind in profiles}
    checkout=root/'repo';checkout.mkdir()
    subprocess.run(['git','init','-q',str(checkout)],check=True)
    subprocess.run(['git','-C',str(checkout),'-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-q','--allow-empty','-m','Fixture'],check=True)
    now=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    call('savePresetSet',{'record':{'id':team,'name':'Native fixture','agentSelection':'custom','configurationDirectories':{k:str(v) for k,v in profiles.items()},'revision':1,'archived':False}})
    for kind in profiles:
        arguments=['--no-alt-screen','--yolo'] if kind=='codex' else ['--dangerously-skip-permissions']
        call('savePreset',{'record':{'id':presets[kind],'setID':team,'name':kind,'kind':kind,'executable':wrappers[kind],'configurationDirectory':str(profiles[kind]),'arguments':arguments,'integration':'unverified','archived':False}})
    call('saveProject',{'record':{'id':project,'name':'Native orchestration','presetSetID':team,'folders':[{'id':folder,'name':'Repo','selectedPath':str(checkout),'canonicalPath':str(checkout),'availability':'available','registered':True}],'groups':[{'id':group,'name':'Default','isDefault':True,'archived':False,'createdAt':now,'updatedAt':now}],'archived':False,'createdAt':now,'updatedAt':now,'lastOpenedAt':now}})
    results=[]
    for parent_kind,child_kind in [('codex','claude'),('claude','codex')]:
        selected_model='sonnet' if child_kind=='claude' else 'gpt-6-astra'
        selected_reasoning='medium'
        marker='native-'+uuid.uuid4().hex[:12]
        worker_prompt=(f'This is an authorized Chauffeur integration check in an empty temporary repository. Do not edit any files, run shell commands, browse, or delegate. Call chauffeur_discover, then chauffeur_report_result using your delegationID and currentTurnID (pass as turnID), result exactly {marker}, and retryKey native-initial. Then finish your turn with a brief reply.')
        parent_prompt=(f'This is an authorized Chauffeur integration check. Do not edit files or run commands. Call chauffeur_delegate exactly once with presetID {presets[child_kind]}, folderID {folder}, model {selected_model}, reasoningEffort {selected_reasoning}, shareCheckout true, retryKey native-child, and task: {worker_prompt} Then end your turn. Do not wait, send follow-ups, close, or launch any other worker.')
        parent=call('launch',{'projectID':project,'groupID':group,'presetID':presets[parent_kind],'folderID':folder,'title':parent_kind+' coordinator probe','task':parent_prompt,'additionalFolderIDs':[],'allowSharedCheckout':True,'coordinationEnabled':True,'retryKey':uid()})
        parent_token=grant(parent['id'])
        print('Started',parent_kind,'to',child_kind,flush=True)
        delegation=wait(lambda:next((d for d in call('snapshot')['delegations'] if d['parentID']==parent['id']),None),'native delegation')
        assert delegation['state']!='failed', delegation
        child=delegation['childID']
        child_token=grant(child)
        child_fixture=json.loads((root/(child+'.private.json')).read_text())
        child_record=session(child)
        assert child_record['launch']['selectedModel']==selected_model, child_record['launch']
        assert child_record['launch']['selectedReasoning']==selected_reasoning, child_record['launch']
        child_args=child_fixture['args']
        assert '--model' in child_args and child_args[child_args.index('--model')+1]==selected_model, child_args
        if child_kind=='claude':
            assert '--effort' in child_args and child_args[child_args.index('--effort')+1]==selected_reasoning, child_args
        else:
            assert '-c' in child_args and 'model_reasoning_effort='+selected_reasoning in child_args, child_args
        def reported(expected):
            item=tool(parent_token,'chauffeur_delegation_status',{'delegationID':delegation['id']})
            return item if item.get('result')==expected and session(child)['state']=='turnFinished' else None
        status=wait(lambda:reported(marker),'native worker report')
        msg=tool(child_token,'chauffeur_send_message',{'recipientID':parent['id'],'body':'native cross-provider message','retryKey':'message'})
        assert any(m['id']==msg['id'] for m in tool(parent_token,'chauffeur_inbox'))
        correction=marker+'-corrected'
        follow_args={'delegationID':delegation['id'],'expectedTurnID':status['currentTurnID'],'prompt':f'Correction task:\nCall chauffeur_discover again and chauffeur_report_result with the current turnID and result exactly {correction}, retryKey native-correction. No file edits. Then finish.','retryKey':'native-follow'}
        time.sleep(1)
        submitted=tool(parent_token,'chauffeur_follow_up',follow_args)
        assert submitted['state']=='submitted', submitted
        assert tool(parent_token,'chauffeur_follow_up',follow_args)['id']==submitted['id']
        corrected=wait(lambda:reported(correction),'native correction report')
        assert corrected['currentTurnID']!=status['currentTurnID']
        closed=tool(parent_token,'chauffeur_close_session',{'delegationID':delegation['id'],'outcome':'accepted','reason':'Both native reports verified','retryKey':'native-close'})
        assert closed['state']=='completed',closed
        assert (root/'runtime/snapshots'/child/'latest.json').exists()
        child_record=session(child)
        results.append({'parent':parent_kind,'child':child_kind,'parentVersion':parent['launch']['executableVersion'],'childVersion':child_record['launch']['executableVersion'],'model':child_record['launch']['selectedModel'],'reasoning':child_record['launch']['selectedReasoning'],'nativeMCPDelegation':True,'reports':True,'followUp':True,'history':True,'executionPolicy':child_record['launch'].get('executionPolicy')})
        call('closeSession',{'sessionID':parent['id']})
        print('Passed',parent_kind,'to',child_kind,flush=True)
    (artifacts/'summary.json').write_text(json.dumps(results,indent=2))
    print('PASS native MCP delegation, reporting, messaging, follow-up and retained closure in both provider directions',flush=True)
finally:
    if runtime and runtime.poll() is None:
        try:
            snapshot=call('snapshot')
            for entry in snapshot['sessions']:
                capture=saved_capture(entry['id'])
                if capture: (artifacts/(entry['id']+'.private.json')).write_text(json.dumps(capture))
            call('forceStopAllSessions')
        except Exception: pass
        runtime.terminate();runtime.wait(timeout=15)
    log.close()
