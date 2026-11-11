# Native MCP discovery adapter

`mcp-adapter.js` independently adapts the core compact discovery proxy from
[nicobailon/pi-mcp-adapter](https://github.com/nicobailon/pi-mcp-adapter).
It extends pz's standard `mcp` tool instead of implementing another MCP client.

## Enable

Keep your existing native MCP server configuration. Append
`./examples/plugins/mcp-adapter.js` to your existing `plugins` array and restart
pz. Paths resolve relative to the working directory; use an absolute path when
needed. No settings are changed automatically and no server is installed.
The native `mcp` inventory tool must be available, which requires configured MCP.

While enabled, remote MCP tool schemas are omitted from model tool definitions.
Tools remain in the native registry: hiding a schema neither disables the tool
nor grants permission to call it. Native tools and tools registered by other
plugins remain visible. Disable the plugin and restart to restore the direct
model-facing MCP schemas.

## Use the standard mcp tool

Search descriptions and names without adding every schema to context:

```json
{"extension":"mcp_adapter","extension_args":"{\"search\":\"screenshot\",\"limit\":12}"}
```

Get one original input schema, retaining its constraints and references:

```json
{"extension":"mcp_adapter","extension_args":"{\"describe\":\"exact_public_tool_name\"}"}
```

Call through the original remote tool's validation, policy, hooks and approvals:

```json
{"extension":"mcp_adapter","extension_args":"{\"tool\":\"exact_public_tool_name\",\"args\":{\"query\":\"example\"}}"}
```

Exact public names come from search. A unique remote name is also accepted;
hyphens and underscores are equivalent for this alias lookup. An ambiguous
remote name is rejected unless `server` disambiguates it. The adapter never
guesses a target from a substring or sends a remote name to another server.

Other discovery examples (`extension_args` content):

```json
{}
{"server":"browser"}
{"search":"screenshot|navigate","regex":true,"offset":0,"limit":12}
```

Word search ranks matches in tool names ahead of server names and descriptions.
Regex search does not rank matches. Discovery pagination uses `offset`, `limit`
and `nextOffset`; input schemas are returned only by `describe`.

## Bounded output and deterministic extraction

Call results are cached in the plugin runtime under a `responseId`. Read more
without invoking the remote tool again:

```json
{"responseId":"mcp-1","outputOffset":12000,"outputLimit":12000}
```

Only eight results are retained, at most 64,000 JavaScript UTF-16 code units each.
The response explicitly reports clipping. Cache data is not persisted to disk;
`/mcp-adapter clear` forgets it. Offsets are not bytes. `/mcp-adapter help` shows
call examples; this is a command, not an interactive setup panel.

For JSON results, request particular fields:

```json
{"tool":"exact_public_tool_name","args":{},"extract":{"count":"stats.total","firstName":"users.0.name"}}
```

Paths select own properties from MCP `structuredContent`, or from a single JSON
text content block. Otherwise the complete MCP result object is the root.
Missing paths are marked `found: false`. This is literal JSON-path selection,
**not** upstream's model-assisted typed extraction. It does not infer values,
convert types, run code, expand schema references or call another model.

## API gaps exposed by this port

The existing argument-adapter API was insufficient. This port adds:

1. Explicit remote MCP provenance on registry entries. Plugin tools also use
   kind `mcp` internally, so kind alone is not a safe routing decision.
2. An opt-in `mcpProxy: true` capability on extensions of the native `mcp`
   inventory tool. It hides only remote MCP schemas from model requests.
3. Restricted workflow requests `{tool, args}` selecting an actual remote MCP
   entry. Native arguments remain the default request shape. Every routed
   operation re-enters the normal native tool path under its real public name.
   Builtins, plugin tools, recursive extensions and arbitrary target switching
   are not allowed by this capability.
4. Native paginated inventory and on-demand schema description, without
   exposing server commands, environment variables or authentication headers.

Workflows remain sequential and bounded to eight native calls/rounds and the
existing cumulative output budget. A failed/denied child aborts immediately;
there is no fallback or automatic retry around a refusal. Search metadata and
remote results remain untrusted data, not instructions.

## Not feature parity

This port does **not** implement upstream's lazy/idle server lifecycle, OAuth or
OS keychain, config import/install/setup UI, semantic classifier, MCP prompts,
resources, elicitation/sampling, Tasks, UI apps, saved scripts, or selective direct
tool configuration. Native pz still starts configured MCP servers as before;
**schema hiding is not lazy startup**. Existing native stdio/HTTP transports are
reused; the adapter does not add legacy SSE or a mux transport.

Those capabilities require additional host resource, authentication and UI APIs,
not just JavaScript argument rewriting. Unsupported adapter arguments fail
explicitly rather than pretending that these capabilities exist.

Regression checks live in the shared `tools/ci/test_plugins.mjs`, with native
routing/visibility checks alongside existing Zig tests. Offline JavaScript
checks do not prove live MCP transport or native authorization behavior.
