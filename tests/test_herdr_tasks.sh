#!/usr/bin/env bash
# Filtros del centro de tareas y navegación: sin abrir Herdr ni modificar tareas reales.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
node --input-type=module - "$ROOT" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const source = fs.readFileSync(`${process.argv[2]}/herdr/mods/tareas/main.js`, 'utf8')
  .replace(/^import .*;$/gm, '').replace('export default class Tareas', 'class Tareas');
let ids = [], actions = new Map(), calls = [], stored = new Map(), texts = [], notes = [], ran = [];
let execImpl = () => {throw Error('No debe crear otro espacio');};
const element = () => {
  let id;
  const el = new Proxy({}, {get: (_, key) => (...args) => {
    if (key === 'id') { id = args[0]; ids.push(id); }
    if (key === 'on_click') actions.set(id, args[0]);
    if (key === 'child' && typeof args[0] === 'string') texts.push(args[0]);
    if (key === 'children') return el;
    if (key === 'when' && args[0]) args[1](el);
    return el;
  }});
  return el;
};
const live = {address:'t1',state:'live',labels:{'bk.kind':'agent','bk.win':'i1','bk.project':'abra','herdr.space':'sp1','herdr.tab':'tb1'}};
const tasks = [
  {id:'1',dir:'/abra/1',project:'abra',status:'in_progress',window:'i1'},
  {id:'1',dir:'/abra/1~old',project:'abra',status:'completed',window:'i1'},
  {id:'2',dir:'/kit/2',project:'kit',status:'pending'},
  {id:'3',dir:'/kit/3',project:'kit',status:'failed'},
];
const Tareas = new Function('View','div','v_flex','h_flex','terminals','run','localStorage','notify','spaces','exec','home', source + '\nreturn Tareas;')(
  class {}, element, element, element, () => [live], (name,args) => calls.push([name,args]),
  {setItem:(k,v)=>stored.set(k,v)}, (n) => notes.push(n), () => [{id:'existing',name:'Barrilete · Tareas',machine:null,tabs:[{id:'board',name:'Todas las tareas'}]}],
  (...a) => execImpl(...a), () => '/home/yo');
const board = new Tareas(); Object.assign(board,{tasks,filter:'active',project:'',loaded:true});
const theme = {accent:'#c6a7ef',blocked:'#edbe85',done:'#a5d8bd'};
const render = () => { ids=[];actions=new Map();board.renderBoard(theme);return ids.filter(x=>x.startsWith('board-/')); };
assert.deepEqual(render(), ['board-/abra/1','board-/kit/2']);
actions.get('project-abra')({}, {notify(){}});
assert.equal(stored.get('project'),'abra');
assert.deepEqual(render(), ['board-/abra/1']);
actions.get('filter-all')({}, {notify(){}});
assert.deepEqual(render(), ['board-/abra/1','board-/abra/1~old']);
actions.get('filter-completed')({}, {notify(){}});
assert.deepEqual(render(), ['board-/abra/1~old']);
actions.get('project-kit')({}, {notify(){}});
assert.deepEqual(render(), []);
assert.equal(board.terminalOf(tasks[1],[live]), null, 'el historial no abre el agente de otra ejecución');
board.open(tasks[0],live);
assert.deepEqual(calls,[['space.select',{id:'sp1'}],['tab.select',{id:'tb1'}],['pane.focus',{terminal:'t1'}]]);
calls=[];await board.openBoard();
assert.deepEqual(calls,[['space.select',{id:'existing'}],['tab.select',{id:'board'}]], 'reutiliza el espacio existente');
console.log('ok - activas, proyecto, historial, estados, vacío, agente y espacio único');

// El acceso de la barra dice qué te espera sin entrar
const bar = new Tareas(); Object.assign(bar,{loaded:true,error:null,tasks:[{status:'pending'},{status:'waiting'},{status:'waiting'},{status:'completed'}]});
const launcher = () => { ids=[];texts=[];bar.renderLauncher(theme);return [ids.filter(x=>x.startsWith('launcher-')).join(','), texts.slice(1).join('|')]; };
assert.deepEqual(launcher(), ['launcher-pending,launcher-waiting','1 por aprobar|2 te esperan']);
bar.tasks.push({status:'in_progress'});
assert.deepEqual(launcher(), ['launcher-pending,launcher-waiting,launcher-in_progress','1 aprobar|2 esperan|1 activas'], 'con los tres grupos, palabras cortas');
bar.tasks=[{status:'completed'}]; assert.deepEqual(launcher(), ['launcher-quiet','nada te espera']);
bar.error='x'; assert.deepEqual(launcher(), ['launcher-quiet','no pude leer las tareas']);
bar.error=null; bar.loaded=false; assert.deepEqual(launcher(), ['launcher-quiet','leyendo…']);
console.log('ok - el acceso de la barra: por aprobar, te esperan, trabajando, nada, error y cargando');

// Título del issue y el botón del reviewer propuesto: corre bk approve una sola vez, en el repo de la tarea
const prop = {id:'pr9-reviewer',dir:'/kit/pr9',project:'kit',status:'pending',role:'reviewer',pr:9,repo:'/repos/kit',title:'Arreglar el login'};
const impl = {id:'4-implementer',dir:'/kit/4',project:'kit',status:'pending',role:'implementer'};
const b2 = new Tareas(); Object.assign(b2,{tasks:[prop,impl,{...prop,dir:'/kit/pr9~old',status:'completed'}],filter:'all',project:'',loaded:true});
b2.load = async () => { ran.push('load'); };
ids=[];actions=new Map();texts=[];b2.renderBoard(theme);
assert.ok(texts.includes('Arreglar el login'), 'la fila muestra el título del issue');
assert.deepEqual(ids.filter(x=>x.startsWith('approve-')), ['approve-/kit/pr9'], 'solo el reviewer por aprobar tiene botón: ni otro rol ni el historial');
let release; execImpl = (cmd,args,opts) => { ran.push([cmd,args,opts.cwd]); return new Promise((ok)=>{release=()=>ok({code:0,stdout:'',stderr:''});}); };
const cx = {notify(){}, stop_propagation(){ ran.push('stop'); }, spawn(f){ last = f(cx); return last; }};
let last;
actions.get('approve-/kit/pr9')({}, cx); const first = last;
ids=[];texts=[];b2.renderBoard(theme); assert.ok(texts.includes('Lanzando…'), 'mientras lanza, el botón lo dice');
actions.get('approve-/kit/pr9')({}, cx);   // un segundo clic mientras lanza no hace nada
assert.equal(ran.filter(x=>Array.isArray(x)).length, 1, 'un segundo clic mientras lanza no corre bk approve otra vez');
release(); await first;
assert.deepEqual(ran.filter(x=>Array.isArray(x)), [['bk',['approve','pr9-reviewer'],'/repos/kit']], 'bk approve una sola vez, en el repo de la tarea');
assert.equal(ran.filter(x=>x==='stop').length, 2, 'el clic del botón no abre la fila');
assert.ok(ran.includes('load'), 'después de lanzar relee las tareas');
assert.equal(notes.at(-1).level, 'success');
execImpl = async () => ({code:1,stdout:'',stderr:'bk: no hay una tarea pendiente\n'});
actions.get('approve-/kit/pr9')({}, cx); await last;
assert.deepEqual([notes.at(-1).level, notes.at(-1).body], ['error','bk: no hay una tarea pendiente'], 'si bk approve falla, lo dice');
ids=[];texts=[];b2.renderBoard(theme); assert.ok(texts.includes('Lanzar reviewer'), 'y el botón vuelve');
console.log('ok - título, botón de aprobar: una vez, en su repo, avisa el resultado');
JS
