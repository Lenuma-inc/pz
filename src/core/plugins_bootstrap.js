(() => {
  'use strict';
  const tools = new Map(), commands = new Map(), hooks = new Map(), state = new Map();
  const parse = JSON.parse.bind(JSON), stringify = JSON.stringify.bind(JSON);
  const events = new Set(['before_request','tool_call','tool_result','session_start','session_end']);
  const reservedCommands = new Set(['help','quit','exit','session','model','provider','tools','mcp','lsp','plugins','bg','upgrade','new','resume','tree','fork','compact','export','settings','hotkeys','login','logout','clear','cost','copy','name','reload','share','changelog','prompt','commands']);
  let sealed = false;
  function name(n) { if (typeof n !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(n)) throw Error('Invalid plugin registration name'); }
  function sync(v) { if (v && typeof v.then === 'function') throw Error('Async/Promise plugin results are not supported'); return v; }
  function registering() { if (sealed) throw Error('Plugin registrations are closed'); }
  const api = Object.freeze({
    apiVersion: 1,
    registerTool(t) {
      registering(); name(t.name);
      if (tools.size >= 64 || tools.has(t.name)) throw Error('Duplicate or excessive plugin tool: '+t.name);
      if (typeof t.description !== 'string' || !t.parameters || typeof t.parameters !== 'object' || Array.isArray(t.parameters) || typeof t.execute !== 'function') throw Error('Invalid plugin tool descriptor');
      tools.set(t.name, {name:t.name,description:t.description,parameters:parse(stringify(t.parameters)),execute:t.execute});
    },
    registerCommand(n,c) {
      registering(); name(n);
      if (commands.size >= 64 || commands.has(n) || reservedCommands.has(n) || !c || typeof c.handler !== 'function') throw Error('Invalid, duplicate or excessive plugin command');
      commands.set(n,{handler:c.handler});
    },
    on(n,f) {
      registering(); if (!events.has(n) || typeof f !== 'function') throw Error('Invalid plugin event');
      const list = hooks.get(n) || []; if (list.length >= 64) throw Error('Too many plugin event handlers'); list.push(f); hooks.set(n,list);
    },
    state:Object.freeze({get:k=>state.get(k),set:(k,v)=>{if (!state.has(k) && state.size >= 1024) throw Error('Too many state keys'); state.set(k,v);}})
  });
  Object.defineProperty(globalThis,'pz',{value:api,writable:false,configurable:false});
  Object.defineProperty(globalThis,'__pzDispatch',{value: function(raw) {
    const q = parse(raw); const ctx = Object.freeze({state:api.state});
    let result;
    if (q.op === 'list') { sealed = true; result = Array.from(tools.values(),t=>({name:t.name,description:t.description,parameters:t.parameters})); }
    else if (q.op === 'describe') { result = {tools:Array.from(tools.keys()),commands:Array.from(commands.keys()),events:Array.from(hooks.keys())}; }
    else if (q.op === 'tool') {
      const t = tools.get(q.name); if (!t) throw Error('Unknown plugin tool: '+q.name);
      result = sync(t.execute(q.args,ctx));
      if (typeof result === 'string') result = {content:[{type:'text',text:result}]};
      if (!result || !Array.isArray(result.content) || !result.content.every(c=>c && c.type === 'text' && typeof c.text === 'string')) throw Error('Invalid plugin tool result: expected string or text content');
    } else if (q.op === 'command') {
      const c = commands.get(q.name);
      result = c ? sync(c.handler(q.args,ctx)) : null;
      if (c && typeof result !== 'string') throw Error('Plugin command must return a string');
    } else if (q.op === 'event') {
      result = {};
      for (const f of hooks.get(q.name) || []) {
        const r = sync(f(q.payload,ctx));
        if (q.name === 'before_request' && r != null) {
          if (typeof r.systemPromptAppend !== 'string') throw Error('before_request must return systemPromptAppend string');
          result.systemPromptAppend = (result.systemPromptAppend ? result.systemPromptAppend + '\n\n' : '') + r.systemPromptAppend;
        }
        if (q.name === 'tool_call' && r != null) {
          if (typeof r.block !== 'boolean' || (r.reason !== undefined && typeof r.reason !== 'string')) throw Error('Invalid tool_call hook result');
          if (r.block) result = {block:true,reason:r.reason || 'Blocked by plugin'};
        }
      }
    } else throw Error('Invalid plugin dispatch');
    const out = stringify(result); if (typeof out !== 'string' || out.length > 1048576) throw Error('Plugin output exceeds limit'); return out;
  },writable:false,configurable:false});
})();
