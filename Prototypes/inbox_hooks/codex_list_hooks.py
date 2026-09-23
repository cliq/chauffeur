#!/usr/bin/env python3
"""Asks an isolated `codex app-server --stdio` for hooks/list using a probe run's
-c flags and CODEX_HOME; writes MODE/hooks-list.json (keys, currentHash, trustStatus)."""
import os,json,pathlib,subprocess,sys,select,time
ROOT=pathlib.Path(os.environ.get('PROBE_ROOT','/tmp/chauffeur-codex-hooks'))
run=ROOT/(sys.argv[1] if len(sys.argv)>1 else 'plain');cmd=json.loads((run/'command.json').read_text());flags=[]
for i,x in enumerate(cmd):
 if x=='-c':flags+=cmd[i:i+2]
env={k:v for k,v in os.environ.items() if not any(s in k for s in ['TOKEN','API_KEY','CODEX','CHAUFFEUR','CLAUDE'])};env['CODEX_HOME']=str(run/'home')
p=subprocess.Popen([cmd[0],'app-server','--stdio']+flags,cwd=run/'work',env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
for msg in [{'id':1,'method':'initialize','params':{'clientInfo':{'name':'hook_probe','version':'1'},'capabilities':{'experimentalApi':True}}},{'method':'initialized'},{'id':2,'method':'hooks/list','params':{'cwds':[str(run/'work')]}}]:p.stdin.write(json.dumps(msg)+'\n');p.stdin.flush()
try:
 for _ in range(20):
  line=p.stdout.readline()
  if not line:break
  r=json.loads(line)
  if r.get('id')==2:
   (run/'hooks-list.json').write_text(json.dumps(r,indent=2));print(json.dumps(r,indent=2));break
finally:p.terminate();p.communicate(timeout=5)
