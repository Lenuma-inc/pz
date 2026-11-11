# Small native pz plugin pack

Five original, dependency-free JavaScript examples for pz's embedded QuickJS API.
Inspired by the workflow ideas in the official [pi extension examples](https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent/examples/extensions)
(presets, protected paths, tool statistics, notes and handoffs). These are original
pz adaptations, not copied implementations or a pi compatibility layer. No Node,
TypeScript, npm, filesystem, network or process APIs are used.

## Enable

Merge the `plugins` array from [settings.json](settings.json) into your own
`.pz/settings.json`, `~/.pz/settings.json`, or explicit configuration file.
Do not overwrite unrelated settings. Nothing in this pack edits your settings.
Paths resolve relative to the **process working directory**, not the settings
file; the supplied paths assume you launch from the pz repository root. Use
absolute paths elsewhere or in global configuration. Existing plugin arrays may
need to be combined manually. Restart pz after changing scripts or configuration.
All registrations happen at startup. Scripts can be enabled separately, in any
order, and coexist with `hello.js`; no directory scanning or installation occurs.
See [the native API documentation](../../docs/PLUGINS.md).

## Commands and behavior

| Script | Interface | Behavior |
| --- | --- | --- |
| `presets.js` | `/preset [list\|off\|concise\|review\|plan]` | Select one prompt appendix; `off` removes it on subsequent requests. Default lists choices and current selection. |
| `protected-paths.js` | `tool_call` hook | Blocks observed direct `write`, `edit`, `patch` modifications to protected lexical paths. |
| `cc-safety-net.js` | `/safetynet [status\|toggle\|reset]`; `tool_call` hook | pz adaptation of the cc-safety-net idea (MIT): blocks destructive git/filesystem commands (`git reset --hard`, `git push --force`, `rm -rf` of root/home/`.git`/cwd/outside targets, `find -delete`, `shred`, `dd` to devices, `mkfs`, `curl\|bash`) and secret file access (`.env*`, `.npmrc`, key files, `~/.ssh`, `~/.aws`, etc.) across `bash`, file and patch tools. Lexical guard only, not a sandbox. |
| `tool-stats.js` | `/toolstats [reset]` | Counts observed calls, results and `isError` results by exact `event.toolName`; reset clears counters. |
| `session-notes.js` | `/notes [list\|add text\|clear]`; model tool `session_note` | Maintain small ephemeral notes. Only the user command can clear them. |
| `handoff.js` | `/handoff [goal]` | Emit Markdown containing the current maintained goal, notes and observed session/model/provider metadata. |

Presets do **not** change tool permissions. In particular, `plan` is an
instruction-only request to avoid mutation, not enforced read-only mode. Turning
a preset off stops future appendices; it cannot erase existing conversation text.

The protected-path guard normalizes slash/backslash separators and dot components
and conservatively rejects sensitive components even before `..` collapse.
It protects `.git`, `.env` and **all `.env.*`, including `.env.example`**,
`id_rsa`, `id_dsa`, `id_ecdsa`, `id_ed25519`, and filenames ending in `.pem`,
`.key`, `.p12` or `.pfx` (case insensitive). This intentionally includes public
or example files with those names. Native tools use `input.path`; `patch` also
has `input.patch`. The guard additionally examines unified patch headers,
Git rename headers and common `*** ... File:` / `*** Move to:` headers, including
multiple files, conservatively even though the native patch tool targets one
explicit path. It does not parse or execute patch contents. Header-like hunk
text can produce conservative false positives; this is not comprehensive patch
syntax validation or a multi-file security boundary.

**This guard is NOT a security sandbox.** It does not cover bash, interpreters,
custom tools, symlink resolution, filesystem aliases or arbitrary alternate
patch syntaxes. It cannot prevent another plugin or process from modifying
files. Use pz's actual policy and sandbox controls for security.

Statistics count hook observations, not guaranteed executions: calls can be
blocked, results may be absent, and plugin hook ordering affects observations.
There are at most 64 buckets (overflow becomes `(other)`), names are capped at
128 characters, and counters saturate at JavaScript's maximum safe integer.

Notes are limited to 32 entries of 1000 characters each. `/notes add text` and
`session_note` with `{ "op": "add", "text": "..." }` append; `{ "op": "list" }`
lists. Invalid input returns usage or a limit message; the tool cannot clear or
remove notes. Notes are appended to requests as a JSON array clearly labeled
untrusted reference data, not instructions. This labeling is not an injection
security guarantee: avoid storing secrets or hostile text.

Handoff reads the shared `ctx.state` key `examples.session-notes.v1` (an array
of note strings), so either load order works and the notes script is optional.
`/handoff goal` updates its current goal (maximum 2000 characters); `/handoff`
reuses it. Metadata comes only from `session_start` / `before_request` events,
is capped at 256 characters per field, and displays unavailable until observed.
Goal, notes and metadata are JSON-escaped in the Markdown output. Handoff does
not read the transcript, invent a summary, invoke a model, save a file or create
a new session. Copy its output manually.

All state is in-memory for the lifetime of the plugin runtime: nothing is
persisted across restart. Notes, goal, counters and preset are not automatically
cleared by session lifecycle events; clear/reset them explicitly when reusing a
runtime. State keys are namespaced under `examples.*.v1`; scripts use a fixed
number of keys and bounded collections. No registration happens inside hooks,
commands or tool execution.
