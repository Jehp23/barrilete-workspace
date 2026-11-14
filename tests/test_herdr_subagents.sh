#!/usr/bin/env bash
# Hooks y transcripts ficticios: nunca lee ni escribe sesiones reales.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json, os, sys, tempfile, time
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1])/'lib'))
with tempfile.TemporaryDirectory() as tmp:
    root=Path(tmp); projects=root/'projects'; states=root/'states'; states.mkdir()
    os.environ['BK_PROJECTS']=str(projects); os.environ['BK_STATE_DIR']=str(states)
    import herdr_subagents as H
    def state(sid, terminal, ts):
        (states/f'{sid}.json').write_text(json.dumps({'pane':terminal,'ts':ts}))
    def child(sid, name, number, *, finished=False, old=False, background=False):
        d=projects/'repo'/sid/'subagents';d.mkdir(parents=True,exist_ok=True)
        transcript=d/f'agent-{name}.jsonl'
        transcript.write_text(json.dumps({'timestamp':f'2026-11-14T00:00:{number:02d}Z'})+'\n')
        meta=transcript.with_suffix('.meta.json')
        meta.write_text(json.dumps({'description':f'tarea {name}','agentType':'reviewer','finished':finished,'requestShape':'background' if background else 'foreground'}))
        if old:os.utime(transcript,(time.time()-700,)*2)
        return transcript
    state('s1','t1',10);state('s2','t2',10)
    child('s1','finished',1,finished=True)
    live=child('s1','live',2,background=True)
    child('s1','stale',3,old=True)
    child('s2','other',1)
    d=projects/'repo'/'s1'/'subagents';(d/'agent-broken.meta.json').write_text('{bad')
    (d/'agent-broken.jsonl').write_text('{}\n')
    (states/'broken.json').write_text('{bad')
    data=H.snapshot()['by_terminal']
    assert set(data)=={'t1','t2'},data
    assert len(data['t1'])==1,data
    item=data['t1'][0]
    assert [item['id'],item['number'],item['description'],item['type'],item['background'],item['path']]==['live','2','tarea live','reviewer',True,str(live)],item
    assert data['t2'][0]['number']=='1'
    # Una terminal reutilizada no conserva los hijos de la sesión anterior.
    state('new-session','t1',20)
    assert 't1' not in H.snapshot()['by_terminal']
    print('ok - padre correcto, descripción, segundo plano, numeración estable, terminados, inactivos, JSON roto y sesión reemplazada')
PY

node --input-type=module - "$ROOT" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const source=fs.readFileSync(`${process.argv[2]}/herdr/mods/agentes/main.js`,'utf8').replace(/^import .*;$/gm,'').replace('export default class Agents','class Agents');
let click, calls=[];
const el=()=>new Proxy({}, {get:(_,key)=>(...args)=>{if(key==='on_click')click=args[0];if(key==='when'&&args[0])args[1](el());return el();}});
const Agents=new Function('View','div','svg','h_flex','v_flex','agents','run','home',source+';return Agents;')(class{},el,el,el,el,()=>[{address:'t1',space:'sp1'}],(name,args)=>calls.push([name,args]),()=>'/home/test');
const view=new Agents();view.listed=new Map([['t2','working']]);
const rows=view.tree([{address:'t2',parent:'t1',state:'live',status:'working'},{address:'claude:t1:x',parent:'t1',state:'live',status:'working',name:'2 reviewer',transcript:'/test/agent-x.jsonl'}],'t1');
assert.equal(rows.length,2,'conserva hijos nativos y los internos');
view.subRow({working:'#123456',foreground:'#ffffff'},rows[1],null,false);click();
assert.deepEqual(calls,[['space.select',{id:'sp1'}],['tab.new',{space:'sp1',name:'2 reviewer',folder:'/home/test',argv:['bk','sub','/test/agent-x.jsonl']}]]);
calls=[];view.subRow({working:'#123456',foreground:'#ffffff'},rows[0],null,false);click();
assert.deepEqual(calls,[['pane.focus',{terminal:'t2'}]],'el hijo nativo sigue abriendo su terminal');
console.log('ok - árbol mixto: clic en Claude sigue el transcript; clic nativo conserva la navegación');
JS
