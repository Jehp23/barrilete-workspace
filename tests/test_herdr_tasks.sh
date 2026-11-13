#!/usr/bin/env bash
# Filtros del centro de tareas y navegación: sin abrir Herdr ni modificar tareas reales.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
node --input-type=module - "$ROOT" <<'JS'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const source = fs.readFileSync(`${process.argv[2]}/herdr/mods/tareas/main.js`, 'utf8')
  .replace(/^import .*;$/gm, '').replace('export default class Tareas', 'class Tareas');
let ids = [], actions = new Map(), calls = [], stored = new Map();
const element = () => {
  let id;
  const el = new Proxy({}, {get: (_, key) => (...args) => {
    if (key === 'id') { id = args[0]; ids.push(id); }
    if (key === 'on_click') actions.set(id, args[0]);
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
const Tareas = new Function('View','div','v_flex','h_flex','terminals','run','localStorage','notify','spaces','exec', source + '\nreturn Tareas;')(
  class {}, element, element, element, () => [live], (name,args) => calls.push([name,args]),
  {setItem:(k,v)=>stored.set(k,v)}, () => {}, () => [{id:'existing',name:'Barrilete · Tareas',machine:null,tabs:[{id:'board',name:'Todas las tareas'}]}],
  () => {throw Error('No debe crear otro espacio');});
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
JS
