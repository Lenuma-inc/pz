// Counts observations, not guaranteed executions (another hook may block a call).
(() => {
  const key = 'examples.tool-stats.v1';
  function stats(ctx) {
    let value = ctx.state.get(key);
    if (!value) { value = { calls: 0, results: 0, errors: 0, tools: [] }; ctx.state.set(key, value); }
    return value;
  }
  function record(event, ctx, result) {
    const s = stats(ctx);
    const name = event && typeof event.toolName === 'string' ? event.toolName.slice(0, 128) : '(unknown)';
    let row = s.tools.find(item => item.name === name);
    if (!row) {
      const label = s.tools.length < 63 ? name : '(other)';
      row = s.tools.find(item => item.name === label);
      if (!row) { row = { name: label, calls: 0, results: 0, errors: 0 }; s.tools.push(row); }
    }
    const field = result ? 'results' : 'calls';
    s[field] = Math.min(Number.MAX_SAFE_INTEGER, s[field] + 1);
    row[field] = Math.min(Number.MAX_SAFE_INTEGER, row[field] + 1);
    if (result && event && event.isError === true) {
      s.errors = Math.min(Number.MAX_SAFE_INTEGER, s.errors + 1);
      row.errors = Math.min(Number.MAX_SAFE_INTEGER, row.errors + 1);
    }
  }
  pz.on('tool_call', (event, ctx) => { record(event, ctx, false); return { block: false }; });
  pz.on('tool_result', (event, ctx) => { record(event, ctx, true); });
  pz.registerCommand('toolstats', { handler(args, ctx) {
    const arg = (args || '').trim();
    if (arg === 'reset') { ctx.state.set(key, null); return 'Tool statistics reset.'; }
    if (arg) return 'Usage: /toolstats [reset]';
    const s = stats(ctx);
    return ['Observed calls: ' + s.calls + '; results: ' + s.results + '; errors: ' + s.errors,
      ...s.tools.map(t => t.name + ': calls=' + t.calls + ', results=' + t.results + ', errors=' + t.errors)].join('\n');
  }});
})();
