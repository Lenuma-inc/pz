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
```

| Event | Payload | Return value |
|---|---|---|
| `session_start` | `sessionId`, `model`, `provider` | ignored |
| `before_request` | `sessionId`, `model`, `provider`, `prompt`, `systemPrompt` | nothing, or `{systemPromptAppend: string}` |
| `tool_call` | `toolName`, `toolCallId`, `input` | nothing, or `{block: boolean, reason?: string}` |
| `tool_result` | `toolName`, `toolCallId`, `output`, `isError` | ignored |
| `session_end` | `sessionId` | ignored |

Handlers run in registration order. Context additions are separated by blank
lines. A blocking decision is sticky: later handlers cannot unblock a tool.
The tool-call hook runs after argument parsing/policy checks and before approval
and dispatch. The result event observes completed dispatches; it does not cover
validation failures, policy denials, approval denials or tools blocked by a hook.
`session_end` runs after normal session completion, not as a crash/failure hook.

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
