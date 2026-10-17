import os,pathlib,subprocess,json,time
R=pathlib.Path.cwd(); E=pathlib.Path('/home/dscott/.no-mistakes/evidence/01M54WH36WR8NGK9EHZG3DDNGF/round5'); D=R/'.r5'; H=D/'lab'; S=str(D/'s'); task='oc2-proof'
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']: env.pop(k,None)
env['FM_HOME']=str(H)
def run(args,check=True): return subprocess.run(list(map(str,args)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,check=check).stdout
def tm(*args): return run(['tmux','-S',S,*args])
def save(n,s): (E/n).write_text(s); return s
def cap(n): return save(n,tm('capture-pane','-p','-S','-100','-t','primary'))
def state():
 p=H/'state'/f'{task}.busy-state'; return p.read_text() if p.exists() else ''
def waitstate(event,limit=150):
 end=time.time()+limit
 while time.time()<end:
  if event in state(): return state()
  time.sleep(.3)
 raise RuntimeError('Timeout waiting '+event+' '+state())
def policy(n):
 rows=[]
 for p in pathlib.Path('/proc').glob('[0-9]*/environ'):
  try:
   en=dict(x.split(b'=',1) for x in p.read_bytes().split(b'\0') if b'=' in x)
   if en.get(b'OPENCODE_CONFIG_DIR',b'').decode()==str(H/'state'/f'{task}.opencode-config'):
    rows.append({'pid':p.parent.name,'config_dir':en[b'OPENCODE_CONFIG_DIR'].decode(),'config':json.loads(en[b'OPENCODE_CONFIG_CONTENT'])})
  except (OSError,ValueError): pass
 assert rows
 save(n,json.dumps(rows,indent=2)); return rows
try:
 D.mkdir(); run([R/'bin/fm-lab-home.sh','create',H]); (D/'project').mkdir()
 run(['git','-C',D/'project','init','-q']); run(['git','-C',D/'project','-c','user.name=Test','-c','user.email=test@example.invalid','commit','--allow-empty','-qm','initial']); run(['git','-C',D/'project','worktree','add','-qb','fm/'+task,D/'worker'])
 (H/'data'/task).mkdir(); (H/'config/backlog-backend').write_text('manual\n'); (H/'config/supervision-host').write_text('off\n')
 (H/'data'/task/'brief.md').write_text('# Task\n## Captain\'s intent\nReply with exactly PLATFORM_OK. Do not use tools or change files.\n\n## Firstmate spec\nDisposable validation. Reply once and wait.\n')
 tm('new-session','-d','-s','primary','-n','fm-'+task,'-x','110','-y','34','-c',D/'worker')
 env['TMUX']=tm('display-message','-p','#{socket_path},#{pid},0').strip()
 (H/'state'/f'{task}.meta').write_text(f'window=primary:fm-{task}\nworktree={D}/worker\nproject={D}/project\nharness=opencode2\nkind=ship\nmode=local-only\nyolo=off\nbranch=fm/{task}\nmodel=zai/glm-5.3-flash\neffort=default\nbackend=tmux\n')
 save('launch.txt',run([R/'bin/fm-spawn.sh',task,'--relaunch','--model','zai/glm-5.3-flash'])); print('launched',flush=True)
 save('completion-state.txt',waitstate('event=execution-succeeded')); time.sleep(1); capture=cap('completion-tui.txt'); assert 'PLATFORM_OK' in capture; before=policy('policy-before.json'); gen=(H/'state'/f'{task}.busy-gen').read_text(); save('generation-before.txt',gen)
 assert (H/'state'/f'{task}.turn-ended').exists(); print('platform completion passed',flush=True)
 save('send.txt',run([R/'bin/fm-send.sh',task,'Without tools, write an extremely long detailed explanation of the numbers from 1 to 1000, one paragraph per number. Start immediately.']))
 save('busy.txt',waitstate('event=execution-started')); cap('busy-tui.txt')
 save('interrupt.txt',run([R/'bin/fm-control.sh',task,'interrupt'])); save('interrupted-state.txt',waitstate('event=execution-interrupted',30)); cap('interrupted-tui.txt'); print('interrupt passed',flush=True)
 cfg=H/'state'/f'{task}.opencode-config'; (cfg/'old-sentinel').write_text('old')
 plugin=D/'worker/.opencode/plugins/fm-busy-state.js'; original=plugin.read_text(); plugin.write_text(original+'\n// replacement test sentinel\n'); save('plugin-before.js',plugin.read_text())
 save('relaunch.txt',run([R/'bin/fm-control.sh',task,'relaunch','--note','Reply with exactly REPLACEMENT_OK. Do not use tools or change files.']))
 save('replacement-state.txt',waitstate('event=execution-succeeded')); time.sleep(1); capture=cap('replacement-tui.txt'); assert 'REPLACEMENT_OK' in capture; after=policy('policy-after.json'); newgen=(H/'state'/f'{task}.busy-gen').read_text(); save('generation-after.txt',newgen); save('plugin-after.js',plugin.read_text())
 assert gen!=newgen and not (cfg/'old-sentinel').exists() and 'replacement test sentinel' not in plugin.read_text()
 assert all(row['config']==before[0]['config'] for row in after)
 assert not {r['pid'] for r in before}&{r['pid'] for r in after}
 save('replacement-proof.txt','Fresh worker processes; fresh busy generation; owned config sentinel removed; plugin regenerated; provider policies and selected model preserved; replacement execution succeeded.\n')
 save('exit.txt',run([R/'bin/fm-control.sh',task,'exit'])); print('ALL PASS',flush=True)
except Exception as ex:
 save('error.txt',str(ex)+'\n'+getattr(ex,'stdout','')); print(repr(ex),getattr(ex,'stdout',''),flush=True)
 try: cap('error-tui.txt')
 except Exception: pass
 raise
finally:
 run(['tmux','-S',S,'kill-server'],check=False)
 import shutil
 for d,ds,fs in os.walk(D): os.chmod(d,0o700)
 shutil.rmtree(D)
 print('lab removed',flush=True)
