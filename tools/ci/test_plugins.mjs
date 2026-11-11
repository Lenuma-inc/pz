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
function mcpAdapterRuntime() {
  const r = runtime(readFileSync(new URL('../../examples/plugins/mcp-adapter.js', import.meta.url), 'utf8'));
  return {
    dispatch: r.dispatch,
    prepare: args => r.dispatch({op:'event',name:'__prepare_tool_extension',payload:{tool:'mcp',args:{extension:'mcp_adapter',extension_args:JSON.stringify(args)}}}),
    complete: (plan, result) => r.dispatch({op:'event',name:'__complete_tool_extension',payload:{tool:'mcp',name:'mcp_adapter',context:plan.context,results:[{output:JSON.stringify(result),isError:false}]}})
  };
}
const mcpAdapterTool = (server, name, description = '') => ({server,name:server+'__'+name,remote_name:name,description});
const mcpAdapterInventory = tools => ({servers:[{name:'browser',status:'connected'},{name:'db',status:'connected'}],tools,nextOffset:null});
test('registers one mcp extension and no replacement remote tools', () => {
  const r = mcpAdapterRuntime();
  assert.deepEqual(r.dispatch({op:'list'}),[]);
  const extensions = r.dispatch({op:'event',name:'__tool_extensions',payload:{}});
  assert.equal(extensions[0].tool,'mcp');
  assert.equal(extensions[0].mcpProxy,true);
});
test('ranked search and regex search return paginated summaries without schemas', () => {
  const r = mcpAdapterRuntime();
  const tools = [mcpAdapterTool('browser','screenshot','Capture pixels'),mcpAdapterTool('db','query','Screenshot records')];
  const result = JSON.parse(r.complete(r.prepare({search:'screenshot',limit:1}),mcpAdapterInventory(tools)).output);
  assert.equal(result.tools[0].name,'browser__screenshot');
  assert.equal(result.nextOffset,1);
  assert.equal(result.tools[0].inputSchema,undefined);
  const regex = JSON.parse(r.complete(r.prepare({search:'^browser',regex:true}),mcpAdapterInventory(tools)).output);
  assert.equal(regex.total,1);
  assert.throws(()=>r.complete(r.prepare({search:'[',regex:true}),mcpAdapterInventory(tools)));
});
test('describe resolves a unique alias then requests the exact native schema', () => {
  const r = mcpAdapterRuntime();
  const next = r.complete(r.prepare({describe:'take-screenshot'}),mcpAdapterInventory([mcpAdapterTool('browser','take_screenshot')]));
  assert.deepEqual(next.requests,[{op:'describe',name:'browser__take_screenshot'}]);
  const schema = {type:'object',properties:{x:{type:'integer',minimum:2}},required:['x']};
  const described = JSON.parse(r.complete(next,{name:'browser__take_screenshot',inputSchema:schema}).output);
  assert.deepEqual(described.inputSchema,schema);
});
test('calls route only the resolved native public name and preserve remote args', () => {
  const r = mcpAdapterRuntime();
  const next = r.complete(r.prepare({tool:'query',server:'db',args:'{"sql":"SELECT 1"}'}),mcpAdapterInventory([mcpAdapterTool('browser','query'),mcpAdapterTool('db','query')]));
  assert.deepEqual(next.requests,[{tool:'db__query',args:{sql:'SELECT 1'}}]);
  assert.throws(()=>r.complete(r.prepare({tool:'query'}),mcpAdapterInventory([mcpAdapterTool('browser','query'),mcpAdapterTool('db','query')])));
  assert.throws(()=>r.prepare({tool:'query',args:'[]'}));
  assert.throws(()=>r.prepare({tool:'query',args:{extension:'evil'}}));
});
test('discovery continuation retains summaries and leaves a request for execution', () => {
  const r = mcpAdapterRuntime();
  let plan = r.prepare({tool:'target'});
  for (let page = 0; page < 3; page++) {
    plan = r.complete(plan,{...mcpAdapterInventory([mcpAdapterTool('db','page'+page)]),nextOffset:(page+1)*64});
    assert.equal(plan.requests[0].offset,(page+1)*64);
  }
  const call = r.complete(plan,mcpAdapterInventory([mcpAdapterTool('db','target')]));
  assert.equal(call.requests[0].tool,'db__target');
});
test('structured JSON extraction is deterministic and missing fields are explicit', () => {
  const r = mcpAdapterRuntime();
  const call = r.complete(r.prepare({tool:'query',extract:{total:'stats.total',missing:'absent'}}),mcpAdapterInventory([mcpAdapterTool('db','query')]));
  const result = JSON.parse(r.complete(call,{structuredContent:{stats:{total:42}}}).output);
  assert.deepEqual(result.extracted,{total:{found:true,value:42},missing:{found:false}});
  assert.equal(result.output,undefined);
  const cached = JSON.parse(r.prepare({responseId:result.responseId}).output);
  assert.match(cached.output,/structuredContent/);
  assert.equal(cached.cachedOnly,true);
});
test('unsupported capabilities and mixed modes fail rather than pretending to work', () => {
  const r = mcpAdapterRuntime();
  for (const args of [{action:'install',url:'https://example.com'},{connect:'db'},{search:'x',tool:'x'},{args:{}},{responseId:'mcp-1',tool:'x'},{tool:'x',extract:{n:'x'},limit:1}]) assert.throws(()=>r.prepare(args));
});
function contextMemoryRuntime() {
  const r = runtime(readFileSync(new URL('../../examples/plugins/context-memory.js', import.meta.url), 'utf8'));
  return {
    event: payload => r.dispatch({op:'event',name:'context_transform',payload}),
    tool: (name,args={}) => JSON.parse(r.dispatch({op:'tool',name,args}).content[0].text),
    command: args => r.dispatch({op:'command',name:'context-memory',args})
  };
}
function contextMemorySnapshot(sessionId='session-a') {
  const message = (index,role,kind,text,protect=false,toolCallId=null) => ({index,role,kind,text,protected:protect,toolCallId,chars:1000,truncated:false,fingerprint:index.toString(16).padStart(64,'0')});
  return {sessionId,eligibleEnd:6,latestUserIndex:1,messages:[
    message(0,'system','text',null,true),
    message(1,'user','text','Keep user constraints',true),
    message(2,'assistant','tool_call',null,false,'call-a'),
    message(3,'tool','tool_result','İ needle [literal]',false,'call-a'),
    message(4,'assistant','text','Earlier completed work'),
    message(5,'assistant','text','Another completed result'),
    message(6,'assistant','text','Recent result',true),
    message(7,'assistant','text','Latest result',true)
  ]};
}
test('context-memory folds are reversible request-only views with stable fingerprints', () => {
  const r = contextMemoryRuntime();
  const snapshot = contextMemorySnapshot();
  assert.deepEqual(r.event(snapshot),{folds:[]});
  const result = r.tool('compress',{from:2,to:3,summary:'Completed read; preserve its caveats.'});
  assert.equal(result.originalsDeleted,false);
  const folded = r.event(snapshot);
  assert.deepEqual(folded.folds[0].fingerprints,[snapshot.messages[2].fingerprint,snapshot.messages[3].fingerprint]);
  assert.equal(r.tool('acp_status').activeRanges.length,1);
  r.tool('decompress',{id:result.id});
  assert.deepEqual(r.event(snapshot),{folds:[]});
  assert.equal(snapshot.messages[3].text,'İ needle [literal]');
});
test('context-memory rejects protected messages, split pairs, overlaps and oversized summaries', () => {
  const r = contextMemoryRuntime(); r.event(contextMemorySnapshot());
  for (const args of [{from:0,to:1,summary:'x'},{from:1,to:2,summary:'x'},{from:2,to:2,summary:'x'},{from:3,to:3,summary:'x'},{from:6,to:7,summary:'x'},{from:4,to:4,summary:'x'.repeat(1001)},{from:4,to:4,summary:'😀'.repeat(4100)}]) assert.throws(()=>r.tool('compress',args));
  r.tool('compress',{from:2,to:4,summary:'First range'});
  assert.throws(()=>r.tool('compress',{from:4,to:5,summary:'Partial overlap'}));
});
test('context-memory merges contained ranges and invalidates stale or different sessions', () => {
  const r = contextMemoryRuntime(); const snapshot = contextMemorySnapshot(); r.event(snapshot);
  r.tool('compress',{from:2,to:3,summary:'Read result'});
  const merged = r.tool('compress',{from:2,to:5,summary:'Read result and subsequent completed work'});
  assert.equal(merged.generation,2);
  assert.equal(r.tool('acp_status').activeRanges.length,1);
  snapshot.messages[3].fingerprint='f'.repeat(64);
  assert.deepEqual(r.event(snapshot),{folds:[]});
  assert.equal(r.tool('acp_status').staleRangesDiscarded,1);
  r.event(contextMemorySnapshot('session-b'));
  assert.equal(r.tool('acp_status').sessionId,'session-b');
});
test('context-memory status excludes incomplete and duplicate tool groups', () => {
  const r = contextMemoryRuntime();
  const incomplete = contextMemorySnapshot();
  incomplete.messages = incomplete.messages.filter(message => message.index !== 3);
  r.event(incomplete);
  assert.equal(r.tool('acp_status').compressible.some(message => message.index === 2),false);
  const duplicate = contextMemorySnapshot();
  duplicate.messages[5] = {...duplicate.messages[5],kind:'tool_call',toolCallId:'call-a'};
  r.event(duplicate);
  assert.equal(r.tool('acp_status').compressible.some(message => message.index === 2),false);
  assert.throws(()=>r.tool('compress',{from:2,to:5,summary:'Duplicate tool IDs'}));
});
test('context-memory search uses literal Unicode-safe previews and summaries', () => {
  const r = contextMemoryRuntime(); r.event(contextMemorySnapshot());
  assert.equal(r.tool('search_context',{query:'NEEDLE'}).matches[0].matchOffset,2);
  assert.equal(r.tool('search_context',{query:'[literal]'}).matches[0].matchOffset,9);
  r.tool('compress',{from:2,to:3,summary:'Saved summary with constraints'});
  assert.equal(r.tool('search_context',{query:'constraints'}).matches[0].kind,'summary');
  r.command('off'); assert.deepEqual(r.event(contextMemorySnapshot()),{folds:[]});
  assert.throws(()=>r.tool('compress',{from:4,to:5,summary:'Off'}));
  r.command('on'); assert.equal(r.event(contextMemorySnapshot()).folds.length,1);
  r.command('restore'); assert.deepEqual(r.event(contextMemorySnapshot()),{folds:[]});
});
test('context_transform combines distinct hooks and rejects overlapping or malformed folds', () => {
  assert.deepEqual(runtime().dispatch({op:'event',name:'__context_transform_enabled',payload:{}}),{enabled:false});
  const fold = (from,to) => ({from,to,summary:'summary',fingerprints:Array(to-from+1).fill('0'.repeat(64))});
  const r = runtime(`pz.on('context_transform',()=>({folds:[${JSON.stringify(fold(1,2))}]}));pz.on('context_transform',()=>({folds:[${JSON.stringify(fold(3,4))}]}));`);
  assert.deepEqual(r.dispatch({op:'event',name:'__context_transform_enabled',payload:{}}),{enabled:true});
  assert.equal(r.dispatch({op:'event',name:'context_transform',payload:{}}).folds.length,2);
  for (const source of [
    `pz.on('context_transform',()=>({folds:[${JSON.stringify(fold(1,2))},${JSON.stringify(fold(2,3))}]}));`,
    "pz.on('context_transform',()=>({folds:[{from:1,to:1,summary:'x',fingerprints:['bad']}]}));",
    "pz.on('context_transform',()=>Promise.resolve({folds:[]}));"
  ]) assert.throws(()=>runtime(source).dispatch({op:'event',name:'context_transform',payload:{}}));
});
console.log(`Passed ${passed} bootstrap logic tests under Node vm; native QuickJS C limits NOT tested.`);
