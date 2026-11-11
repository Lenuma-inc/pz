# JavaScript plugins (API v1)

pz embeds QuickJS-ng. Plugins do not require Node, npm, a separate interpreter,
or a plugin-host process. This is a pz API, **not** a pi extension compatibility
layer. TypeScript, ES modules, npm packages and pi packages are not supported.

## Enable a plugin

Add explicit script paths to `~/.pz/settings.json`, `.pz/settings.json`, or an
explicit configuration file:

```json
{"plugins": ["./examples/plugins/hello.js"]}
```

Relative paths resolve against the process working directory, not the settings
file. Use absolute paths in global settings when launching from different
projects. There is no directory scanning, package download or installation at
startup. Scripts are read in configured order. Restart pz after editing them.

`"plugins": false` or `"plugins": []` disables plugins, overriding an earlier
configuration layer. Without enabled scripts, no JavaScript runtime is created.
`/plugins` lists the registered tools, commands and event subscriptions. RPC
clients can send `{"cmd":"plugins"}` or invoke custom commands using
`{"cmd":"hello","arg":"world"}`. Slash commands are available in the TUI;
print-mode prompts are still model prompts, not a command execution interface.

## API

A script runs in its own function scope with the global `pz` object.
`pz.apiVersion` is `1`. Register everything while the script loads; registration
is closed before commands, tools or event handlers run. Names must match
`[A-Za-z0-9_-]{1,128}`. Builtin tool/command names and duplicate registrations are
rejected; custom commands cannot override pz commands.

```javascript
pz.registerCommand("hello", {
  description: "Greet someone",
  completions: [
    { value: "world", description: "Greet the whole world" },
    { value: "team", description: "Greet the team" }
  ],
  handler(args, ctx) {
    return `Hello, ${args || "world"}!`;
  }
});

pz.registerTool({
  name: "greet",
  description: "Produce a greeting for a supplied name",
  parameters: {
    type: "object",
    properties: {name: {type: "string"}},
    required: ["name"],
    additionalProperties: false
  },
  execute(args, ctx) {
    if (typeof args.name !== "string") throw new Error("name must be a string");
    return `Hello, ${args.name}!`;
  }
});
```

Command handlers return strings. Tool handlers return either a string or an
object with `content: [{type: "text", text: "..."}]` and optional JSON details.
The object is returned as JSON tool output. Parameters are a JSON Schema exposed
to the model; handlers must validate their inputs. Custom tools use the normal
policy/approval pipeline and are conservatively marked destructive. Their
internal dynamic-dispatch kind is shared with MCP, but no MCP server is started.

All callbacks are synchronous. Promise/thenable results are rejected. There are
no timers, background jobs or async host APIs.

## Extending existing tools

`pz.registerToolExtension({tool, name, description, parameters, prepare})`
registers a named argument adapter for an existing tool. `tool` is its exact
registry name, not a hardcoded capability list: any builtin can be extended,
including tools added later. The same mechanism works with other registered
tools by name. It does not create a tool, enable a disabled tool, or replace its
dispatch implementation. Registrations for unavailable targets cannot execute.

Call the original tool with only `extension` (the registered extension name)
and optional `extension_args` (a JSON object encoded as a string). Native
arguments cannot be mixed with this envelope. `prepare(args, ctx)` receives the
decoded object and synchronously returns a native argument object for that
same tool, or one of the multi-step result shapes described below. Handlers must validate their input; `parameters` describes it to the
model, rather than providing automatic JSON Schema validation. The runtime also
accepts an object for `extension_args`, but advertises a string in tool schemas.

Preparation happens once, before native argument parsing, authorization, tool
hooks, approval and execution. These stages see the derived arguments, including
paths, URLs and operations. Returning another extension envelope is rejected;
there is no recursive dispatch, arbitrary target switching, direct network access
or shell access from JavaScript. The opt-in MCP proxy capability below permits
only routing to registered native remote MCP entries. Errors stop the call rather than falling back to the
original operation. Ordinary calls retain their original behavior.

### Multi-step extensions

An extension can additionally register `complete(results, context, ctx)`.
Instead of native arguments, `prepare` can return a bounded plan explicitly
marked with `workflow: true`. The marker is required so native fields such as
ffmpeg's `output` are never mistaken for extension results:

```javascript
pz.registerToolExtension({
  tool: 'web', name: 'compare_pages',
  description: 'Read two pages through the ordinary web tool',
  parameters: { type: 'object' },
  prepare(args) {
    return {
      workflow: true,
      requests: [{ url: 'https://example.com/a' }, { url: 'https://example.com/b' }],
      context: { label: 'Comparison sources' }
    };
  },
  complete(results, context, ctx) {
    return { workflow: true, output: context.label + '\n' + results.map(r => r.output).join('\n\n') };
  }
});
```

`requests` contains native argument objects for the **same target tool**, never
extension envelopes. Each request independently passes through native parsing,
authorization, `tool_call` hooks, approval, execution and `tool_result` hooks.
The host executes requests sequentially outside the JavaScript callback; this
is not direct JavaScript network access or a general tool-switching API.
`complete` receives `{output, isError}` results and the JSON `context` returned
with the plan. It may return another plan or a final
`{workflow: true, output: string, isError?: boolean}`. A failed/denied native request aborts the
workflow without invoking `complete`; extensions cannot retry around a denial.

There are at most eight requests and eight rounds per invocation, and bounded
final output (256 KiB). Nested extension calls are rejected. A pure cached read
may return the marked final-output shape directly from `prepare`, without a native
request. It does not grant new host capabilities; state is still local to the
plugin runtime. Existing native argument adapters remain compatible. See the
[web-access adaptation](../examples/plugins/WEB_ACCESS.md) for a real consumer.

### MCP discovery proxies

An extension of the native `mcp` inventory tool may declare `mcpProxy: true`.
This explicit capability omits remote MCP schemas from model-facing tool
requests without removing entries from the registry. It does not hide native
or plugin-defined tools; both can internally share kind `mcp`, so the host
checks remote provenance rather than relying on the kind or name prefix.

Such an extension may include a routed workflow request:

```javascript
{ workflow: true, requests: [{ tool: exactPublicMcpName, args: remoteArgs }] }
```

`tool` must resolve to a registered remote MCP entry. The same native parsing,
authorization, hooks and approval path executes under that entry's real name.
Routing to builtins, plugin-defined tools, other extensions, or unavailable
targets is rejected. Other extensions retain same-target native argument
requests. Remote arguments must be objects and cannot contain extension or
workflow envelopes. The host validates the capability independently of the
JavaScript callback.

The standard native inventory supports paginated `list` and on-demand
`describe` of one original input schema. The
[MCP adapter example](../examples/plugins/MCP_ADAPTER.md) demonstrates this API.
It does not grant server installation, process lifecycle, OAuth, filesystem,
or general cross-tool execution capabilities.

Only tools with matching registered extensions receive an alternative envelope
in their model-facing schema. The original native schema remains an alternative.
Extension descriptions and parameter schemas are included in request guidance
and `/plugins` output. Registration is closed after loading, with at most 64
extensions in total and no duplicate `(tool, name)` pairs. Existing plugin
read-only and enforced-policy restrictions still apply.

Development API checks: `node tools/ci/test_plugins.mjs`. They exercise
the JavaScript bootstrap, not native execution or authorization.

## Events and context

```javascript
pz.on("before_request", (event, ctx) => ({
  systemPromptAppend: "Prefer small, reviewable changes."
}));

pz.on("tool_call", (event, ctx) => {
  if (event.toolName === "write" && event.input.path.endsWith(".env")) {
    return {block: true, reason: "This plugin protects .env files"};
  }
});

pz.on("footer_render", (event, ctx) => {
  // Customize the TUI footer: up to 2 rows of up to 32 segments each.
  return {
    rows: [
      [{text: " model ", fg: 0xffffff, bg: 0x375a7f}, {text: "\ue0b0", fg: 0x375a7f}],
      [{text: "secondary info", fg: 0xaaaaaa}]
    ]
  };
});
```

| Event | Payload | Return value |
|---|---|---|
| `session_start` | `sessionId`, `model`, `provider` | ignored |
| `before_request` | `sessionId`, `model`, `provider`, `prompt`, `systemPrompt` | nothing, or `{systemPromptAppend: string}` |
| `tool_call` | `toolName`, `toolCallId`, `input` | nothing, or `{block: boolean, reason?: string}` |
| `tool_result` | `toolName`, `toolCallId`, `output`, `isError` | ignored |
| `footer_render` | `width`, `height`, `model`, `provider`, `thinking`, `cwd`, `branch`, `inputTokens`, `outputTokens`, `cacheRead`, `cacheWrite`, `contextTokens`, `contextLimit`, `costMicents`, `subscription`, `turns`, `backgroundRunning`, `limits` | nothing, or `{rows: Array<Array<{text: string, fg?: number, bg?: number}>>}` |
| `session_end` | `sessionId` | ignored |

Handlers run in registration order. Context additions are separated by blank
lines. A blocking decision is sticky: later handlers cannot unblock a tool.
The tool-call hook runs after argument parsing/policy checks and before approval
and dispatch. The result event observes completed dispatches; it does not cover
validation failures, policy denials, approval denials or tools blocked by a hook.
`session_end` runs after normal session completion, not as a crash/failure hook.

The `footer_render` event fires before the TUI footer is rendered, providing
terminal dimensions, model/provider/thinking state, path, branch, token counts,
context usage, cost and quota data. A handler can return `{rows: [...]}` with up
to 2 rows of up to 32 segments each. Each segment has `text` (string, max 2048
bytes, no control characters U+0000–U+001F or U+007F–U+009F) and optional `fg`/`bg`
colors (24-bit RGB integers 0x000000–0xFFFFFF). The native renderer handles
wcwidth clipping for wide glyphs and applies the final layout. Returning nothing
or an empty/absent `rows` array delegates to the built-in footer. The event is
disabled under read-only tool masks and enforced policy mode, matching other
plugin restrictions. See `examples/plugins/powerline-footer.js` for a complete
implementation with responsive layout, presets and powerline separators.

Context hooks append instructions for the outgoing request. They do **not**
rewrite durable history, replace messages, override compaction, or implement a
model provider. Those extension points are not part of v1.

## State

`ctx.state` and `pz.state` provide `get(key)` and `set(key, value)`. State lives
only for the current plugin runtime and is lost on process exit. The map is
shared by scripts; namespace your keys, e.g. `my-plugin:counter`. A script can
also retain private state in its registration closures.

## Restrictions and trust

This embedding exposes no filesystem, network, process, environment, shell,
module loader or QuickJS libc APIs. Plugins can compute results, register tools
and commands, and add context or block calls; they cannot directly run a shell,
fetch URLs or read files. Native builtin tools remain responsible for those
operations and their permissions. Only load trusted scripts: this is not an
OS-level security boundary against an interpreter vulnerability.

Enforced policy mode refuses enabled plugins. Read-only SME/reviewer swarm
members do not inherit plugin configuration. Plugin tools, custom commands and
hooks are disabled under read-only tool masks (none of write/edit/bash/patch).
A plugin cannot bypass builtin
command precedence, policy authorization, tool approval, or protected-path checks.
Hook errors are surfaced rather than silently ignored.

Limits shared by a runtime:

- at most 32 scripts, each at most 1 MiB;
- at most 64 tools and 64 commands;
- at most 64 handlers per event and 1024 state keys;
- 16 MiB QuickJS heap and 512 KiB JS stack;
- a one-second interpreter interrupt deadline per script/callback dispatch;
- 1 MiB JSON input/output limit.

The deadline is an interpreter interrupt, not a separate process watchdog.
Plugins run serially under a mutex. Multiple enabled scripts add initialization
work, and subscribed hooks add work to their corresponding operations; plugin
execution is not zero-cost.

## Verification

`tools/ci/test_plugins.mjs` exercises bootstrap/API logic with Node's existing
VM as a **development test tool only**; Node is not linked, launched or required
by pz. These tests do not validate the native QuickJS ABI or native limits.
Native tests live in `src/core/plugins.zig` and the regular Zig test suite.
