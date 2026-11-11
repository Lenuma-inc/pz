// Convenience guard only: NOT a security sandbox. See README.md.
(() => {
  function protectedPath(path) {
    if (typeof path !== 'string') return false;
    const parts = [];
    for (const part of path.replace(/\\/g, '/').split('/')) {
      if (!part || part === '.') continue;
      // Check before collapsing '..' too: conservative about sensitive components.
      if (/^(?:\.git|\.env(?:\..*)?|id_(?:rsa|dsa|ecdsa|ed25519))$/i.test(part) || /\.(?:pem|key|p12|pfx)$/i.test(part)) return true;
      if (part === '..') parts.pop(); else parts.push(part);
    }
    return false;
  }
  pz.on('tool_call', event => {
    if (!event || !['write', 'edit', 'patch'].includes(event.toolName)) return { block: false };
    const input = event.input || {};
    const paths = [input.path];
    if (event.toolName === 'patch' && typeof input.patch === 'string') {
      for (const line of input.patch.split(/\r?\n/)) {
        // Native patch uses input.path; inspect other common patch headers defensively.
        const match = /^(?:--- |\+\+\+ |rename from |rename to |\*\*\* (?:Add File|Update File|Delete File|Move to): )(.*)$/.exec(line);
        if (match) {
          let path = match[1].split('\t')[0].trim();
          if (path[0] === '"' && path[path.length - 1] === '"') path = path.slice(1, -1);
          paths.push(path);
        }
        const diff = /^diff --git (.*)$/.exec(line);
        if (diff) paths.push(...diff[1].split(/\s+/));
      }
    }
    return paths.some(protectedPath)
      ? { block: true, reason: 'Example protected-paths guard: direct modification of environment, Git, or private-key paths is blocked.' }
      : { block: false };
  });
})();
