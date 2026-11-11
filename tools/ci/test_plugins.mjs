#!/usr/bin/env node
// Development-only bootstrap tests: Node vm is NOT a security boundary and these
// checks do not validate native QuickJS integration, C limits, or sandbox escapes.
// Run: node tools/ci/test_plugins.mjs (no npm, downloads, or compilation).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const bootstrap = readFileSync(new URL('../../src/core/plugins_bootstrap.js', import.meta.url), 'utf8');
function runtime(source = '') {
  const context = vm.createContext(Object.create(null));
  const run = source => vm.runInContext(source, context, { timeout: 1000 });
  run(bootstrap);
  run(source);
  return { run, dispatch: q => JSON.parse(run(`__pzDispatch(${JSON.stringify(JSON.stringify(q))})`)) };
}
let passed = 0;
function test(name, body) {
  try { body(); passed++; console.log(`ok ${passed} - ${name}`); }
  catch (error) { console.error(`not ok - ${name}`); throw error; }
}
const tool = (execute = "() => 'hello'") => `pz.registerTool({name:'hello',description:'Greeting',parameters:{type:'object'},execute:${execute}});`;

test('minimal globals and immutable public API', () => {
  const r = runtime();
  assert.equal(r.run("['process','require','fetch'].every(k => typeof globalThis[k] === 'undefined')"), true);
  assert.equal(r.run('Object.isFrozen(pz) && Object.isFrozen(pz.state)'), true);
  assert.equal(r.run("Object.getOwnPropertyDescriptor(globalThis,'pz').writable"), false);
});
test('tools list, arguments, state, and text content', () => {
  const r = runtime(tool("(args,ctx) => {ctx.state.set('last',args.name); return 'hello '+ctx.state.get('last')}"));
  assert.deepEqual(r.dispatch({op:'list'}), [{name:'hello',description:'Greeting',parameters:{type:'object'}}]);
  assert.deepEqual(r.dispatch({op:'tool',name:'hello',args:{name:'world'}}), {content:[{type:'text',text:'hello world'}]});
  assert.throws(() => r.dispatch({op:'tool',name:'missing'}), /Unknown plugin tool/);
  const rich = runtime(tool("() => ({content:[{type:'text',text:'one'},{type:'text',text:'two'}]})"));
  assert.equal(rich.dispatch({op:'tool',name:'hello'}).content.length, 2);
});
test('commands receive arguments and persistent state', () => {
  const r = runtime("pz.registerCommand('greet',{handler:(args,ctx)=>{ctx.state.set('args',args);return ctx.state.get('args')}})");
  assert.equal(r.dispatch({op:'command',name:'greet',args:'Ada'}), 'Ada');
  assert.equal(r.dispatch({op:'command',name:'unknown'}), null);
  assert.throws(() => runtime("pz.registerCommand('bad',{handler:()=>42})").dispatch({op:'command',name:'bad'}), /must return a string/);
});
test('registration names, descriptors, duplicates, and event shapes are validated', () => {
  for (const source of [
    "pz.registerTool({name:'bad name'})", "pz.registerTool({name:'bad',description:2,parameters:{},execute(){}})",
    "pz.registerTool({name:'bad',description:'x',parameters:[],execute(){}})",
    "pz.registerTool({name:'bad',description:'x',parameters:{}})",
    "pz.registerCommand('bad',{})", "pz.on('unknown',()=>{})", "pz.on('session_start',42)",
    tool()+tool(), "pz.registerCommand('same',{handler(){}});pz.registerCommand('same',{handler(){}})"
  ]) assert.throws(() => runtime(source));
});
test('invalid tool result shapes fail', () => {
  for (const value of ['null','42','{}',"{content:[{type:'image',text:'x'}]}",'{content:[{type:"text",text:4}]}']) {
    const r = runtime(tool(`() => (${value})`));
    assert.throws(() => r.dispatch({op:'tool',name:'hello'}), /Invalid plugin tool result/);
  }
});
test('Promise and thenable results are rejected on every callback path', () => {
  for (const result of ["Promise.resolve('x')", "({then(){}})"]) {
    assert.throws(() => runtime(tool(`() => ${result}`)).dispatch({op:'tool',name:'hello'}), /Async\/Promise/);
    assert.throws(() => runtime(`pz.registerCommand('async',{handler:()=>${result}})`).dispatch({op:'command',name:'async'}), /Async\/Promise/);
    assert.throws(() => runtime(`pz.on('session_start',()=>${result})`).dispatch({op:'event',name:'session_start'}), /Async\/Promise/);
  }
});
test('context appends are ordered and blocking cannot be undone by a later allow', () => {
  const r = runtime(`
    pz.on('before_request',()=>({systemPromptAppend:'first'}));
    pz.on('before_request',()=>null);
    pz.on('before_request',()=>({systemPromptAppend:'second'}));
    pz.on('tool_call',()=>({block:true,reason:'guard'}));
    pz.on('tool_call',()=>({block:false}));
  `);
  assert.deepEqual(r.dispatch({op:'event',name:'before_request',payload:{}}), {systemPromptAppend:'first\n\nsecond'});
  assert.deepEqual(r.dispatch({op:'event',name:'tool_call',payload:{}}), {block:true,reason:'guard'});
  assert.deepEqual(r.dispatch({op:'event',name:'session_end'}), {});
  assert.deepEqual(runtime("pz.on('tool_call',()=>({block:true}))").dispatch({op:'event',name:'tool_call'}), {block:true,reason:'Blocked by plugin'});
});
test('event result shapes are validated', () => {
  for (const [event,value] of [['before_request','{}'],['before_request','{systemPromptAppend:3}'],['tool_call','{block:"yes"}'],['tool_call','{block:true,reason:3}']]) {
    assert.throws(() => runtime(`pz.on('${event}',()=>(${value}))`).dispatch({op:'event',name:event}));
  }
});
test('registration and state counts are bounded at their boundaries', () => {
  const r = runtime(`
    for(let i=0;i<64;i++) {
      pz.registerTool({name:'t'+i,description:'x',parameters:{},execute:()=>''});
      pz.registerCommand('c'+i,{handler:()=>''});
      pz.on('session_start',()=>{});
    }
    for(let i=0;i<1024;i++) pz.state.set('k'+i,i);
    pz.state.set('k0','updated');
  `);
  assert.throws(() => r.run(tool()), /excessive/);
  assert.throws(() => r.run("pz.registerCommand('overflow',{handler:()=>''})"), /excessive/);
  assert.throws(() => r.run("pz.on('session_start',()=>{})"), /Too many/);
  assert.throws(() => r.run("pz.state.set('overflow',1)"), /Too many/);
  assert.equal(r.run("pz.state.get('k0')"), 'updated');
});
test('listing seals all registries but leaves runtime state usable', () => {
  const r = runtime(tool()); r.dispatch({op:'list'});
  for (const source of [tool(), "pz.registerCommand('later',{handler:()=>''})", "pz.on('session_start',()=>{})"]) assert.throws(() => r.run(source), /closed/);
  r.run("pz.state.set('live',true)"); assert.equal(r.run("pz.state.get('live')"), true);
});
test('reserved built-in command cannot be registered', () => {
  assert.throws(() => runtime("pz.registerCommand('help',{handler:()=>''})"), /plugin command/);
});
test('output serialization limit rejects oversized output', () => {
  assert.throws(() => runtime(tool("()=>'x'.repeat(1048576)")).dispatch({op:'tool',name:'hello'}), /output exceeds limit/);
});
test('generic tool extensions prepare arguments and validate registrations', () => {
  const descriptor = prepare=>`pz.registerToolExtension({tool:'web',name:'test',description:'test',parameters:{type:'object'},prepare:${prepare}})`;
  const prepare=(r,tool,extension,args={})=>r.dispatch({op:'event',name:'__prepare_tool_extension',payload:{tool,args:{extension,extension_args:args}}});
  let r=runtime(descriptor("a=>({url:a.url})"));
  assert.deepEqual(prepare(r,'web','test',{url:'https://example.com'}),{url:'https://example.com'});
  assert.deepEqual(prepare(r,'web','test','{"url":"https://example.com"}'),{url:'https://example.com'});
  assert.throws(()=>prepare(r,'web','missing'),/Unknown/);
  assert.throws(()=>prepare(r,'ffmpeg','test'),/Unknown/);
  assert.throws(()=>prepare(r,'web','test','[]'),/Invalid extension arguments/);
  assert.throws(()=>r.dispatch({op:'event',name:'__prepare_tool_extension',payload:{tool:'web',args:{extension:'test',url:'https://example.com'}}}),/mix/);
  for(const result of ['null','[]','42',"({extension:'test'})","({extension_args:{}})",'Promise.resolve({})']) {
    assert.throws(()=>prepare(runtime(descriptor(`()=>${result}`)),'web','test'));
  }
  for(const tool of ['bash','mcp','read','write','future_tool']) {
    const generic = runtime(descriptor('a=>({path:a.path})').replace("tool:'web'",`tool:'${tool}'`));
    assert.deepEqual(prepare(generic,tool,'test',{path:'file.txt'}),{path:'file.txt'});
  }
  for(const tool of ['', 'bad tool', '../web']) assert.throws(()=>runtime(descriptor('()=>({})').replace("tool:'web'",`tool:'${tool}'`)));
  assert.throws(()=>runtime(descriptor('()=>({})')+';'+descriptor('()=>({})')),/Duplicate/);
  r.dispatch({op:'list'}); assert.throws(()=>r.run(descriptor('()=>({})')),/closed/);
  assert.equal(r.dispatch({op:'describe'}).extensions[0].name,'test');
  assert.match(r.dispatch({op:'event',name:'before_request',payload:{}}).systemPromptAppend,/test/);
});
test('example plugin runs without filesystem or network capabilities', () => {
  const r = runtime(readFileSync(new URL('../../examples/plugins/hello.js', import.meta.url), 'utf8'));
  assert.equal(r.dispatch({op:'list'})[0].name, 'hello');
  assert.match(r.dispatch({op:'tool',name:'hello',args:{name:'Ada'}}).content[0].text, /Ada/);
  assert.match(r.dispatch({op:'event',name:'before_request',payload:{}}).systemPromptAppend, /hello/);
  assert.equal(r.dispatch({op:'event',name:'tool_call',payload:{toolName:'hello',input:{name:'blocked'}}}).block, true);
  assert.equal(r.dispatch({op:'event',name:'tool_call',payload:{toolName:'hello',input:{name:'Ada'}}}).block, false);
});
test('workflow callbacks preserve state and context across completion rounds', () => {
  const r = runtime(`pz.registerToolExtension({tool:'read',name:'flow',description:'x',parameters:{},
    prepare:(args,ctx)=>{ctx.state.set('path',args.path);return {workflow:true,requests:[{path:args.path}],context:{round:1}}},
    complete:(results,context,ctx)=>context.round===1
      ? {workflow:true,requests:[{path:ctx.state.get('path')}],context:{round:2}}
      : {workflow:true,output:results[0].output,isError:false}})`);
  const event=(name,payload)=>r.dispatch({op:'event',name,payload});
  assert.deepEqual(event('__prepare_tool_extension',{tool:'read',args:{extension:'flow',extension_args:{path:'a'}}}),
    {workflow:true,requests:[{path:'a'}],context:{round:1}});
  const complete=context=>event('__complete_tool_extension',{tool:'read',name:'flow',context,results:[{output:'native',isError:false}]});
  assert.deepEqual(complete({round:1}),{workflow:true,requests:[{path:'a'}],context:{round:2}});
  assert.deepEqual(complete({round:2}),{workflow:true,output:'native',isError:false});
});
test('workflow callbacks reject async, malformed, recursive and invalid final results', () => {
  const source=(prepare,complete)=>`pz.registerToolExtension({tool:'read',name:'flow',description:'x',parameters:{},prepare:()=>(${prepare}),complete:()=>(${complete})})`;
  const prepare=r=>r.dispatch({op:'event',name:'__prepare_tool_extension',payload:{tool:'read',args:{extension:'flow'}}});
  const complete=r=>r.dispatch({op:'event',name:'__complete_tool_extension',payload:{tool:'read',name:'flow',results:[{output:'ok',isError:false}]}});
  for (const value of ['Promise.resolve({workflow:true,output:"x"})','{then(){}}','null','[]','{workflow:true,requests:[]}',
    '{workflow:true,requests:Array(9).fill({path:"a"})}','{workflow:true,requests:[null]}','{workflow:true,requests:[[]]}',
    '{workflow:true,requests:[{extension:"flow"}]}','{workflow:true,requests:[{extension_args:{}}]}','{workflow:true,requests:[{workflow:true,requests:[]}]}',
    '{workflow:true,requests:[{}],extra:true}','{workflow:true,output:42}','{workflow:true,output:"x",isError:"yes"}','{workflow:true,output:"x",extra:true}',
    '{workflow:true,output:"x".repeat(262145)}']) {
    assert.throws(()=>prepare(runtime(source(value,'{workflow:true,output:"ok"}'))));
    assert.throws(()=>complete(runtime(source('{workflow:true,requests:[{path:"a"}]}',value))));
  }
  assert.deepEqual(complete(runtime(source('{}','{workflow:true,output:"failed",isError:true}'))),{workflow:true,output:'failed',isError:true});
  assert.throws(()=>complete(runtime(source('{}','{path:"a"}'))));
  for (const marker of ['false','1','"true"','null']) {
    assert.throws(()=>prepare(runtime(source(`{workflow:${marker},requests:[{}]}`,'{workflow:true,output:"ok"}'))));
  }
  const legacy=runtime("pz.registerToolExtension({tool:'read',name:'flow',description:'x',parameters:{},prepare:a=>({path:'a'})})");
  assert.deepEqual(prepare(legacy),{path:'a'});
  const nativeOutput=runtime("pz.registerToolExtension({tool:'read',name:'flow',description:'x',parameters:{},prepare:()=>({output:'movie.mp4'})})");
  assert.deepEqual(prepare(nativeOutput),{output:'movie.mp4'});
  assert.throws(()=>complete(legacy),/Missing extension completion/);
  assert.throws(()=>runtime(source('{workflow:true,requests:[{}]}','{workflow:true,output:"ok"}').replace('complete:()=>({workflow:true,output:"ok"})','complete:42')),/Invalid/);
});
test('web-access cached passage offsets preserve Unicode and literal matching', () => {
  const r = runtime(readFileSync(new URL('../../examples/plugins/web-access.js', import.meta.url), 'utf8'));
  const prepare = args => r.dispatch({op:'event',name:'__prepare_tool_extension',payload:{tool:'web',args:{extension:'web_access',extension_args:args}}});
  const plan = prepare({op:'fetch',url:'https://example.com'});
  const result = r.dispatch({op:'event',name:'__complete_tool_extension',payload:{tool:'web',name:'web_access',context:plan.context,results:[{output:'İ needle [literal]',isError:false}]}});
  const responseId = JSON.parse(result.output).responseId;
  const found = needle => JSON.parse(prepare({op:'get_search_content',responseId,findText:needle}).output);
  assert.equal(found('NEEDLE').passages[0].matchOffset,2);
  assert.equal(found('[literal]').passages[0].matchOffset,9);
});
console.log(`Passed ${passed} bootstrap logic tests under Node vm; native QuickJS C limits NOT tested.`);
