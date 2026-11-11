(() => {
  'use strict';
  const extensions = new Map();
  const tools = new Map(), commands = new Map(), hooks = new Map(), state = new Map();
  const parse = JSON.parse.bind(JSON), stringify = JSON.stringify.bind(JSON);
  const events = new Set(['before_request','context_transform','tool_call','tool_result','session_start','session_end','footer_render']);
  const reservedCommands = new Set(['help','quit','exit','session','model','provider','tools','mcp','lsp','plugins','bg','upgrade','new','resume','tree','fork','compact','export','settings','hotkeys','login','logout','clear','cost','copy','name','reload','share','changelog','prompt','commands']);
  let sealed = false;
  function name(n) { if (typeof n !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(n)) throw Error('Invalid plugin registration name'); }
  function sync(v) { if (v && typeof v.then === 'function') throw Error('Async/Promise plugin results are not supported'); return v; }
  function validateFinal(result) {
    if (result.workflow !== true || Object.keys(result).some(k=>k !== 'workflow' && k !== 'output' && k !== 'isError') || typeof result.output !== 'string' || result.output.length > 262144 || (result.isError !== undefined && typeof result.isError !== 'boolean')) throw Error('Invalid extension output');
  }
  function validateWorkflow(result,t) {
    if (result.workflow !== true || typeof t.complete !== 'function' || Object.keys(result).some(k=>k !== 'workflow' && k !== 'requests' && k !== 'context') || !Array.isArray(result.requests) || result.requests.length < 1 || result.requests.length > 8 || result.requests.some(r=>!r || typeof r !== 'object' || Array.isArray(r) || 'extension' in r || 'extension_args' in r || 'workflow' in r)) throw Error('Invalid extension workflow');
  }
  function registering() { if (sealed) throw Error('Plugin registrations are closed'); }
  const api = Object.freeze({
    apiVersion: 1,
    registerTool(t) {
      registering(); name(t.name);
      if (tools.size >= 64 || tools.has(t.name)) throw Error('Duplicate or excessive plugin tool: '+t.name);
      if (typeof t.description !== 'string' || !t.parameters || typeof t.parameters !== 'object' || Array.isArray(t.parameters) || typeof t.execute !== 'function') throw Error('Invalid plugin tool descriptor');
      tools.set(t.name, {name:t.name,description:t.description,parameters:parse(stringify(t.parameters)),execute:t.execute});
    },
    registerToolExtension(t) {
      registering(); name(t.name);
      name(t.tool);
      if (typeof t.description !== 'string' || !t.parameters || typeof t.parameters !== 'object' || Array.isArray(t.parameters) || typeof t.prepare !== 'function' || (t.complete !== undefined && typeof t.complete !== 'function')) throw Error('Invalid tool extension descriptor');
      if (t.mcpProxy !== undefined && (t.mcpProxy !== true || t.tool !== 'mcp')) throw Error('Invalid MCP proxy capability');
      const key = t.tool+':'+t.name;
      if (extensions.size >= 64 || extensions.has(key)) throw Error('Duplicate or excessive tool extension');
      extensions.set(key,{tool:t.tool,name:t.name,description:t.description,parameters:parse(stringify(t.parameters)),prepare:t.prepare,complete:t.complete,...(t.mcpProxy === true ? {mcpProxy:true} : {})});
    },
    registerCommand(n,c) {
      registering(); name(n);
      if (commands.size >= 64 || commands.has(n) || reservedCommands.has(n) || !c || typeof c.handler !== 'function') throw Error('Invalid, duplicate or excessive plugin command');
      if (c.completions !== undefined && (!Array.isArray(c.completions) || c.completions.length > 128 || c.completions.some(v => typeof v === 'string' ? v.length > 256 : !v || typeof v.value !== 'string' || v.value.length > 256 || typeof v.description !== 'string' || v.description.length > 1024))) throw Error('Invalid plugin command completions');
      commands.set(n,{handler:c.handler,description:typeof c.description === 'string' ? c.description : '',completions:c.completions ? c.completions.map(v => typeof v === 'string' ? {value:v,description:''} : {value:v.value,description:v.description}) : []});
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
    else if (q.op === 'describe') { result = {tools:Array.from(tools.keys()),commands:Array.from(commands.keys()),command_details:Array.from(commands,([name,c])=>({name,desc:c.description,args:c.completions.map(v=>v.value),arg_desc:c.completions.map(v=>v.description)})),events:Array.from(hooks.keys()),extensions:Array.from(extensions.values(),({tool,name,description,parameters,mcpProxy})=>({tool,name,description,parameters,...(mcpProxy === true ? {mcpProxy:true} : {})}))}; }
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
      if (q.name === '__tool_extensions') result = Array.from(extensions.values(),({tool,name,description,parameters,mcpProxy})=>({tool,name,description,parameters,...(mcpProxy === true ? {mcpProxy:true} : {})}));
      if (q.name === '__context_transform_enabled') result = {enabled:hooks.has('context_transform')};
      if (q.name === '__prepare_tool_extension') {
        const {tool,args} = q.payload;
        name(tool);
        if (!args || typeof args !== 'object' || Array.isArray(args) || typeof args.extension !== 'string') throw Error('Invalid extension request');
        const t = extensions.get(tool+':'+args.extension);
        if (!t) throw Error('Unknown tool extension');
        if (Object.keys(args).some(k=>k !== 'extension' && k !== 'extension_args')) throw Error('Extension calls cannot mix native arguments');
        const input = typeof args.extension_args === 'string' ? parse(args.extension_args) : (args.extension_args === undefined ? {} : args.extension_args);
        if (!input || typeof input !== 'object' || Array.isArray(input)) throw Error('Invalid extension arguments');
        result = sync(t.prepare(input,ctx));
        if (!result || typeof result !== 'object' || Array.isArray(result) || 'extension' in result || 'extension_args' in result) throw Error('Invalid or recursive extension result');
        if ('workflow' in result) {
          if ('requests' in result) validateWorkflow(result,t);
          else validateFinal(result);
        }
      }
      if (q.name === '__complete_tool_extension') {
        const {tool,name:extension,results,context} = q.payload;
        const t = extensions.get(tool+':'+extension);
        if (!t || typeof t.complete !== 'function') throw Error('Missing extension completion callback');
        if (!Array.isArray(results) || results.length < 1 || results.length > 8 || results.some(r=>!r || typeof r.output !== 'string' || r.isError !== false)) throw Error('Invalid extension results');
        result = sync(t.complete(results,context,ctx));
        if (!result || typeof result !== 'object' || Array.isArray(result) || 'extension' in result || 'extension_args' in result) throw Error('Invalid extension completion');
        if ('requests' in result) validateWorkflow(result,t);
        else validateFinal(result);
      }
      if (q.name === 'before_request' && extensions.size) result.systemPromptAppend = 'Available builtin tool extensions (call the same tool with only extension and extension_args as a JSON object string; derived native operations retain normal validation and approval):\n'+stringify(Array.from(extensions.values(),({tool,name,description,parameters,mcpProxy})=>({tool,name,description,parameters,...(mcpProxy === true ? {mcpProxy:true} : {})})));
      for (const f of hooks.get(q.name) || []) {
        const r = sync(f(q.payload,ctx));
        if (q.name === 'before_request' && r != null) {
          if (typeof r.systemPromptAppend !== 'string') throw Error('before_request must return systemPromptAppend string');
          result.systemPromptAppend = (result.systemPromptAppend ? result.systemPromptAppend + '\n\n' : '') + r.systemPromptAppend;
        }
        if (q.name === 'context_transform' && r != null) {
          if (!r || typeof r !== 'object' || Array.isArray(r) || Object.keys(r).some(k=>k !== 'folds') || !Array.isArray(r.folds) || r.folds.length > 32) throw Error('Invalid context_transform result');
          const folds = (result.folds || []).concat(r.folds);
          if (folds.length > 32 || folds.some(f=>!f || typeof f !== 'object' || Array.isArray(f) || Object.keys(f).some(k=>!['from','to','summary','fingerprints'].includes(k)) || !Number.isSafeInteger(f.from) || !Number.isSafeInteger(f.to) || f.from < 0 || f.to < f.from || typeof f.summary !== 'string' || f.summary.length < 1 || f.summary.length > 16000 || !Array.isArray(f.fingerprints) || f.fingerprints.length !== f.to-f.from+1 || f.fingerprints.some(s=>typeof s !== 'string' || !/^[0-9a-f]{64}$/.test(s)))) throw Error('Invalid context_transform folds');
          folds.sort((a,b)=>a.from-b.from);
          if (folds.some((f,i)=>i && folds[i-1].to >= f.from)) throw Error('Overlapping context_transform folds');
          result.folds = folds;
        }
        if (q.name === 'footer_render' && r != null) {
          if (!Array.isArray(r.rows) || r.rows.length > 2 || !r.rows.every(row =>
            Array.isArray(row) && row.length <= 32 && row.every(s => s &&
              typeof s.text === 'string' && s.text.length <= 2048 && !/[\x00-\x1f\x7f-\x9f]/.test(s.text) &&
              ['fg','bg'].every(k => s[k] === undefined || (Number.isInteger(s[k]) && s[k] >= 0 && s[k] <= 0xffffff)))))
            throw Error('Invalid footer_render result');
          result = {rows:r.rows};
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
