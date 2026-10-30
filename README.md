# pz

A security-first coding harness rewritten from the ground up in Zig for enterprise environments. `pz` is not a generic extensible agent platform, for now: the goal is peace of mind through built-in security, policy, and auditability.

## Measured footprint

Local Linux x86_64 measurements on 2026-10-30 with Zig 0.16.0 and
`zig build -Doptimize=ReleaseFast -Dgit-hash=c43627bf6b51`:

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
- **16 built-in tools** — `read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`, `ask`, `web`, `skill`, `agent`, `patch`, `todo`, `github`, `swarm`, `ffmpeg`
- **Skills** — discoverable `/skillname` slash commands with frontmatter, registry, and policy gating
- **Session management** — persist, resume, fork, name, export, share as gist
- **OAuth + API key auth** — automatic token refresh, multi-provider support
- **Subscription quotas** — the footer shows used percentages from the selected Codex/Claude provider's response headers or Codex stream events after a completed request. Window labels follow the reported duration (5h, week, month); missing quota data shows `limits: n/a` and changing model/provider clears it. API-key responses may not include subscription quotas.
- **Thinking levels** — prefer off when supported; OpenAI model metadata determines the available levels through max. Shift+Tab skips unsupported levels. Any adjustment is shown explicitly; Anthropic uses token budgets for enabled levels.
- **Prompt caching** — automatic cache_control on system messages
- **Headless modes** — `--print`, `--json`, and `rpc` for scripting and integration
- **Agent tool** — spawn subagents with dedicated RPC fd, progress streaming, process group isolation
- **Swarm tool** — collaborating live workers with addressed messages and explicit wait/stop/close operations
- **File attachments** — local text, images, documents and bounded video-frame extraction; clipboard images enter the outgoing prompt
- **Zero-alloc hot path** — rendering and input handling avoid heap allocations

### Security

- **Signed policy bundles** — Ed25519-verified policy with lock mode, generation rollback resistance, and expiry
- **Tool sandbox** — process group isolation, env scrubbing, TERM→KILL escalation
- **Linux workspace sandbox** — read the host filesystem, write only the workspace and `/tmp`, block network access. Python environments keep access to their installed interpreters; temporary files and tool caches use `/tmp`. A bash call with `sandbox_permissions: "require_escalated"` and `justification` asks the user to approve that command outside the sandbox. Denial, missing interactive approval, or a verified policy blocks escalation.
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
zig build -Doptimize=ReleaseFast -Dgit-hash=<commit-hash>
```

Release builds require `-Dgit-hash=<hash>` and embed `CHANGELOG.md`. Debug builds use VCS.

## Run

```
# Canonical state lives under ~/.pz/ and ./.pz/
pz

# Explicit provider and model
pz --provider anthropic --model claude-sonnet-4-20250514

# Resume a session
pz resume          # picker (also: pz -r)
pz resume --last   # most recent (also: pz -c)
pz resume 123      # specific session ID

# Headless
pz print "explain this codebase"
echo '{"prompt":"hello"}' | pz json

# Choose a supported reasoning effort
pz --thinking low
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

## License

MIT

## Attachments and clipboard

Drop local files into the prompt or paste their paths. Quoted paths, escaped
spaces, `file:///` URLs, `~/`, `./`, and multiple files are supported. Ctrl+V
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

`ffmpeg` provides fixed local operations: inspect, thumbnails, trim, fit to
landscape/portrait/square, codec export, GIF creation and audio extraction.
It requires installed `ffmpeg` and `ffprobe`, checks input/output path policy,
limits inputs to 100 MiB and generated outputs to 64 MiB, and never overwrites
an existing output file. Rendering operations also limit input duration to five
minutes; inspection does not impose that duration limit.

`agent` runs a child agent; `swarm` provides live workers with spawn, send/recv,
wait, stop and close operations. Spawn peers before waiting when collaboration
is needed. LSP and external web search are outside this tool set.

## Models and keyboard help

The OpenAI picker and thinking controls use a generated catalog from Codex model
metadata. Refresh it with `python3 tools/update-openai-models.py`, then run
`zig build`. This updates the bundled snapshot; pz does not fetch it at startup.
The startup screen shows short hints and skill names; `/hotkeys` lists the full
keyboard help.

