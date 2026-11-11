// Native pz adaptation of nicobailon/pi-powerline-footer's segmented footer idea.
// Independent implementation; no Node, shell, timers, or filesystem access.
(() => {
  let preset = 'default';
  const presets = ['default', 'minimal', 'compact', 'full', 'ascii'];
  pz.registerCommand('powerline', {
    description: 'Select footer preset: default, minimal, compact, full, ascii, off',
    handler(args) {
      const value = (args || '').trim();
      if (!value) return 'Powerline footer: ' + preset + '. Presets: ' + presets.join(', ') + ', off.';
      if (value !== 'off' && !presets.includes(value)) return 'Usage: /powerline [default|minimal|compact|full|ascii|off]';
      preset = value;
      return 'Powerline footer: ' + preset + '.';
    }
  });
  const clean = value => String(value || '').replace(/[\x00-\x1f\x7f-\x9f]/g, '').slice(0, 256);
  const count = n => n >= 1000000 ? (n / 1000000).toFixed(1) + 'm' : n >= 1000 ? (n / 1000).toFixed(1) + 'k' : String(n || 0);
  const colors = [0x375a7f, 0x375b48, 0x535067, 0x555555, 0x67532d, 0x424242];
  pz.on('footer_render', e => {
    if (preset === 'off') return;
    const ascii = preset === 'ascii';
    const model = clean(e.model) || '(model unavailable)';
    const path = clean(e.cwd).replace(/\\/g, '/').replace(/\/$/, '').split('/').pop() || '/';
    const branch = clean(e.branch);
    const context = e.contextLimit > 0 ? ((e.contextTokens || 0) / e.contextLimit * 100).toFixed(1) + '%' : 'ctx n/a';
    const cost = e.subscription ? 'subscription' : '$' + ((e.costMicents || 0) / 100000).toFixed(2);
    let labels;
    if (preset === 'minimal') labels = [path, branch, context];
    else if (preset === 'compact') labels = [model, branch, context, cost];
    else labels = [model, clean(e.thinking), path, branch, context, cost];
    // Priority in narrow terminals: model (or path), then context, then cost.
    if (e.width < 60) labels = preset === 'minimal' ? [path, context] : [model, context];
    if (e.width < 24) labels = [context];
    labels = labels.filter(Boolean);
    const rows = [[]];
    // Use a conservative per-segment budget; native renderer handles actual wcwidth
    // clipping, including wide glyphs and the final powerline triangle.
    const budget = Math.max(1, Math.floor(e.width / Math.max(1, labels.length)) - 3);
    labels = labels.map(text => Array.from(text).slice(0, budget).join(''));
    labels.forEach((text, i) => {
      const bg = colors[i % colors.length];
      rows[0].push({text: ' ' + text + ' ', fg: 0xffffff, bg});
      if (ascii) rows[0].push({text: '|', fg: 0xaaaaaa});
      else rows[0].push({text: '\ue0b0', fg: bg, ...(i + 1 < labels.length ? {bg: colors[(i + 1) % colors.length]} : {})});
    });
    // Preserve native quota information even in compact/minimal modes.
    const secondary = [clean(e.limits)];
    if (preset !== 'minimal') {
      secondary.push('in ' + count(e.inputTokens), 'out ' + count(e.outputTokens));
      if (e.cacheRead) secondary.push('cache ' + count(e.cacheRead));
    }
    if (preset === 'full' || ascii) {
      secondary.push('turn ' + (e.turns || 0));
      if (e.backgroundRunning) secondary.push('jobs ' + e.backgroundRunning);
    }
    if (e.height > 1) rows.push([{text: secondary.filter(Boolean).join(' | '), fg: 0xaaaaaa}]);
    return {rows};
  });
})();
