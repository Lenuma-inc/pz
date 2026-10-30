# Lessons Learned

Hard-won patterns and anti-patterns from building pz. **Update this file at the end of every session** with new discoveries.

## Session Notes (2026-10-31)

### Do More
- Keep synchronized terminal updates open through editor cursor placement, and hide the cursor while painting dirty cells.
- Compare context compaction by pinned version: OpenCode V1 pruning differs from V2 summary/tail retention; distinguish active context replacement from persisted history deletion.
- Search exact symbols in known paths before repository-wide scans; preview long matching lines rather than sending them whole.
- Reduce repeated agent instructions and model-visible output before trading away reasoning quality; stop exploration and verification once task evidence is sufficient.
- Default model-visible source reads to bounded line windows; internal edit reads are not prompt context.
- Distinguish internal file reads from model-visible context; cap edit/write/patch diffs independently and request narrow source ranges.
- Preserve sentinel slice types when returning allocated real paths from helpers; keep ffmpeg time arguments in distinct argv slots.
- Separate edit input-file limits from output budgets; correlate tool failures and appended bash diffs with recorded token growth before changing prompts.
- Distinguish punctuation outside a quoted path in pasted diagnostics from punctuation inside an attachment filename.
- Sort session pickers by recorded activity; hide sessions without prompts instead of presenting internal IDs as titles.
- Persist admitted attachment contents in session prompts; replay recorded data instead of reopening temporary source paths.
- Cut display previews at UTF-8 boundaries, including small byte limits and footer buffers.
- Correlate child errors and replay stages with the user's actual session before changing swarm scheduling.

### Do Not Do
- Treat a frame-only renderer test as proof of cursor redraw correctness; test the complete Ui.draw transaction and real keyboard edits.
- Treat ffprobe metadata as proof of full decoding or visual quality; keep media regression checks focused when requested.
- Treat ordinary directory context in delegated tasks as a file attachment, or fabricate content for attachments absent from old sessions.
- Assume deterministic provider fixtures match current reasoning budgets or guarded tool-result framing.

## Session Notes (2026-10-30)

### Do More
- Compare Codex's model-specific `model_messages.instructions_template` with pz's assembled context and tool guidance; pin the upstream revision and match effective reasoning levels before attributing behavior to the model.
- Bind context-file trust to absolute path and exact bytes; keep config-write approvals separate and protect config directories with read-only sandbox mounts.
- Measure optimized builds for README footprint figures and state whether debug symbols remain; keep Debug comparisons separate.
- Date footprint measurements and state build mode, line-count scope and measured process mode; do not reuse stale TUI RSS as a fresh result.
- Reconcile README tool inventories and CLI examples with the registry and parser; separate attachment dependencies from repository-tool behavior.
- Keep session continuation (`-c`, `resume --last`) separate from interactive selection (`-r`, `resume`); exercise both through the real binary.
- Keep forge adapters on the shared HTTP policy path; infer only known hosts and require an explicit API for self-hosted repository URLs.
- Treat Gitea/Forgejo tree `truncated` as pagination, unlike GitHub's incomplete-tree error; test second pages against real servers.
- Project API metadata into compact text for model tools; preserve commit identifiers, readable patches, pagination and explicit missing-patch warnings.
- Expose media processing as a typed built-in tool with fixed ffmpeg operations; enforce read and write policy on both paths, and never overwrite output files.
- Attach clipboard images to the outgoing editor prompt and retain their source files; terminal preview alone does not send image content.
- Choose clipboard readers from the active desktop session: wl-paste for Wayland, xclip for X11, osascript for macOS.
- Sniff image bytes and label text-only document extraction and silent video frames explicitly in model context.
- Test both legacy and Kitty key encodings through the real PTY; enabling Kitty changes how Shift+Tab arrives.
- Verify thinking levels in serialized provider requests, including explicit off and distinct high/xhigh efforts.
- Keep CLI, runtime, and provider defaults aligned; test startup without a thinking flag and reject removed mode names.
- Read allowed reasoning efforts and defaults from credential-scoped model metadata; a global off default can be invalid, and API and subscription catalogs can differ.
- Distinguish unsupported levels from wire-value mappings: Pi marks GPT-6.1 Sol off as null, while its Codex minimal level maps to low; direct OpenAI marks minimal unsupported too.
- Scan shared ~/.agents/skills before pz-specific roots; keep deduplication map keys alive when replacing skill metadata.
- Preserve and redact child provider diagnostics before sending failure frames; test missing error text and long escaped messages through the real child.
- On Linux, re-exec /proc/self/exe rather than its resolved path: a running executable may have been unlinked by a rebuild/update.
- Keep RPC frame limits independent of the small read buffer; stream long frames with the protocol limit and test oversize rejection.
- Distinguish successful delegation from concurrency: the two-child live retest returned both results, but calls ran sequentially.
- Trace concurrency through production dispatch: loop.runTool blocks on PolicySpawnCtx.runReqStreaming; BgPool exists but is not wired into the agent tool.

### Do Not Do
- Assume pz's parsed thinking=off reaches every model unchanged: `ThinkingLevel.forModel` selects a supported level before request serialization.
- Silently turn session-list read failures into an empty picker; propagate storage errors.
- Assume every repository has README.md; select an actual file from its directory listing (Cassette uses README.en.md and README.ru.md).
- Omit OpenAI reasoning options to implement off: omission leaves the server default active.
- Infer reasoning capabilities from model-name prefixes or advertise effort levels absent from the selected model's catalog.
- Run PTY regressions against stale build_options.pz_bin_path; rebuild the executable and use its generated test options.

## Session Notes (2026-10-29)

### Do More
- For GitHub inspection, expose recursive tree completeness and explicit pagination; retain file modes/SHAs and disclose commit/compare patch limits.
- Use an explicitly named temporary test-import root for direct filtered Zig checks, and ensure PTY build options reference the newly built binary.
- Reproduce long SSE failures with valid raw chunked HTTP; test lines larger than the transfer buffer across multiple chunk sizes.
- Clear `AbortSlot` before destroying its stream on every exit path; test a stream error followed by cancellation/quit.
- Unwrap SSE `ReadFailed` through HTTP `bodyErr()` and connection `getReadError()` before reporting it to users.
- Preserve message phase and boundaries through session replay and both OpenAI authentication modes; test fragmented text and explicit `end_turn: false`.

### Do Not Do
- Present truncated GitHub trees or omitted binary/large patches as complete repository evidence.
- Use Zig 0.16 `Reader.takeDelimiter` on chunked HTTP bodies: its full-buffer failing-writer probe can consume the next chunk header without updating decoder state. Use buffered scanning plus `streamDelimiter` from the outset.
- Treat echoed AGENTS text in Responses metadata as proof of memory corruption; validate the raw HTTP framing independently.
- Leave an abort callback pointing at a destroyed stream after `next()` fails; TUI shutdown will call it again.
- Search raw ANSI output for rendered sentences; inspect the frame/vscreen because styling can split the bytes.

## Session Notes (2026-10-28)

- When diagnosing silent turn endings, correlate session `tool_result`, `usage`, and `stop` events; missing terminal events support an incomplete stream but do not identify its transport cause. Keep child RPC EOF separate from provider SSE EOF.
- Preserve Responses assistant message boundaries and `phase` through streaming, history, replay, and request serialization; text deltas alone lose commentary/final semantics. Compare `end_turn` and terminal SSE validation with native Codex before blaming model autonomy.

### Do More
- Exercise signal draining with a real pending, thread-directed signal and verify the next read returns `WouldBlock`.

- Terminate displayed diff lines even when source snippets have no final newline; keep removed and added markers on separate lines.
- Give the model registry-derived tool guidance; explicitly prefer selective GitHub reads over cloning for source exploration.
- Exercise the production child entry point, not only the echo harness; a working RPC mock cannot detect a missing --child handler.
- Keep trusted sibling directory handles before callbacks can rename ancestors; fd discovery paths are only a selection snapshot.

### Do Not Do
- Do not read Linux `signalfd` into fewer than 128 bytes: `EINVAL` triggers an `unreachable` panic in `std.posix.read`.

- Do not assume fd accepts a path alongside --strip-cwd-prefix, or slash globs without --full-path; test the installed CLI.
- Do not rely on discarded comptime imports to register Zig 0.16 tests; import the suite from a test block.
- Treat a port or scheme change as a new HTTP origin when stripping credentials.
- Do not return a successful readiness message from an execution tool; return its actual result or a propagated error.

## Session Notes (2026-10-27)

### Do Not Do
- Do not assume every terminal sends bare CSI arrow sequences; accept parameterized CSI arrows such as `1;1A` alongside standard CSI and SS3 forms.
- Never continue after `Reader.takeDelimiter` returns `StreamTooLong`: it leaves the reader unchanged, so drain long SSE lines with `streamDelimiter`.
- Absolute `.mp4` input starts with `/`, so route it as a prompt before slash-command dispatch. Extract a bounded contact sheet and pass it as provider image parts; keep file/protocol limits at the extraction boundary.
- A Linux filesystem read-only bind still exposes readable secrets; build the sandbox from an empty root and bind only system directories plus the workspace.
- Handle drag selection inside the TUI when mouse reporting is required for wheel scrolling.
- Tool failures caused by policy or sandbox limits must tell the model to stop and ask the user for access; opaque error names invite blind retries.

---

## Session Notes (2026-03-24)

### Worked Well
- When CLI and RPC share the same OAuth callback protocol, keep one shared runner for browser launch, callback wait, manual fallback hint, and completion; endpoint differences belong in `OAuthSpec`, not duplicated control flow.
- For auth/browser regressions, disabling `openBrowser()` under `builtin.is_test` is not enough; PTY/e2e runs spawn the real `pz` binary, so `zig build test` must inject an env guard into every run artifact.
- For provider OAuth breakage, diff the first-party client’s exact authorize host, scope set, JSON field order, refresh payload, and `Accept`/`Content-Type` headers; “roughly OAuth-correct” is not enough.
- Adding random entropy strings to parallel agent prompts breaks convergence — same-model agents with identical prompts find the same things and miss the same blind spots.
- Converting all `runPzPtySteps` tests to `runPtyInteractive` with wait-for-text sync eliminated an entire class of timing flakes (10 tests converted, 0 remaining callers).
- Adversarial plan review with 6 specialized agents (plan-critic, edge-case, reviewer, scout, auditor, destructor) on disjoint surfaces finds issues a single reviewer misses — 2 reviews × 10 rounds found 2 Critical + 59 Major issues.
- Many plan items turn out to be "already done" when checked against actual code — always verify before implementing (B5, D5, D10, D11, D12, D16 were all complete).
- The escapeBodyAlloc case-sensitivity bug (A10) was found by the security auditor agent — fresh context catches what the implementer assumes is working.

### Do Not Do
- Don't run tests 5+ times to prove stability — fix the root cause instead. Converting to wait-for-text sync is the fix, not longer sleeps.
- Don't use `runPzPtySteps` for new PTY tests — use `runPtyInteractive` exclusively.
- Don't skip plan review validation against actual code — line numbers drift as the file changes, function names get wrong, items get silently dropped.
- Don't claim `catch return` in `RealSleeper.sleep` is a bug — immediate retry on poll failure is correct backoff behavior.
- Don't assume `config.zig Err = anyerror` — it uses `@typeInfo` reflection to compute a concrete error set.
- For Zig 0.16/0.17 shared build code, branch on `@hasField` for struct reflection metadata and `ArrayListUnmanaged` fields; both APIs changed between releases.

### Did Not Work
- Fixed-sleep `runPzPtySteps` approach for PTY tests — inherently unreliable, can't be fixed with longer sleeps.
- Trying to make the version check PTY test deterministic with server.join — the join kills the server before the version check thread can connect. Using skip on timeout is more robust.

## Session Notes (2026-03-20)

### Worked Well
- For SSE debugging, curl with `-D /dev/stderr` to dump response headers exposes content-encoding mismatches that are invisible in the application.
- Adding a temporary `std.debug.print` for response `content_encoding` and `transfer_encoding` in `http_client.zig` immediately confirmed the gzip root cause vs hours of guessing.

### Do Not Do
- Don't use `std.http.Client.Response.reader()` for SSE streams — Zig's HTTP client sends `accept-encoding: gzip, deflate` by default, and `reader()` doesn't decompress. Either omit `accept-encoding` (correct for SSE) or use `readerDecompressing()`.
- Don't assume API key and OAuth paths behave the same at the HTTP level — Cloudflare/CDN may compress differently based on request headers like `anthropic-dangerous-direct-browser-access`.

## Session Notes (2026-03-13)

### Worked Well
- Keep one local integration/debug lane and only 2-3 worker lanes; beyond that, overlap and flaky shared-surface debugging erase the parallelism win.
- Parallelize only disjoint dots, not “similar” dots; runtime/provider/session/core work tends to couple even when file lists look different.
- When a worker stalls or the wrapper goes silent, inspect the workspace state directly and reclaim the slot fast instead of waiting on agent status alone.
- For invalid UTF-8 at provider/session boundaries, use one shared lossy helper plus short-lived arena-backed `sanitizeMaybeAlloc` during JSON serialization; it preserves the existing JSON shape for valid text and only allocates on the bad-byte path.
- For property-built session events, copy generated `Id`/`String`-like data into explicit local storage before constructing slice-backed event structs. Method-call slices taken straight from generated values can point at short-lived temporaries and corrupt roundtrip/dupe properties.
- For compaction budget coverage, snapshot a compact formatted metadata string (`outcome/input/limit/kept/dropped`) instead of relying on `ohsnap`'s raw enum-struct layout; the string stays stable while still proving the important fields.
- For deterministic compaction fitting, compute one shared metadata pass over the full provider input text (guard, system prompt, conversation wrapper, footer, summary prompt) and reuse that in both budget checks and tests so suffix retention stays exact.

### Do More
- When a new property introduces helper generators, add one shrink-specific property in `core/pbt.zig` so generator semantics fail locally before they get buried under larger suite noise.

### Do Not Do
- Do not trust filtered `zig build test -- --test-filter ...` output as isolated coverage in this repo; the build step still runs unrelated PTY/e2e work, so note flaky external failures separately and keep one clean full-suite run for final verification.

### Did Not Work
- Trying to use standalone `zig test --test-filter ...` against the build-generated suite roots returned zero matching tests for imported module cases here, so end-to-end confidence still had to come from the full `zig build test` suite.
## Session Notes (2026-03-11)

### Worked Well
- For leftover retry/parser state tests in snapshot migrations, format the derived multi-field state into one compact `ohsnap` string instead of leaving a tail of count/wait/stop field asserts.
- For parser and protocol robustness, add the crap-and-mutate helper to `core/pbt.zig` first, then reuse it from real parser properties; that keeps the mutation strategy deterministic, reviewable, and shared instead of growing ad hoc `mutate*` helpers in each file.
- Before `jj workspace add`, move root to a fresh empty child; creating workspaces from a non-empty working-copy commit can base the new workspace on the parent commit instead of the intended integrated head.
- For cross-feature audit proof, keep the E2E harness under `src/test/`, feed it a mixed row set from real hook emitters where public (`auth`, `bg`) plus manual control fixtures where hooks stay private, and verify the sealed syslog bodies round-trip exactly through both UDP and TCP mocks.
- For signed runtime-policy checks, map slash/tool/subagent actions onto a synthetic namespace like `runtime/...`; it stays outside policy self-protection and gives stable paths for hashable authority decisions.
- Landing worker results with `jj restore --from <commit> <file>` kept dot merges exact and avoided stale workspace side-data.
- Replacing `git` shell-outs in `build.zig` with `jj log` made test runs work inside `jj workspace` siblings without fake `.git` hacks.
- For seeded `pbt` self-tests, snapshot the actual fixed-seed success stream and shrunk witness from the harness instead of guessing expected bytes.
- For borrowed replay/session events, add an owned path (`nextDup`/`dupe`) instead of relying on callers to remember arena lifetime rules.
- For DNS/network guards, keep address classification in one shared helper and compare `std.net.Address` values with `std.net.Address.eql`, not struct equality.
- For TUI `ask`, keep the tool thread on a waitable handoff and let the main loop answer through its existing `tui_input.Reader`; pausing the ESC watcher only while the main loop owns stdin preserves single-reader semantics and avoids editor/ask interleaving.
- Gate every bash entrypoint through one shared protected-command scanner; otherwise direct `!cmd` and tool `bash` drift and one becomes the bypass.
- For RFC 5424 UDP truncation, parse through the structured-data boundary and append truncation metadata there; trimming raw bytes blindly risks invalid frames and would miss the `sendRaw` audit path.
- Pulling the ad hoc blocked-stream provider out of the loop test and into `src/test/provider_mock.zig` made the cancel regression cheaper to reuse and gave `T7b` a real local provider harness instead of copy-pasted test scaffolding.
- A tiny one-shot local HTTP server under `src/test/http_mock.zig` is enough to unblock update/share/redirect testing; land the harness before trying to write higher-level E2E around it.
- Contract helpers added under `src/core/providers/contract.zig` are not automatically visible through `src/core/providers/mod.zig`; owned callers should import the contract directly unless the module surface is intentionally widened.
- When a test frees a companion `parts` buffer by deriving its size from `msgs.len`, any change that allows multi-part system messages must update that free path too or the debug allocator will catch a mismatched free/leak.
- Approval caches for privileged tool calls need the full raw arg payload plus session/location/policy binding; anything narrower silently broadens the grant surface.
- For shipped audit E2E, capture multiple collector frames, extract the syslog body back out, and verify the sealed chain from the collected payloads; that proves transport + redaction together instead of only unit-encoding them.
- For runtime control audit, route slash commands, RPC commands, and overlay selections through one shared helper with its own sequence counter; otherwise one UI path will bypass privileged audit again.
- For DLP-style text redaction, keep path/secret markers in shared lists and property-test both positive markers and plain-id negatives; otherwise detector growth turns into unreviewable `or` chains.
- For approval-cache properties, generate alternate session/hash strings inside the property so the invariant never collapses onto an accidental equal input.

### Did Not Work
- Assuming `execWithIo` exercises the live TUI loop was wrong. `runTui` gates overflow-retry and other live-turn behavior behind `isatty(STDIN_FILENO)`, so fixed-buffer tests only cover the non-TTY prompt path unless stdin/tty are injectable.
- Using synthetic policy paths under `.pz/runtime/...` for runtime actions was wrong because policy self-protection denies any `.pz` path before rule evaluation.
- Letting a worker validate in a workspace whose build still shells out to `git` created false failures. Fix the build once instead of faking `.git` per workspace.
- For raw string snapshots, writing only the body text is wrong. `ohsnap` expects the full typed shape like `[]u8` plus the value line.
- Escaping JSON quotes inside raw multiline `ohsnap` snapshots is wrong. After `\\`, the quotes are literal snapshot content.
- Putting `<!update>` anywhere but the first snapshot line does not work; `ohsnap` will keep failing instead of rewriting the snapshot.
- Using `<!update>` inside tests that temporarily `chdir` with `CwdGuard` is wrong. `ohsnap` resolves the module root from the current working directory, so rewrite mode can fail with `FileNotFound`; patch the snapshot text by hand in those tests.
- Exposing Zig stdlib private error sets (for example `std.net.GetAddressListError`) from repo APIs is a dead end. Map them at the boundary.
- Treating `std.net.Stream.writer` like the old zero-arg API caused wasted compile/debug churn. In Zig 0.15 it requires a caller-supplied buffer; direct `std.posix.write` is often simpler in tiny test servers.
- Leaving temporary `std.debug.print` probes in inherited code polluted targeted test runs and risks shipping noise. Strip them before final validation, not after.

## Session Notes (2026-03-10)

### Worked Well
- Keep a repo-local `docs/zig.md` copied from `~/.agents/docs/zig.md` and point `AGENTS.md` at it so every agent works from the same Zig 0.15 rules inside the repo.
- Enforce `ohsnap` for struct/multi-field assertions and `joelreymont/zcheck` for property tests in the task definition before parallel work starts; that prevents workers from drifting into field-by-field test rewrites.
- For parallel dot execution, assign one `jj workspace` per agent, give each worker explicit file ownership, and merge their work back only after the tracks stabilize. Reuse and close the live agent pool instead of over-spawning threads.
- Keep routine Zig API knowledge in `docs/zig.md` so normal work does not require spelunking Zig std/source.

### Did Not Work
- Leaving Zig rules only in `~/.agents/docs/zig.md` made the repo instructions incomplete. Do not rely on off-repo paths when the project expects durable, shared guidance.
- Spawning fresh subagents without first reclaiming finished threads hit the agent limit and stalled review rounds. Reuse or close agents before launching more.
- Looking at Zig std/source for normal API recall wasted time. Default to `docs/zig.md` and only read source when truly blocked.

## Session Notes (2026-02-22)

### Worked Well
- Running pi and pz in parallel tmux sessions (100x50) with `tmux capture-pane -p -S -500` gives exact terminal output for side-by-side parity comparison. Captures must happen while TUI is running since pz uses alternate screen buffer.
- Formatting tool calls as `$ cmd args` (parsing JSON args to extract command/path) matches pi's display and is much more readable than raw `[tool name#id]` format.
- Collapsing long tool output with `... (N earlier lines, ctrl+o to expand)` keeps the transcript compact without losing information.
- Suppressing usage/stop protocol events from transcript (handling them only in panels/status bar) eliminates visual noise that pi doesn't show.
- Using `pushAnsi()` with span-based coloring for tool results preserves ANSI colors from tool output (e.g., colored grep results) while keeping the frame-buffer rendering clean.
- Adding `eofReader()` test helper (returns 0 bytes = EOF) replaced all `null` input readers in runtime tests, preventing them from blocking on real stdin in non-TTY mode.

### Did Not Work
- Passing `null` for input reader in runtime tests caused real stdin reads in non-TTY mode, hanging tests indefinitely. Always use an explicit EOF reader.
- Early `return` after processing `-p` prompt caused pz to exit immediately after the first response instead of staying in TUI mode like pi. The prompt path must fall through to the input loop.
- Using `frame.Color.eql` directly on `vscreen.Color` types in fixture tests caused type mismatch. Must use VScreen's own `expectFg`/`expectBg` methods.
- Variable name `count` in `pushToolResult` shadowed `Transcript.count()` method. Zig treats method names as field access, so local variables must not shadow struct method names.
- Zig 0.15's `std.Io.AnyReader` (DeprecatedReader) is a flat struct with `context: *const anyopaque` and `readFn`, not a vtable-based interface. Constructing it requires `.{ .context = undefined, .readFn = &S.read }`.

## Architecture & Design

### TUI parity approach
Compare against pi by running both with identical prompts and capturing terminal output. Track specific gaps (status bar fields, startup sections, transcript formatting) as discrete tasks. Fix the most visually impactful differences first.

### Transcript block kinds control visibility
The `Kind` enum (text, thinking, tool, err, meta) determines per-block filtering via `show_tools` and `show_thinking` flags. Tool display and thinking display are independent toggles. Thinking defaults to visible (matching pi), toggled with ctrl+t.

### Status bar accumulates across turns
Usage stats (in/out tokens, cache R/W, cost) come from provider usage events and accumulate in `Panels.usage`. The status bar renders these on each frame.

### Cost calculation uses integer micents
Cost is tracked in micents (1/100000 of a dollar) to avoid floating point. Rates are stored in cents/MTok. Formula: `tokens * rate_cents / 1000`. Model tier detected by substring match ("opus", "haiku", default sonnet). Displayed as `$N.NNN`.

### Prompt caching needs minimum token count
Anthropic requires ~1024 tokens in a cached block before it actually caches. Short system prompts won't trigger caching. `cache_control: {"type": "ephemeral"}` is set on the last system text block. R/W tokens show in status bar when >0.

### OAuth = subscription
Auth type from `~/.pi/agent/auth.json` determines subscription status. OAuth users get `(sub)` indicator in status bar. API key users don't. Detected via `Client.isSub()` and passed through `runTui()` as bool.

### Skills discovery is simple glob
`~/.claude/skills/*/SKILL.md` — iterate dirs, check file exists, sort for stable display. Shown in `[Skills]` startup section matching pi.

### jj bookmark for branch display
Pi shows git branch in footer, but jj repos have detached HEAD. Use `jj log --no-graph -r @ -T bookmarks` to get the jj bookmark name. Strip trailing `*` (dirty indicator). Fall back to git branch, then `detached`.

### TurnCtx eliminates parameter sprawl
`runTuiTurn` had 12+ params passed from 7 call sites. Replaced with `TurnCtx` struct holding stable loop state (alloc, provider, store, tools_rt ptr, mode, max_turns). Per-turn variables (sid, prompt, model, opts) passed via `TurnOpts`. Store `*tools.builtin.Runtime` (pointer) not `tools.Registry` (value) so `/tools` changes are visible.

### Overlay composites on frame buffer
Model selector overlay renders directly onto the frame buffer after normal TUI content, before `rnd.render()`. Key interception happens before `ui.onKey()` — when overlay is open, up/down/enter/esc are handled by overlay, not editor. Box-drawing chars (┌┐└┘│─) make clean borders.

### ESC cancellation needs raw mode + dedicated thread
Detecting ESC during streaming requires a dedicated InputWatcher thread (mirrors pi's CancellableLoader + AbortController pattern). The thread uses `poll()` with 100ms timeout + `read()` on stdin, setting an atomic bool when ESC (0x1b) is received. Critical: raw mode (`enableRaw`) MUST be set before starting the thread — in canonical mode, `poll()` POLLIN only fires on complete lines, so bare ESC never triggers it. The `enableRaw` call was moved before the `-p` prompt path for this reason. Non-blocking approaches (`fcntl O_NONBLOCK`, inline `pollCancel` in push callback) failed on macOS due to Zig's `read()` wrapper returning `WouldBlock` even when `std.c.read()` returns 0.

## Session Notes (2026-03-15)

### Formal Verification

#### TLA+ Lessons
- State space explodes with `SUBSET` — use fixed ownership sets, not `SUBSET Files`
- `Reset` with fresh budget creates infinite loops — bound with `MaxRounds`
- Terminal states need `CHECK_DEADLOCK FALSE` in cfg
- TLC runs natively on ARM via `tla2tools.jar` + homebrew openjdk (no Rosetta)
- `.lake/` and TLC `states/` dirs must be gitignored with `**/` prefix, not path-specific

#### Lean Lessons
- `bv_decide` can't unfold `def` with `~~~` (complement) — use literal hex values or `@[reducible]`
- `bv_decide` can't handle variable `Fin` indices into `BitVec` — use concrete positions
- `lake build` needs `lake update` first when adding dependencies
- If `.lake/packages/` has corrupt git clones, `rm -rf .lake && lake update` is the only fix
- Mathlib isn't needed for `bv_decide` (it's in `Std.Tactic.BVDecide`) — avoid mathlib for bitvector-only proofs
- Adversarial review of proof PLANS finds real code bugs (3 this session: CmdCache TTL, timing oracle, bash fail-open)
- The review process for writing proofs is as valuable as the proofs themselves — modeling forces you to read the code carefully

### Do More
- Review proof plans adversarially before writing proofs — the code-model gap analysis catches bugs
- Run `std.mem.eql` audit across all crypto/security comparisons — it's never constant-time
- Always gitignore generated artifacts with `**/` glob, not path-specific entries
- Benchmark episodes at 1M context before implementing — may not be needed

### Do Not Do
- Don't move directories while agents are writing to them — files land in wrong location
- Don't assume `generateSummary` can be reused for different output shapes — verify the actual struct
- Don't use `tool_result` events for non-tool data — Anthropic API validates tool_use pairing
- Don't claim proofs verify "existing code" when they model planned code — label clearly

## E2E audit (2026-10-30)

### Do More
- Report a capped test run ending in exit 124 as inconclusive, not passed; this audit's single 60-second run produced no test summary.

### Do Not Do
- Treat successful `--version` and `--help` checks of an older existing binary as verification of current sources, or API tests that skip network errors as proof of live-provider success.
