# pz

A security-first coding harness rewritten from the ground up in Zig for enterprise environments. `pz` is not a generic extensible agent platform, for now: the goal is peace of mind through built-in security, policy, and auditability.

## Measured footprint

Local Linux x86_64 measurements with Zig 0.16.0 and the default `zig build` Debug configuration:

| Measurement | Result |
|---|---:|
| Binary size (`zig-out/bin/pz`, unstripped) | 65.4 MiB |
| `pz --version` startup (25 runs, median) | 23.33 ms |
| `pz --version` peak RSS | 9.3 MiB |
| TUI idle RSS (empty temporary profile, 3 seconds) | 11.9–13.2 MiB |

Startup timing includes process creation. RSS is resident memory reported by Linux; TUI samples were taken after launch with version checks disabled. These are local Debug-build measurements, not release-build or provider-response benchmarks. The Linux binary is dynamically linked to glibc and libm; bash sandboxing also requires `bwrap`.

## Features

### Harness

- **Interactive TUI** — streaming responses, markdown rendering, syntax highlighting
- **Image rendering** — Kitty graphics protocol support in terminal
- **24 slash commands** — `/model`, `/fork`, `/export`, `/compact`, `/share`, `/tree`, and more
- **Autocomplete dropdown** — fuzzy-filtered command and file path completion
- **14 built-in tools** — `read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`, `ask`, `web`, `skill`, `agent`, `patch`, `todo`, `github`
- **Skills** — discoverable `/skillname` slash commands with frontmatter, registry, and policy gating
- **Session management** — persist, resume, fork, name, export, share as gist
- **OAuth + API key auth** — automatic token refresh, multi-provider support
- **Thinking levels** — prefer off when supported; OpenAI model metadata determines the available levels through max. Shift+Tab skips unsupported levels. Any adjustment is shown explicitly; Anthropic uses token budgets for enabled levels.
- **Prompt caching** — automatic cache_control on system messages
- **Headless modes** — `--print`, `--json`, and `rpc` for scripting and integration
- **Agent tool** — spawn subagents with dedicated RPC fd, progress streaming, process group isolation
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
- **Event loop** — kqueue (macOS) event loop core with provider and tool I/O migration

### Testing

- **1300+ tests** — unit, integration, snapshot (ohsnap), and property (zcheck) tests
- **PTY harness** — real-process TUI tests with ANSI AST parsing
- **Mock infrastructure** — provider, syslog, HTTP, cancel, time mocks
- **Allocator regression** — test-allocator proofs for UAF and leak safety

## Build

Supports [Zig](https://ziglang.org) 0.16.0 and 0.17.0.

```
zig build
```

The binary lands in `zig-out/bin/pz`.

On Linux, bash execution requires `bubblewrap` (`bwrap`) on `PATH` and permission to create user and network namespaces. A temporary root exposes system directories read-only, mounts the workspace writable, and blocks shell network access.

Release builds require `-Dgit-hash=<hash>` and embed `CHANGELOG.md`. Debug builds use VCS.

## Run

```
# Canonical state lives under ~/.pz/ and ./.pz/
pz

# Explicit provider and model
pz --provider anthropic --model claude-sonnet-4-20250514

# Headless
pz --print "explain this codebase"
echo '{"prompt":"hello"}' | pz --json
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

## Repository tools

`grep` uses installed `rg` for regular expressions, including single-file searches;
`find` uses installed `fd` for literal names or glob patterns. Both honor ignore
files. Missing executables fail explicitly. HTTP tools require installed `curl`.

`patch` applies a unified diff to one explicit file, validating all hunks before
writing. It updates or creates files; file deletion and renaming are separate
operations. `todo` keeps a task list for the current runtime session. `skill`
without a name lists the available model-invocable skills.

The OpenAI picker and thinking controls use a generated catalog from Codex model
metadata. Refresh it with `python3 tools/update-openai-models.py`, then run
`zig build`. This updates the bundled snapshot; pz does not fetch it at startup.
The startup screen shows short hints and skill names; `/hotkeys` lists the full
keyboard help.

`github` browses public repositories one directory or file at a time using the
GitHub Contents API, following the approach in
[ghgrab](https://github.com/abhixdd/ghgrab/blob/main/src/github.rs).
It never clones repositories. Examples of model tool arguments:

```json
{"repo":"abhixdd/ghgrab","op":"list","path":"src"}
{"repo":"abhixdd/ghgrab","op":"read","path":"src/github.rs","from_line":190,"to_line":210}
```

Omit `ref` for the repository's default branch, or specify a branch, tag, or commit.
Files are capped at 2 MiB and returned output at the normal tool limit. Large
files need a line range; directories hitting GitHub's 1,000-entry limit fail
explicitly. Private repositories and authenticated API access are not implemented.
The model receives tool guidance on each request, including instructions to use
`github` for source exploration before considering a clone. LSP and external web
search are outside this tool set.
