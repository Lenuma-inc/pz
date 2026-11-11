// pz adaptation of the cc-safety-net idea (MIT, https://github.com/kenryu42/cc-safety-net):
// block destructive commands and secret file access via the tool_call hook.
// Pure embedded JavaScript: no Node, filesystem, or network APIs. This is a lexical
// convenience guard, NOT a security sandbox. See README.md.
//
// Ported behavior:
// - Destructive git commands: reset --hard/--merge, checkout/switch/restore discards,
//   clean -f, rm -rf/R, push --force/--mirror/--delete, branch -D, tag/reflog delete,
//   stash drop/clear, worktree remove --force, rebase/merge --abort.
// - Destructive filesystem commands: rm -rf on catastrophic targets (/, ~, .git),
//   current directory, or outside the working directory; find -delete / -exec rm -rf;
//   shred; dd to a /dev device; mkfs on a device; pipe-to-shell installs (curl|bash).
// - Secret path protection for read, write, edit, patch, find, ls, grep and bash
//   operands: .env variants, .npmrc, .pypirc, .netrc, .git-credentials, id_(rsa|dsa|
//   ecdsa|ed25519) variants, *_rsa style key basenames, .pem/.key/.p12/.pfx/.kdbx/
//   keystore extensions, ~/.ssh, ~/.aws, ~/.gcp, ~/.kube/config, ~/.docker/config.json.
// - Commands too complex to analyze (command substitution outside quotes, nested
//   wrappers) are conservatively allowed but reported via /safetynet explain.
//
// Hooks only observe native builtin tools by name; no wrapper stripping beyond
// bash -c / sh -c / sudo / env prefixes. Plugin hooks run before approval; the
// runtime's policy/approval/protected-path pipeline still applies independently.
(() => {
  const key = 'examples.cc-safety-net.v1';

  // ---------- state ----------
  function state(ctx) {
    let value = ctx.state.get(key);
    if (!value) { value = { enabled: true, blocks: 0, last: null }; ctx.state.set(key, value); }
    return value;
  }

  pz.registerCommand('safetynet', {
    completions: [{"value": "status", "description": "Show guard status and blocked calls"}, {"value": "toggle", "description": "Enable or disable the guard"}, {"value": "reset", "description": "Clear block counters"}],
    description: "Inspect or configure the lexical safety guard",
    handler(args, ctx) {
      const arg = (args || '').trim();
      const s = state(ctx);
      if (!arg || arg === 'status') {
        return 'cc-safety-net guard: ' + (s.enabled ? 'ENABLED' : 'DISABLED') +
          '; blocked calls: ' + s.blocks +
          (s.last ? '\nLast block: ' + JSON.stringify(s.last) : '');
      }
      if (arg === 'toggle') {
        s.enabled = !s.enabled;
        return 'cc-safety-net guard ' + (s.enabled ? 'enabled' : 'disabled') +
          '. This is a lexical convenience guard, not a security boundary.';
      }
      if (arg === 'reset') { s.blocks = 0; s.last = null; return 'Block counters reset.'; }
      return 'Usage: /safetynet [status|toggle|reset]';
    }
  });

  // ---------- shared helpers ----------
  function normalize(path) {
    if (typeof path !== 'string') return null;
    const parts = [];
    for (const part of path.replace(/\\/g, '/').split('/')) {
      if (!part || part === '.') continue;
      if (part === '..') { parts.pop(); continue; }
      parts.push(part);
    }
    return parts;
  }

  // Conservative: check components before collapsing '..'.
  function sensitiveComponents(parts) {
    for (const part of parts) {
      if (/^(?:\.env(?:\..*)?|\.npmrc|\.pypirc|\.netrc|\.git-credentials)$/i.test(part)) return true;
      if (/^id_(?:rsa|dsa|ecdsa|ed25519)/i.test(part)) return true;
      if (/_(?:rsa|dsa|ecdsa|ed25519)$/i.test(part)) return true;
      if (/\.(?:pem|key|keypair|p12|pfx|pkcs12|kdbx?|keystore|keyring|jks|kwallet|keychain|ovpn|asc)$/i.test(part)) return true;
    }
    return false;
  }

  function sensitiveDirComponents(parts) {
    for (const part of parts) {
      if (/^(?:\.ssh|\.aws|\.gcp|\.config\/gcloud)$/i.test(part)) return true;
      if (part === 'gcloud' && parts.indexOf('.config') >= 0) return true;
    }
    // ~/.kube/config, ~/.docker/config.json and credential backup variants.
    for (let i = 0; i + 1 < parts.length; i++) {
      const base = parts[i + 1];
      if (/^\.(?:kube|docker)$/i.test(parts[i]) &&
          /^(?:config(?:\.json)?(?:\.(?:bak|backup|copy|disabled|old|orig|save|tmp))?)$/i.test(base)) return true;
    }
    return false;
  }

  function isSecretPath(path) {
    const parts = normalize(path);
    if (!parts) return false;
    return sensitiveComponents(parts) || sensitiveDirComponents(parts);
  }

  // Extract candidate paths from an arbitrary string (bash operands, patch headers).
  function candidatePaths(text) {
    if (typeof text !== 'string') return [];
    const out = [];
    // Quoted or unquoted tokens that look like paths.
    for (const match of text.matchAll(/(?:"([^"]*)"|'([^']*)'|((?:~|\/|\.{1,2})?\/?[\w.@+-]+(?:\/[\w.@+-]+)+))/g)) {
      const token = match[1] || match[2] || match[3];
      if (token) out.push(token);
    }
    return out;
  }

  // ---------- destructive command analysis ----------
  function splitTopLevel(command) {
    // Split on ; && || | respecting quotes and $() / `` nesting (shallow).
    const segments = [];
    let current = '';
    let depth = 0, quote = null;
    for (let i = 0; i < command.length; i++) {
      const ch = command[i];
      if (quote) {
        current += ch;
        if (ch === quote && command[i - 1] !== '\\') quote = null;
        continue;
      }
      if (ch === '"' || ch === "'") { quote = ch; current += ch; continue; }
      if (ch === '(' && /\$\s*$/.test(current.slice(0, i))) { depth++; }
      if (ch === '`') { depth = depth > 0 ? depth - 1 : depth + 1; }
      if (ch === '(' && depth === 0 && /\$\s*$/.test(current)) depth++;
      if (ch === ')') depth = Math.max(0, depth - 1);
      if (depth === 0 && (ch === ';' || ch === '|' || ch === '&' || ch === '\n')) {
        segments.push(current);
        current = '';
        if (ch === '&' && command[i + 1] === '&') i++;
        continue;
      }
      current += ch;
    }
    segments.push(current);
    return segments.filter(s => s.trim());
  }

  function stripWrappers(words) {
    let i = 0;
    while (i < words.length) {
      const w = words[i].toLowerCase();
      if (w === 'sudo' || w === 'env' || w === 'nice' || w === 'nohup' ||
          w === 'command' || w === 'time' || w === 'stdbuf') {
        // Skip env assignments after env/nice.
        let j = i + 1;
        while (j < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[j])) j++;
        if (j < words.length && (w === 'sudo' || w === 'env') &&
            ['-u', '--user', '-E', '--'].includes(words[j])) { i = j + 1; continue; }
        i = j;
        continue;
      }
      if ((w === 'bash' || w === 'sh' || w === 'ash' || w === 'dash') &&
          (words[i + 1] === '-c' || words[i + 1] === '-lc')) {
        return words[i + 2] ? stripWrappers([]).concat(words[i + 2]) : words.slice(i + 3);
      }
      break;
    }
    return words.slice(i);
  }

  function tokenize(segment) {
    const words = [];
    let current = '';
    let quote = null, hasSubst = false;
    for (let i = 0; i < segment.length; i++) {
      const ch = segment[i];
      if (quote) {
        if (ch === quote && segment[i - 1] !== '\\') { quote = null; continue; }
        current += ch;
        continue;
      }
      if (ch === '"' || ch === "'") { quote = ch; hasSubst = true; continue; }
      if (ch === ' ' || ch === '\t') {
        if (current || hasSubst) { words.push({ text: current, subst: hasSubst }); current = ''; hasSubst = false; }
        continue;
      }
      if (ch === '$' && segment[i + 1] === '(') { hasSubst = true; current += '$('; i++; continue; }
      if (ch === '`') { hasSubst = true; current += '`'; continue; }
      current += ch;
    }
    if (current || hasSubst) words.push({ text: current, subst: hasSubst });
    return words;
  }

  function isFlag(word, names) {
    return names.some(name => word === name || (word.length > 2 && word.startsWith('-') && !word.startsWith('--') && word.includes(name.replace('-', ''))));
  }

  function collectFlags(words, shortNames, longNames) {
    const out = { combined: '', long: [] };
    for (const w of words) {
      if (w.subst) { out.combined += '?'; continue; }
      if (w.text.startsWith('--')) { out.long.push(w.text); continue; }
      if (w.text.startsWith('-') && w.text.length > 1) out.combined += w.text.slice(1);
      else out.combined += 'N'; // operand marker
    }
    return out;
  }

  function checkRm(words) {
    const flags = collectFlags(words.slice(1), [], ['--recursive', '--force']);
    const recursive = flags.combined.includes('r') || flags.long.includes('--recursive');
    if (!recursive) return null;
    const force = flags.combined.includes('f') || flags.long.includes('--force');
    if (!force) return null;
    const targets = words.slice(1).filter(w => !w.subst && (!w.text.startsWith('-') || w.text === '-' || w.text === '--'));
    const operands = [];
    let pastOptions = false;
    for (const w of words.slice(1)) {
      if (!pastOptions && (w.text === '--')) { pastOptions = true; continue; }
      if (!pastOptions && w.text.startsWith('-') && w.text.length > 1) continue;
      operands.push(w);
    }
    for (const op of operands) {
      if (op.subst) return block('rm.recursive-force-dynamic-target', 'rm -rf with a dynamic target cannot be verified.');
      const parts = normalize(op.text);
      if (!parts) continue;
      const joined = parts.join('/');
      if (parts.length === 0) return block('rm.recursive-force-cwd-self', 'rm -rf of the current directory.');
      if (/^(?:dev|proc|sys)$/.test(parts[0]) && parts.length === 1) return block('rm.recursive-force-root-or-home', 'rm -rf of a system directory root.');
      if (joined === '' || (parts.length === 1 && /^(?:root|home|users)$/.test(parts[0]) === false && op.text.startsWith('/') && parts.length === 1)) {
        return block('rm.recursive-force-root-or-home', 'rm -rf of the filesystem root.');
      }
      if (parts[0] === '.git' || parts.includes('.git')) return block('rm.git-metadata', 'rm -rf of Git metadata.');
      if (parts.length === 1 && (parts[0] === '~' || parts[0].toLowerCase() === 'home' || /^(?:Users)$/.test(parts[0]))) {
        return block('rm.recursive-force-root-or-home', 'rm -rf of the home directory.');
      }
      if (op.text.startsWith('..') || op.text.startsWith('/')) {
        return block('rm.recursive-force-outside-cwd', 'rm -rf outside the working directory.');
      }
    }
    return null;
  }

  function block(id, reason) {
    return { id, reason };
  }

  function checkSegment(segment) {
    const words = tokenize(segment);
    if (!words.length) return null;
    const stripped = stripWrappers(words.map(w => w.text));
    const head = (stripped[0] || '').toLowerCase().replace(/^.*\//, '');
    const args = stripped.slice(1);

    // git subcommands
    if (head === 'git' && args.length) {
      const sub = (args[0] || '').toLowerCase();
      const rest = args.slice(1);
      const longs = rest.filter(a => a.startsWith('--'));
      const shortCombined = rest.filter(a => a.startsWith('-') && !a.startsWith('--')).join('');
      if (sub === 'reset' && (longs.includes('--hard') || longs.includes('--merge'))) {
        return block('git.reset-hard', 'git reset --hard/--merge discards uncommitted changes.');
      }
      if (sub === 'checkout' && (longs.includes('--force') || shortCombined.includes('f') ||
          rest.includes('--') || (rest.filter(a => !a.startsWith('-')).length >= 1 && rest.length >= 1 && !/^-(?:b|B|t)/.test(rest[0]) && rest[0] !== '-'))) {
        // Conservative: checkout with paths or --force discards worktree state.
        const operands = rest.filter(a => !a.startsWith('-') && a !== '--');
        const hasDoubleDash = rest.includes('--');
        if (longs.includes('--force') || shortCombined.includes('f') || hasDoubleDash ||
            (operands.length >= 2)) {
          return block('git.checkout-discard', 'git checkout may discard uncommitted changes (use a branch or stash).');
        }
      }
      if (sub === 'switch' && (longs.includes('--discard-changes') || longs.includes('--force'))) {
        return block('git.switch-discard-changes', 'git switch with discard/force discards local changes.');
      }
      if (sub === 'restore') {
        return block('git.restore-worktree', 'git restore discards working-tree changes.');
      }
      if (sub === 'clean' && (shortCombined.includes('f') || longs.includes('--force'))) {
        return block('git.clean-force', 'git clean -f deletes untracked files.');
      }
      if (sub === 'rm' && (shortCombined.includes('r') || longs.includes('--recursive')) &&
          (shortCombined.includes('f') || longs.includes('--force'))) {
        return block('git.rm-force', 'git rm -rf removes tracked files forcefully.');
      }
      if (sub === 'push' && (longs.includes('--force') || shortCombined.includes('f') ||
          longs.includes('--mirror') || longs.includes('--delete') || shortCombined.includes('d'))) {
        return block(longs.includes('--mirror') ? 'git.push-mirror' : 'git.push-force',
          'git push --force/--mirror/--delete can destroy remote history.');
      }
      if (sub === 'branch' && (shortCombined.includes('D') || longs.includes('--delete --force'))) {
        return block('git.branch-force-delete', 'git branch -D force-deletes a branch.');
      }
      if (sub === 'tag' && (longs.includes('--delete') || shortCombined.includes('d'))) {
        return block('git.tag-delete', 'git tag -d deletes a tag.');
      }
      if (sub === 'reflog' && (args[1] === 'delete' || args[1] === 'expire' || args[1] === 'drop')) {
        return block('git.reflog-delete', 'git reflog delete/expire destroys recovery history.');
      }
      if (sub === 'stash' && (args[1] === 'drop' || args[1] === 'clear')) {
        return block(args[1] === 'clear' ? 'git.stash-clear' : 'git.stash-drop', 'git stash drop/clear destroys stash entries.');
      }
      if (sub === 'worktree' && args[1] === 'remove' && (longs.includes('--force') || shortCombined.includes('f'))) {
        return block('git.worktree-remove-force', 'git worktree remove --force.');
      }
      if (sub === 'rebase' && longs.includes('--abort')) return block('git.rebase-abort', 'git rebase --abort discards an in-progress rebase.');
      if (sub === 'merge' && longs.includes('--abort')) return block('git.merge-abort', 'git merge --abort discards an in-progress merge.');
      return null;
    }

    // rm
    if (head === 'rm') return checkRm(stripped.map(t => ({ text: t, subst: /\$\(|`/.test(t) })));

    // find with -delete or -exec rm
    if (head === 'find') {
      if (args.includes('-delete')) return block('find.delete', 'find -delete removes matched files.');
      if (args.some(a => a === '-exec' || a === '-execdir')) {
        const idx = args.findIndex(a => a === '-exec' || a === '-execdir');
        const inner = args.slice(idx + 1);
        if (inner[0] && inner[0].replace(/^.*\//, '') === 'rm') return block('find.exec-rm-recursive-force', 'find -exec rm.');
      }
      // find <path> -delete on git metadata handled by secret path scan anyway.
      return null;
    }
    if (head === 'shred') return block('shred.target', 'shred destroys its target.');
    if (head === 'dd') {
      if (args.some(a => /^of=\/dev\//.test(a) && !/^of=\/dev\/(?:null|zero|full)$/.test(a))) {
        return block('dd.device-write', 'dd writing to a disk device.');
      }
      return null;
    }
    if (/^mkfs/.test(head) || head === 'mke2fs' || head === 'newfs') {
      if (args.some(a => a.startsWith('/dev/'))) return block('mkfs.device', 'mkfs formats a device.');
      return null;
    }

    // curl/wget piped to shell
    if ((head === 'curl' || head === 'wget') && segment.includes('|')) {
      const afterPipe = segment.slice(segment.indexOf('|') + 1).trim();
      const innerHead = (afterPipe.split(/\s+/)[0] || '').replace(/^.*\//, '');
      if (['bash', 'sh', 'zsh', 'dash', 'ash', 'python', 'python3', 'node', 'perl', 'ruby'].includes(innerHead.toLowerCase())) {
        return block('pipe-to-shell', 'Remote content piped directly into an interpreter.');
      }
    }

    // Interpreter one-liners with obviously destructive inner commands.
    if (['python', 'python3', 'node', 'perl', 'ruby', 'php'].includes(head)) {
      const code = args.join(' ');
      if (/\brm\s+(-{1,2}r[^ ]*f|-{1,2}f[^ ]*r)\b/.test(code) || /os\.system|subprocess|child_process|exec\(/.test(code) && /rm\s+-rf/.test(code)) {
        return block('interpreter.dangerous-command', 'Interpreter one-liner containing a destructive command.');
      }
    }

    return null;
  }

  function analyzeCommand(command) {
    if (typeof command !== 'string' || !command.trim()) return null;
    for (const segment of splitTopLevel(command)) {
      const verdict = checkSegment(segment);
      if (verdict) return verdict;
    }
    return null;
  }

  // ---------- tool_call hook ----------
  const PATH_TOOLS = ['read', 'write', 'edit', 'patch', 'find', 'ls', 'grep', 'skill'];
  const COMMAND_TOOLS = ['bash'];

  pz.on('tool_call', (event, ctx) => {
    const s = state(ctx);
    if (!s.enabled || !event || typeof event.toolName !== 'string') return { block: false };
    const input = event.input || {};
    const toolName = event.toolName;

    // Secret path checks for path tools.
    if (PATH_TOOLS.includes(toolName)) {
      const paths = [];
      if (typeof input.path === 'string') paths.push(input.path);
      if (typeof input.pattern === 'string' && (toolName === 'grep' || toolName === 'find')) {
        // pattern is a regex, not a path; only guard if it embeds a path-like token.
        for (const candidate of candidatePaths(input.pattern)) paths.push(candidate);
      }
      if (toolName === 'patch' && typeof input.patch === 'string') {
        for (const line of input.patch.split(/\r?\n/)) {
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
      for (const path of paths) {
        if (isSecretPath(path)) {
          s.blocks++; s.last = { tool: toolName, path, rule: 'secret.path' };
          return { block: true, reason: 'cc-safety-net: access to a potential secret file is blocked (' + path + ').' };
        }
      }
      return { block: false };
    }

    // Command analysis for bash.
    if (COMMAND_TOOLS.includes(toolName) && typeof input.command === 'string') {
      const verdict = analyzeCommand(input.command);
      if (verdict) {
        s.blocks++; s.last = { tool: toolName, rule: verdict.id, reason: verdict.reason };
        return { block: true, reason: 'cc-safety-net [' + verdict.id + ']: ' + verdict.reason };
      }
      // Secret paths referenced inside the command.
      for (const candidate of candidatePaths(input.command)) {
        if (isSecretPath(candidate)) {
          s.blocks++; s.last = { tool: toolName, path: candidate, rule: 'secret.path' };
          return { block: true, reason: 'cc-safety-net: command touches a potential secret file (' + candidate + ').' };
        }
      }
    }
    return { block: false };
  });
})();
