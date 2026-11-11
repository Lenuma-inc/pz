# pz

A security-first coding harness rewritten from the ground up in Zig for enterprise environments. `pz` is not a generic extensible agent platform, for now: the goal is peace of mind through built-in security, policy, and auditability.

## Measured footprint

Local Linux x86_64 measurements on 2026-10-30 with Zig 0.16.0 and
`zig build -Doptimize=ReleaseFast` at commit `c43627bf6b51`:

| Measurement | Result | Scope / method |
|---|---:|---|
| Zig source lines | 96,570 | Physical lines in 153 `src/**/*.zig` files, including comments, blank lines and tests |
| Separate test-module lines | 7,074 | `src/test/**/*.zig`; included above, excludes inline tests elsewhere |
| Binary size | 16.7 MiB | `zig-out/bin/pz`, unstripped, with debug info |
| CLI startup | 1.02 ms | Median of 25 `pz --version` runs; includes process creation |
| CLI peak RAM (RSS) | 2.8 MiB | `pz --version`, Linux `/usr/bin/time -f %M` |

Line counts include tests and are not a production-only code count. These are
local ReleaseFast measurements; CLI startup/RAM do not describe an active TUI,
agent turn or provider response. TUI memory was not remeasured successfully in
this run. The Linux binary is dynamically linked to glibc and libm; bash
sandboxing also requires `bwrap`.

For comparison, the same local Debug build measured 62.4 MiB on disk,
26.36 ms startup and 9.2 MiB peak CLI RSS. ReleaseFast is about 3.7× smaller
even with debug info retained.

## Features

### Harness

- **Interactive TUI** — streaming responses, markdown rendering, syntax highlighting
- **Image rendering** — Kitty graphics protocol support in terminal
- **Slash commands** — `/model`, `/fork`, `/export`, `/compact`, `/share`, `/tree`, and more
- **Autocomplete dropdown** — fuzzy-filtered command and file path completion
- **18 built-in tools** — `read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`, `ask`, `web`, `skill`, `agent`, `patch`, `todo`, `github`, `swarm`, `ffmpeg`, `lsp`, `mcp`
- **Skills** — discoverable `/skillname` slash commands with frontmatter, registry, and policy gating
- **Session management** — persist, resume, fork, name, export, share as gist
- **OpenAI OAuth + API key auth** — automatic token refresh for Codex/OpenAI authentication
- **Subscription quotas** — the footer shows used percentages from Codex stream events after a completed request. Window labels follow the reported duration (5h, week, month); missing quota data shows `limits: n/a`. API-key responses may not include subscription quotas.
- **Thinking levels** — OpenAI model metadata determines available levels through max. Shift+Tab skips unsupported levels; adjustments are shown explicitly.
- **Prompt caching** — automatic cache_control on system messages
- **Headless modes** — `--print`, `--json`, and `rpc` for scripting and integration
- **Agent tool** — spawn subagents with dedicated RPC fd, progress streaming, process group isolation
- **Swarm tool** — collaborating live workers with addressed messages and explicit wait/stop/close operations
- **File attachments** — local text, images, documents and bounded video-frame extraction; clipboard images enter the outgoing prompt
- **Zero-alloc hot path** — rendering and input handling avoid heap allocations

### Security

- **Signed policy bundles** — Ed25519-verified policy with lock mode, generation rollback resistance, and expiry
- **Tool sandbox** — process group isolation, env scrubbing, TERM→KILL escalation
- **Linux workspace sandbox** — read the host filesystem, write only the workspace and `/tmp`, block network access. Python environments keep access to their installed interpreters; temporary files and tool caches use `/tmp`. A bash call with `sandbox_permissions: "require_escalated"` and `justification` asks the user to approve that command outside the sandbox. Denial, missing interactive approval, or a verified policy blocks escalation. Explicit `--yolo` runs bash outside the sandbox without approval prompts; project context still requires explicit trust. The flag is rejected when a signed policy is enforced.
- **Egress policy** — deny-by-default endpoint allowlists, bounded deadlines, policy-bound proxy
- **TOCTOU guards** — fd-pinned tool I/O with `readlinkat`/`O_NOFOLLOW`, hardlink rejection, root confinement
- **Symlink escape prevention** — component-by-component path walk for tool paths and context files
- **Shell tokenizer** — parse `bash -c`, quoting, command substitution for policy-driven command denial
- **Prompt injection boundaries** — untrusted content wrapped with provenance markers, context budgets
- **DNS rebinding protection** — private-range blocking on web tool and redirect hops
- **Secret zeroization** — Ed25519 seed/keypair wiped after use
- **Absolute-path commands** — `/share`, `/copy`, editor, paste use absolute paths, not PATH resolution

### Audit

- **Structured audit log** — typed events with severity, outcome, HMAC-SHA256 chained integrity
- **Syslog shipping** — RFC 5424 UDP/TCP with TLS hooks, hostname resolution, reconnect backoff
- **Durable spool** — file-backed audit spool with ordered resend on collector reconnect
- **Keyed redaction** — HMAC-based per-session pseudonyms, non-correlatable across deployments
- **Privileged action audit** — export, share, copy, model change, subagent, editor launch tracked
- **Pipeline sanitization** — ANSI/control stripping and secret redaction for `--print`/`--json` output

### Enterprise

- **Canonical `.pz/` layout** — settings, auth, policy, sessions, audit under one root
- **Signed self-update** — Ed25519 manifest verification, key ring with rollback/downgrade detection, crash-safe install
- **Context-bound approvals** — tool kind, cwd, repo root, policy hash, session lifetime binding
- **LRU approval cache** — bounded eviction for context-bound approvals
- **Fail-closed policy** — unknown keys rejected, unsigned policies rejected in lock mode
- **Secure local storage** — 0700/0600 perms, atomic writes (temp+fsync+rename), O_NOFOLLOW confinement
- **Event loop** — epoll (Linux) and kqueue (macOS/BSD) backends

### Testing

- **Automated coverage** — unit, integration, snapshot (ohsnap), and property (zcheck) tests
- **PTY harness** — real-process TUI tests with ANSI AST parsing
- **Mock infrastructure** — provider, syslog, HTTP, cancel, time mocks
- **Allocator regression** — test-allocator proofs for UAF and leak safety

## Build

The minimum [Zig](https://ziglang.org) version declared in `build.zig.zon` is 0.16.0.

```
zig build
```

The binary lands in `zig-out/bin/pz`.

On Linux, bash execution requires `bubblewrap` (`bwrap`) on `PATH` and permission to create user and network namespaces. A temporary root exposes system directories read-only, mounts the workspace writable, and blocks shell network access.

For an optimized local build:

```sh
zig build -Doptimize=ReleaseFast
```

Builds read the commit hash from Git and require a Git checkout. Release builds embed `CHANGELOG.md`; Debug builds use Git history.

## Run

```
# Canonical state lives under ~/.pz/ and ./.pz/
pz

# Explicit provider and model
pz --provider openai --model gpt-6.1-sol

# Resume a session
pz resume          # picker (also: pz -r)
pz resume --last   # most recent (also: pz -c)
pz resume 123      # specific session ID

# Headless
pz print "explain this codebase"
echo '{"prompt":"hello"}' | pz json

# Run without approval prompts (bash has your filesystem and network access)
pz print --yolo "Investigate this repository"

# Choose a supported reasoning effort
pz --thinking low
```

### Named OpenAI-compatible endpoints

In the TUI, run `/login openai-compatibility`. The wizard asks for a unique
provider name, an HTTPS API base URL, and an API key (masked). It checks the
`/models` endpoint and saves credentials privately under `~/.pz/`; editing
configuration files is not required. Repeat the command to add another provider
or update an existing name.

The endpoint must support the OpenAI Responses API. Examples of API bases are
`https://inference.dahl.global/v1` and
`https://discovery-api.intern-ai.org.cn/v1` (Atria's website is not its API).
A host-only URL is normalized to `/v1`.

Saved names appear in `/provider` completion. `/model` lists API-discovered models
as `name::model-id`, keeping endpoints with identical model IDs separate. Context
windows are used when the model catalog reports them. For example:

```text
/provider dahl
/model dahl::MiniMaxAI/MiniMax-M2.7
```

## Test

```
zig build test
```

## Changelog

- `CHANGELOG.md` for release-by-release notes
- `pz --changelog` or `/changelog` in TUI for in-app change visibility

## Config

Canonical `pz` state lives under `.pz/`:

- `~/.pz/settings.json` — global defaults
- `./.pz/settings.json` — project-local overrides
- `~/.pz/auth.json` — OAuth / API key credentials
- `~/.pz/state.json` — local machine state
- `~/.pz/sessions/` and `./.pz/sessions/` — persisted sessions
- `~/.pz/policy.json` and `./.pz/policy.json` — authoritative signed policy bundles
- `~/.agents/skills/`, `~/.pz/skills/` and `./.pz/skills/` — skill definitions, with later directories overriding earlier ones by directory name
- `AGENTS.md` — policy-controlled context files

For models missing from the built-in context-window registry, set the verified
window size (in tokens) by exact model ID in `settings.json`:

```json
{
  "contextWindows": {
    "your-model-id": 131072
  }
}
```

Values must be positive integers. Explicit values override the built-in registry;
a later configuration file replaces the entire `contextWindows` map. Unknown
models have no assumed window: the UI omits the context percentage and automatic
percentage-based compaction is disabled until a window is configured. Manual
compaction remains available. Use the limit documented by your model provider,
not the illustrative value above.

## License

MIT

## Attachments and clipboard

Drop local files into the prompt or paste their paths. Quoted paths, escaped
spaces, `file:///` URLs, `~/`, `./`, and multiple files are supported. In multiline
prompts, put each path on its own line or use `@path` / `file:///` explicitly;
paths embedded in pasted code remain text. Ctrl+V
reads images or text from the clipboard using `wl-paste` on Wayland, `xclip`
on X11, or `osascript` on macOS. Pasted images enter the editor as attachments;
press Enter to send them. Their private temporary files remain available for
submission and replay; removing a source file makes replay fail explicitly.

Text is read as UTF-8 regardless of extension. PNG, JPEG, GIF and WebP are
recognized by their contents and sent as image parts. Other supported raster
formats use installed `ffmpeg`. Video containers including MP4, MOV, MKV, WebM
and AVI use `ffprobe` and `ffmpeg` to produce eight chronological frames;
audio is not transcribed. Audio files provide format/stream metadata only.
PDFs use installed `pdftotext` (text only; scans need OCR). DOCX, XLSX, PPTX,
OpenDocument and EPUB text use isolated Python 3; other ZIPs provide a directory
listing without extracting files. Embedded images, macros, spreadsheet display
formatting and document layout are not preserved by text extraction.

Limits: eight files, 4 MiB total extracted content, 100 MiB per source and five
minutes per video. Unknown binaries, missing converters and oversized inputs
fail explicitly. Image input still requires a vision-capable model. Media
generation is a separate provider tool; selecting a Codex model alone does not
expose Codex app tools in pz.

## Repository tools

`grep` uses installed `rg` for regular expressions, including single-file searches;
`find` uses installed `fd` for literal names or glob patterns. Both honor ignore
files. Missing executables fail explicitly. HTTP tools require installed `curl`.

`patch` applies a unified diff to one explicit file, validating all hunks before
writing. It updates or creates files; file deletion and renaming are separate
operations. `todo` keeps a task list for the current runtime session. `skill`
without a name lists the available model-invocable skills.

`github` inspects public GitHub, GitLab, Gitea and Forgejo repositories without
cloning. It supports directory listings, line-ranged file reads, trees, history,
branches, tags and repository metadata. Commit patches and comparisons are
GitHub-only. Metadata is returned as compact text with pagination hints and
explicit warnings for missing patches.

Examples of model tool arguments:

```json
{"repo":"owner/repo","op":"list","path":"src"}
{"repo":"owner/repo","op":"read","path":"src/main.zig","from_line":1,"to_line":20}
{"repo":"https://codeberg.org/owner/repo","op":"tree"}
{"api":"gitea","repo":"https://git.example.org/owner/repo","op":"info"}
```

`owner/repo` selects GitHub. HTTPS URLs infer known hosts (github.com, gitlab.com,
codeberg.org and gitea.com); self-hosted URLs require an explicit `api` value.
Omit `ref` for the default branch, or specify a branch, tag or commit. Reads are
capped at 2 MiB, other API responses at 8 MiB, and returned output at the normal
tool limit. GitHub directories hitting 1,000 entries and truncated GitHub trees
fail explicitly. Follow page hints to retrieve remaining results. Private
repositories and authenticated API access are not implemented. Requests remain
subject to egress policy.

`ffmpeg` provides fixed local operations: inspect metadata, verify full decoding,
thumbnails, trim, fit to landscape/portrait/square, codec export, GIF creation,
audio extraction and loudness normalization, rotation, mirroring, playback speed
and muting.
Use `op=transform` with `transform=clockwise|counterclockwise|half|horizontal|vertical`,
`op=speed` with a `speed` multiplier from 0.5 to 2 (audio pitch preserved), or
`op=resize` sets exact even pixel dimensions with `width` and `height`, preserving
the full frame with `fit_mode=contain` or filling it with `fit_mode=crop`.
`op=mute` drops audio while copying the video stream into MP4. `op=loudness`
normalizes the first audio stream to -14 LUFS for web playback, re-encoding audio
to AAC while copying video. These operations write `.mp4`; resize, rotation and
speed re-encode H.264/AAC.
`op=insert` creates a silent MP4 from a JPG, PNG or WebP still image; provide
`duration_seconds` and `aspect=landscape|portrait|square`. Set `ken_burns=true`
for a slow zoom and pan; `fit_mode` controls whether the image is padded or cropped.
`op=join` concatenates two clips given by `input` and `input2`; both clips need
audio, and the output is normalized to 1080p H.264/AAC.
For speed, `start_seconds`
is source time and optional `duration_seconds` is output time.
It requires installed `ffmpeg` and `ffprobe`, checks input/output path policy,
limits inputs to 100 MiB and generated outputs to 64 MiB, and never overwrites
an existing output file. Rendering operations also limit input duration to five
minutes; slowed output without an explicit duration is also capped at five
minutes. Metadata inspection does not impose that duration limit. Each generated
file is checked with ffprobe; use `op=verify` to decode all audio and video streams.
Neither check judges visual quality or whether the edit matches intent.

`agent` runs one child agent. `swarm` coordinates live workers with roles
(`sme`, `coder`, `test_engineer`, `reviewer`), addressed messages, and lifecycle
operations. Its workflow is plan/consult, implement one task at a time, test,
then independently review; SME and reviewer workers have read-only built-in
tools and no MCP servers. Workers share the project checkout, so parallel code
changes are not isolated.

## Models and keyboard help

The OpenAI picker and thinking controls use a generated catalog from Codex model
metadata. Refresh it with `python3 tools/update-openai-models.py`, then run
`zig build`. This updates the bundled snapshot; pz does not fetch it at startup.
The startup screen shows short hints and skill names; `/hotkeys` lists the full
keyboard help.

## Web

`web` searches the public web with Exa when given a `query`, or fetches a known
URL and extracts readable Markdown when given a `url`.

```json
{"url":"https://example.org/article"}
```

Search works without an API key; set `EXA_API_KEY` to use your own Exa key.
Search results are untrusted; use `web` with a result URL to read a page.

Integrations are enabled by default. Set these fields in `~/.pz/settings.json`
(or project `.pz/settings.json`) to disable them independently:

```json
{"exa": false, "mcp": false, "lsp": false, "skills": false}
```

`skills: false` disables skill discovery, the `skill` tool, and slash skill calls.
`exa: false` disables Exa search while keeping URL fetching available. `mcp: false`
prevents configured MCP servers from starting and hides their tools. `lsp: false`
disables language servers and hides the LSP tool. Existing `mcpServers` settings
can remain in the file; set `mcp` back to `true` to re-enable them. To re-enable
LSP, set `lsp` to `true` for defaults or restore its server settings object.

Fetching returns readable Markdown: article text, links, tables, numbered lists
and code. Navigation, scripts and sidebar noise are removed. Article JSON becomes
labelled title/body text; other JSON stays compact. RSS/Atom feeds become readable
entries. Next.js/RSC data is used when ordinary HTML has little content.
JavaScript app shells and browser verification pages are reported explicitly;
pz does not execute JavaScript or solve browser challenges.

Auto output defaults to 80 numbered lines and 8 KiB. Use `from_line` and `to_line` for
ranges, or the returned `next from_line=..., line_offset=...` to continue.
Oversized lines split at UTF-8 boundaries. Both modes download at most 4 MiB;
the output budget is applied after line selection. Auto extraction
requires `python3` (standard library only).

Use `json_path` to select a dot-separated JSON field, including array indices.
Use `pattern` for case-insensitive regex matches in extracted text (requires
`rg`). Use `format: "raw"` for response text without extraction or Python;
it supports the same line ranges and continuation, and cannot be combined with
`json_path` or `pattern`. Both modes redact sensitive lines while retaining
surrounding content. A sensitive marker in a minified, single-line response
still hides that entire line.

Call an operation from an OpenAPI JSON document with `openapi`, `operation_id`
and `parameters` (a JSON object string). Put inline path/query/header scalar
values in the object by parameter name; use `body` for a JSON request body.
Calls require approval and are limited to operations served from the
specification's origin. YAML, `$ref`, and server-variable expansion are not
supported yet.


## JavaScript plugins

pz embeds QuickJS-ng for explicitly configured JavaScript plugins. No Node,
npm, external interpreter or plugin-host process is required. Without enabled
scripts, no JS runtime is created.

```json
{"plugins": ["./examples/plugins/hello.js"]}
```

Add this to your settings, then use `/plugins` to inspect registrations or
`/hello world` to run the example command. Set `plugins` to `false` or `[]` to
disable them. Paths are relative to the working directory; use absolute paths
in global settings.

API v1 supports synchronous tools, slash/RPC commands, in-memory state and
session/request/tool events. The embedding exposes no filesystem, network or
shell APIs. It does not load TypeScript, npm packages or pi extensions, and does
not yet support custom model providers or compaction implementations. See
[the plugin API and limits](docs/PLUGINS.md) and [examples](examples/plugins/).
