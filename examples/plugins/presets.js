// Original pz adaptation; see README.md for inspiration and limitations.
(() => {
  const key = 'examples.presets.v1';
  const presets = {
    concise: 'Be concise. Prefer direct answers and omit unnecessary narration.',
    review: 'Review changes critically: prioritize correctness, regressions, and missing tests. Report concrete findings with file references.',
    plan: 'Planning mode (instruction only): inspect and explain a proposed plan. Do not modify files or run mutating commands unless the user explicitly exits this preset.'
  };
  pz.registerCommand('preset', { handler(args, ctx) {
    const name = (args || '').trim() || 'list';
    if (name === 'list') return 'Presets: concise, review, plan, off. Active: ' + (ctx.state.get(key) || 'off') + '. Plan is instruction-only, not a permission boundary.';
    if (name === 'off' || Object.prototype.hasOwnProperty.call(presets, name)) {
      ctx.state.set(key, name === 'off' ? null : name);
      return 'Preset: ' + name + (name === 'plan' ? ' (instruction-only; tool permissions unchanged).' : '.');
    }
    return 'Usage: /preset [list|off|concise|review|plan]';
  }});
  pz.on('before_request', (_, ctx) => {
    const name = ctx.state.get(key);
    return { systemPromptAppend: name ? '\n[User-selected preset: ' + name + ']\n' + presets[name] + '\n' : '' };
  });
})();
