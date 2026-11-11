# Native web-access adaptation

`web-access.js` is an independent adaptation of the core research workflow in
[nicobailon/pi-web-access](https://github.com/nicobailon/pi-web-access), not a
TypeScript/Node compatibility shim or a feature-complete copy. It extends the
existing `web` tool with `extension: "web_access"`; it registers no replacement
network tool and never invokes `yt-dlp` or other subprocesses.

## Enable

Append the path `./examples/plugins/web-access.js` to your existing `plugins`
array and restart pz. Paths are relative to the process working directory; use
an absolute path when appropriate. Do not replace unrelated configuration.
The standard `web` tool must be enabled. Search uses the native Exa integration
and its existing optional `EXA_API_KEY`; the plugin receives no credentials.
`/webaccess status` shows capabilities and cache IDs; `/webaccess clear` forgets
cached results. Nothing installs or enables the plugin automatically.

## Call the standard web tool

```json
{"extension":"web_access","extension_args":"{\"op\":\"search\",\"queries\":[\"Zig HTTP client\",\"Zig HTTP client redirects\"],\"numResults\":3,\"includeContent\":true}"}
```

```json
{"extension":"web_access","extension_args":"{\"op\":\"fetch\",\"urls\":[\"https://example.com/a\",\"https://example.com/b\"],\"from_line\":1,\"to_line\":200}"}
```

```json
{"extension":"web_access","extension_args":"{\"op\":\"source_check\",\"claim\":\"The API supports conditional requests\"}"}
```

Responses include a `responseId` and indexed items. Read a cached item or find
literal passages without another HTTP request:

```json
{"extension":"web_access","extension_args":"{\"op\":\"get_search_content\",\"responseId\":\"web-1\",\"index\":0,\"offset\":6000,\"limit\":12000}"}
```

```json
{"extension":"web_access","extension_args":"{\"op\":\"get_search_content\",\"responseId\":\"web-1\",\"index\":0,\"findText\":\"ETag\",\"findMode\":\"case-insensitive\"}"}
```

YouTube metadata uses the public oEmbed endpoint:

```json
{"extension":"web_access","extension_args":"{\"op\":\"youtube\",\"url\":\"https://www.youtube.com/watch?v=abcdefghijk\"}"}
```

This returns metadata only, **not a transcript or video understanding**.

## Behavior and limits

- `search`: 1–4 queries, 1–10 results each. `provider` is `auto` or `exa`.
  `domainFilter` adds `site:` / `-site:` query operators, not a guaranteed
  provider-side filter or security boundary. `includeContent: true` fetches up
  to four distinct explicitly linked search result URLs in a second step.
- `fetch`: 1–4 HTTP(S) URLs; native readable/raw mode, regex `pattern`,
  `json_path`, and line pagination. Native redirect, address, egress, size,
  extraction, redaction and approval rules remain authoritative.
- `source_check`: searches for the claim (or supplied `query`/`queries`), then
  fetches up to four linked sources unless `fetchContent: false`. It collects
  evidence, **not an automated truth verdict**. Read and compare sources.
- `get_search_content`: pages cached native output or finds at most ten literal
  passages (`exact` / `case-insensitive`). Offsets are JavaScript UTF-16 string
  offsets, not HTTP byte offsets or native `line_offset` values.
- The cache holds eight response groups, at most 120,000 characters per item,
  within the plugin runtime. It is not persisted to disk. Cached content may
  already contain native pagination/truncation: follow the native continuation
  using another `fetch`, rather than assuming the cache holds the full page.
- Workflow requests run sequentially, not concurrently. At most eight native
  requests execute per extension invocation. Every request goes through normal
  native validation, policy, hooks and approval. A failed/denied child aborts the
  workflow; no fallback is attempted. Cached reads do not perform network I/O.
- Search results and page text remain untrusted data. The plugin never executes
  page-provided code or interprets page text as host instructions.

Not ported: the upstream provider matrix, login/browser-cookie access,
automatic hosted extraction fallbacks, GitHub cloning, PDF conversion, semantic
field extraction/curator UI, local video analysis and transcript acquisition.
Use pz's existing `github` for source browsing and `ffmpeg` for local video.
Unsupported options are rejected instead of silently pretending to work.

The API additions demonstrated by this port are bounded multi-request tool
extensions, completion callbacks over native results, continuation plans, and
local cached results. See [PLUGINS.md](../../docs/PLUGINS.md).

Offline adapter checks are in `tools/ci/test_web_access.mjs`; those checks do
not prove live HTTP behavior or native policy integration.
