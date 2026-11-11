// Independent native adaptation of nicobailon/pi-web-access (MIT).
// No Node, subprocesses, browser cookies, external fetch proxy, or yt-dlp.
(() => {
  'use strict';
  const key = 'examples.web-access.v1';
  const maxEntries = 8;
  const maxContent = 120000;
  const operations = ['search', 'fetch', 'source_check', 'get_search_content', 'youtube'];
  function fail(message) { throw Error('web_access: ' + message); }
  function text(value, name, max = 4000) {
    if (typeof value !== 'string' || !value.trim() || value.length > max) fail('invalid ' + name);
    return value.trim();
  }
  function integer(value, fallback, low, high, name) {
    if (value === undefined) return fallback;
    if (!Number.isInteger(value) || value < low || value > high) fail('invalid ' + name);
    return value;
  }
  function url(value) {
    const result = text(value, 'url', 8000);
    if (!/^https?:\/\/[^\s/@?#]+(?::[0-9]+)?(?:[/?#]|$)/i.test(result) || /[\x00-\x20\x7f]/.test(result)) fail('expected an HTTP(S) URL without credentials');
    return result;
  }
  function list(single, multiple, name) {
    if (single !== undefined && multiple !== undefined) fail('use ' + name + ' or ' + name + 's, not both');
    const result = multiple === undefined ? [single] : multiple;
    if (!Array.isArray(result) || !result.length || result.length > 4) fail('expected 1–4 ' + name + 's');
    return result.map(value => text(value, name, 8000));
  }
  function state(ctx) { return ctx.state.get(key) || { next: 1, entries: [] }; }
  function store(ctx, items, kind) {
    const s = state(ctx);
    const responseId = 'web-' + s.next++;
    const entry = { responseId, kind, items };
    s.entries.push(entry);
    if (s.entries.length > maxEntries) s.entries.shift();
    ctx.state.set(key, s);
    return entry;
  }
  function page(entry, args) {
    const index = integer(args.index, 0, 0, entry.items.length - 1, 'index');
    const item = entry.items[index];
    const offset = integer(args.offset, 0, 0, item.content.length, 'offset');
    const limit = integer(args.limit, 12000, 1, 24000, 'limit');
    if (args.findText !== undefined) {
      const needle = text(args.findText, 'findText', 500);
      if (args.findMode !== undefined && !['exact', 'case-insensitive'].includes(args.findMode)) fail('findMode must be exact or case-insensitive');
      const insensitive = args.findMode !== 'exact';
      // Match against the original string: Unicode lowercasing may change length.
      const matcher = new RegExp(needle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), insensitive ? 'gi' : 'g');
      matcher.lastIndex = offset;
      const passages = [];
      let match = matcher.exec(item.content);
      let at = match ? match.index : -1;
      let size = 0;
      while (at >= 0 && passages.length < 10 && size < limit) {
        const start = Math.max(0, at - 300);
        const end = Math.min(item.content.length, at + needle.length + 300, start + limit - size);
        const passage = item.content.slice(start, end);
        passages.push({ offset: start, matchOffset: at, text: passage });
        size += passage.length;
        match = matcher.exec(item.content);
        at = match ? match.index : -1;
      }
      return { workflow: true, output: JSON.stringify({ responseId: entry.responseId, index, source: item.source, passages, cachedOnly: true }) };
    }
    const end = Math.min(item.content.length, offset + limit);
    return { workflow: true, output: JSON.stringify({ responseId: entry.responseId, index, source: item.source, content: item.content.slice(offset, end), nextOffset: end < item.content.length ? end : null, nativeOutputClipped: item.clipped, cachedOnly: true }) };
  }
  function searchRequests(args, claim) {
    if (args.provider !== undefined && args.provider !== 'exa' && args.provider !== 'auto') fail('this native port currently supports Exa search only');
    if (args.recencyFilter !== undefined) fail('recencyFilter requires structured native search filters; not silently approximated');
    const queries = args.query === undefined && args.queries === undefined && claim ? [claim] : list(args.query, args.queries, 'query');
    const count = integer(args.numResults, 5, 1, 10, 'numResults');
    let suffix = '';
    if (args.domainFilter !== undefined) {
      if (!Array.isArray(args.domainFilter) || args.domainFilter.length > 10) fail('domainFilter must contain at most 10 domains');
      const include = [], exclude = [];
      for (const value of args.domainFilter) {
        const d = text(value, 'domainFilter', 254);
        if (!/^-?(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$/i.test(d)) fail('invalid domainFilter hostname');
        if (d[0] === '-') exclude.push('-site:' + d.slice(1));
        else include.push('site:' + d);
      }
      // Query operators, not a security filter or guaranteed provider-side restriction.
      suffix = (include.length ? ' (' + include.join(' OR ') + ')' : '') + (exclude.length ? ' ' + exclude.join(' ') : '');
    }
    return { workflow: true, requests: queries.map(query => ({ query: query + suffix, num_results: count })), context: { kind: claim ? 'source_check' : 'search', sources: queries, claim: claim || null, fetchContent: claim ? args.fetchContent !== false : args.includeContent === true } };
  }
  pz.registerToolExtension({
    tool: 'web', name: 'web_access',
    description: 'Native pi-web-access adaptation: multi-query Exa search, multi-page fetch, cached paging and literal passage finding, source evidence, YouTube metadata (not transcripts/video analysis). Uses ordinary web authorization. No yt-dlp. Cache contains bounded native output, not guaranteed full pages.',
    parameters: {
      type: 'object', additionalProperties: false,
      properties: {
        op: { type: 'string', enum: operations },
        query: { type: 'string' }, queries: { type: 'array', items: { type: 'string' }, minItems: 1, maxItems: 4 },
        url: { type: 'string' }, urls: { type: 'array', items: { type: 'string' }, minItems: 1, maxItems: 4 },
        includeContent: { type: 'boolean' }, fetchContent: { type: 'boolean' },
        numResults: { type: 'integer', minimum: 1, maximum: 10 }, provider: { type: 'string', enum: ['auto', 'exa'] },
        domainFilter: { type: 'array', items: { type: 'string' }, maxItems: 10, description: 'Search query site: operators; prefix - to exclude. Not a strict filter.' },
        mode: { type: 'string', enum: ['readable', 'raw'] },
        from_line: { type: 'integer', minimum: 1 }, to_line: { type: 'integer', minimum: 1 }, line_offset: { type: 'integer', minimum: 0 },
        pattern: { type: 'string' }, json_path: { type: 'string' }, claim: { type: 'string' },
        responseId: { type: 'string' }, index: { type: 'integer', minimum: 0 }, offset: { type: 'integer', minimum: 0 },
        limit: { type: 'integer', minimum: 1, maximum: 24000 }, findText: { type: 'string' }, findMode: { type: 'string', enum: ['exact', 'case-insensitive'] }
      }, required: ['op']
    },
    prepare(args, ctx) {
      if (!operations.includes(args.op)) fail('unknown operation');
      const allowed = {
        search: ['query', 'queries', 'numResults', 'provider', 'domainFilter', 'includeContent'],
        source_check: ['claim', 'query', 'queries', 'numResults', 'provider', 'domainFilter', 'fetchContent'],
        fetch: ['url', 'urls', 'mode', 'from_line', 'to_line', 'line_offset', 'pattern', 'json_path'],
        youtube: ['url'],
        get_search_content: ['responseId', 'index', 'offset', 'limit', 'findText', 'findMode']
      };
      for (const field of Object.keys(args)) if (field !== 'op' && !allowed[args.op].includes(field)) fail('unsupported argument for ' + args.op + ': ' + field);
      if (args.op === 'get_search_content') {
        const id = text(args.responseId, 'responseId', 64);
        const entry = state(ctx).entries.find(item => item.responseId === id);
        if (!entry) fail('unknown or expired responseId; cache is session-local and holds the last ' + maxEntries + ' responses');
        return page(entry, args);
      }
      for (const field of ['includeContent', 'fetchContent']) if (args[field] !== undefined && typeof args[field] !== 'boolean') fail(field + ' must be boolean');
      if (args.op === 'search') return searchRequests(args);
      if (args.op === 'source_check') return searchRequests(args, text(args.claim, 'claim'));
      if (args.op === 'youtube') {
        const source = url(args.url);
        const match = source.match(/^https?:\/\/(?:www\.|m\.)?(?:youtube\.com\/(?:watch\?(?:[^#]*&)?v=|shorts\/|embed\/)|youtu\.be\/)([A-Za-z0-9_-]{11})(?:[?&#/]|$)/i);
        if (!match) fail('expected a YouTube watch, shorts, embed or youtu.be URL');
        const canonical = 'https://www.youtube.com/watch?v=' + match[1];
        return { workflow: true, requests: [{ url: 'https://www.youtube.com/oembed?format=json&url=' + encodeURIComponent(canonical) }], context: { kind: 'youtube_metadata', sources: [canonical] } };
      }
      if (args.mode !== undefined && args.mode !== 'raw' && args.mode !== 'readable') fail('mode must be readable or raw');
      if (args.mode === 'raw' && args.json_path !== undefined) fail('raw mode cannot use json_path');
      const sources = list(args.url, args.urls, 'url').map(url);
      const from = integer(args.from_line, 1, 1, 1000000, 'from_line');
      const to = integer(args.to_line, from + 399, from, 1000000, 'to_line');
      const lineOffset = integer(args.line_offset, 0, 0, 100000000, 'line_offset');
      return { workflow: true, requests: sources.map(source => {
        const request = { url: source, format: args.mode === 'raw' ? 'raw' : 'auto', from_line: from, to_line: to, line_offset: lineOffset };
        if (args.pattern !== undefined) request.pattern = text(args.pattern, 'pattern', 1000);
        if (args.json_path !== undefined) request.json_path = text(args.json_path, 'json_path', 1000);
        return request;
      }), context: { kind: 'fetch', sources } };
    },
    complete(results, context, ctx) {
      if (!context || !Array.isArray(context.sources) || !Array.isArray(results) || results.length !== context.sources.length) fail('invalid workflow result');
      const items = results.map((result, index) => {
        if (result.isError || typeof result.output !== 'string') fail('native request failed');
        return { source: context.sources[index], content: result.output.slice(0, maxContent), clipped: result.output.length > maxContent };
      });
      if (context.fetchContent) {
        const sources = [];
        // Only explicit result URL fields/links, never instructions from fetched text.
        for (const item of items) {
          const links = item.content.matchAll(/(?:^URL:\s*|\]\()(https?:\/\/[^\s<>\)\"]+)/gm);
          for (const match of links) {
            const source = url(match[1]);
            if (!sources.includes(source)) sources.push(source);
            if (sources.length >= 4) break;
          }
          if (sources.length >= 4) break;
        }
        if (sources.length) return {
          workflow: true,
          requests: sources.map(source => ({ url: source, from_line: 1, to_line: 400 })),
          context: { kind: context.kind, claim: context.claim, sources, previous: items }
        };
      }
      const entry = store(ctx, (context.previous || []).concat(items), context.kind);
      const note = context.kind === 'source_check' ? 'Evidence search only: these sources do not establish whether the claim is true. Read sources and compare cited passages.' : context.kind === 'youtube_metadata' ? 'YouTube oEmbed metadata only; no transcript, audio, frames or video understanding.' : 'Stored native output may be paginated or truncated; follow native continuation with a new fetch, not cache offsets.';
      return { workflow: true, output: JSON.stringify({ responseId: entry.responseId, kind: entry.kind, claim: context.claim || undefined, note, items: entry.items.map((item, index) => ({ index, source: item.source, content: item.content.slice(0, 6000), nextOffset: item.content.length > 6000 ? 6000 : null, nativeOutputClipped: item.clipped })) }) };
    }
  });
  pz.registerCommand('webaccess', {
    description: 'Show native web-access features and bounded session cache',
    completions: [{ value: 'status', description: 'Show capabilities and cached response IDs' }, { value: 'clear', description: 'Forget cached web responses in this session' }],
    handler(args, ctx) {
      const arg = (args || '').trim();
      if (arg === 'clear') { ctx.state.set(key, { next: state(ctx).next, entries: [] }); return 'Web-access cache cleared.'; }
      if (arg && arg !== 'status') return 'Usage: /webaccess [status|clear]';
      return 'web extension: web_access\nOperations: ' + operations.join(', ') + '\nSearch: native Exa. No yt-dlp, browser cookies, hosted fetch fallback, PDF conversion, or video analysis.\nCache: ' + (state(ctx).entries.map(entry => entry.responseId + ' (' + entry.kind + ')').join(', ') || 'empty');
    }
  });
})();
