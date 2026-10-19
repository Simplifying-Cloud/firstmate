import os, pathlib, tempfile, subprocess, urllib.request, urllib.error, json, shutil
root=pathlib.Path.cwd()
lab=pathlib.Path(tempfile.mkdtemp(prefix='.cred-live-',dir=root))
env={k:v for k,v in os.environ.items() if k not in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE']}
env['FM_HOME']=str(lab)
env['TMPDIR']=str(lab)
broker=str(root/'bin/fm-cred-broker.sh')
secrets=[]
def run(*args):
 p=subprocess.run([broker,'github',*args],env=env,text=True,capture_output=True)
 assert not any(s in p.stdout+p.stderr for s in secrets)
 return p

def api(token,path):
 req=urllib.request.Request('https://api.github.com/'+path,headers={'Authorization':'Bearer '+token,'Accept':'application/vnd.github+json','User-Agent':'firstmate-live-validation'})
 try:
  with urllib.request.urlopen(req,timeout=30) as r:return r.status,json.load(r)
 except urllib.error.HTTPError as e:return e.code,{}
try:
 (lab/'config').mkdir(); (lab/'state').mkdir()
 config=lab/'config/github-app'
 config.write_text('app_id=5373803\ninstallation_id=172847821\nprivate_key=/home/dscott/.config/firstmate/github-app.pem\nworkflows=on\n');config.chmod(0o600)
 for access in ('read','write'):
  task='live-'+access
  out=lab/(task+'.token')
  p=run('mint','--task',task,'--repo','Simplifying-Cloud/firstmate','--access',access,'--out',str(out))
  assert p.returncode==0,(p.returncode,p.stderr)
  token=out.read_text().strip(); secrets.append(token)
  assert out.stat().st_mode & 0o777 == 0o600
  pending=list((lab/'state/cred-pending'/task).glob('*'));assert len(pending)==1
  assert pending[0].stat().st_mode & 0o777 == 0o600
  status,data=api(token,'installation/repositories')
  repos=[r['full_name'] for r in data.get('repositories',[])]
  assert status==200 and repos==['Simplifying-Cloud/firstmate'],(status,repos)
  status,_=api(token,'repos/Simplifying-Cloud/firstmate/contents/README.md');assert status==200,status
  other,_=api(token,'repos/Simplifying-Cloud/proxmox-lab/contents/README.md');assert other in (403,404),other
  print(f'{access}: minted via real GitHub App; repository list={repos}; own README=200; other repository README={other}; output and pending response mode=0600',flush=True)
  if access=='read':p=run('revoke','--token-file',str(out))
  else:p=run('retire','--task',task)
  assert p.returncode==0,p.stderr
  status,_=api(token,'installation/repositories');assert status==401,status
  assert not list((lab/'state/cred-pending'/task).glob('*'))
  print(f'{access}: '+('revoke' if access=='read' else 'retire')+' confirmed; old token=401; pending set empty',flush=True)
  p=run('retire','--task',task);assert p.returncode==0,p.stderr
  print(f'{access}: retirement replay succeeds',flush=True)
 # Exercise safe refusal through the real broker, no fake API.
 config.write_text(config.read_text()+'app_id=5373803\n')
 p=run('mint','--task','bad-config','--repo','Simplifying-Cloud/firstmate','--access','read','--out',str(lab/'refused'))
 assert p.returncode!=0 and not (lab/'refused').exists()
 print('duplicate config key: mint refused; no output credential',flush=True)
 # Safe persisted-state recovery through the public retire command.
 pending=lab/'state/cred-pending/tokenless';pending.mkdir(mode=0o700)
 (pending/'token.empty').touch(mode=0o600)
 p=run('retire','--task','tokenless');assert p.returncode==0,p.stderr
 assert not list(pending.iterdir())
 print('tokenless pending entry: retirement succeeds and removes placeholder',flush=True)
 ledger=(lab/'state/cred-ledger').read_text()
 assert not any(s in ledger for s in secrets)
 assert 'reason=tokenless outcome=unknown' in ledger
 print('ledger: no credential values; mint, revoke, retire, and unknown-outcome records present',flush=True)
 print(ledger,flush=True)
finally:
 # Revoke only credentials created by this disposable validation.
 if (lab/'state/cred-pending').exists():
  for task in (lab/'state/cred-pending').iterdir():
   p=run('retire','--task',task.name)
   if p.returncode: print('CLEANUP RETIRE FAILED: '+task.name,flush=True)
 shutil.rmtree(lab)
