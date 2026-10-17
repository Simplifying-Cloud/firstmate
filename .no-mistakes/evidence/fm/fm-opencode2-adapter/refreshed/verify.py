import os,json,pathlib,subprocess
root=pathlib.Path.cwd()
e=pathlib.Path('/home/dscott/.no-mistakes/evidence/01M54WH36WR8NGK9EHZG3DDNGF/refreshed')
home=str(root/'.oc2-refreshed/lab')
rows=[]
for p in pathlib.Path('/proc').glob('[0-9]*/environ'):
 try:
  env=dict(x.split(b'=',1) for x in p.read_bytes().split(b'\0') if b'=' in x)
  if env.get(b'OPENCODE_CONFIG_DIR',b'').decode()==home+'/state/oc2-recheck.opencode-config':
   rows.append({'pid':p.parent.name,'config_dir':env[b'OPENCODE_CONFIG_DIR'].decode(),'config':json.loads(env[b'OPENCODE_CONFIG_CONTENT'])})
 except (OSError,ValueError): pass
assert rows
before=json.loads((e/'policy-before.json').read_text())
assert all(r['config']==before[0]['config'] for r in rows)
assert not {r['pid'] for r in rows}&{r['pid'] for r in before}
(e/'policy-after.json').write_text(json.dumps(rows,indent=2))
assert (e/'generation-before.txt').read_text()!=(e/'generation-after.txt').read_text()
assert 'replacement test sentinel' not in (e/'plugin-after.js').read_text()
assert (e/'plugin-after.js').read_text()!=(e/'plugin-before.js').read_text()
assert not (pathlib.Path(home)/'state/oc2-recheck.opencode-config/old-sentinel').exists()
print('PASS: fresh processes, identical provider policy and model, replaced config directory, regenerated plugin and generation')
