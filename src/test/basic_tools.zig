const std = @import("std");
const tools = @import("../core/tools.zig");
const builtin = @import("../core/tools/builtin.zig");
const guard = @import("../core/tools/path_guard.zig");
const patch = @import("../core/tools/patch.zig");
const github = @import("../core/tools/github.zig");
const noop = @import("noop_sink.zig");
const snap = @import("helpers.zig").expectSnapText;
const alloc = std.testing.allocator;

fn run(rt: *builtin.Runtime, kind: tools.Kind, args: tools.Call.Args) !tools.Result {
    return rt.registry().run(@tagName(kind), .{ .id = "basic", .kind = kind, .args = args, .src = .model, .at_ms = 1 }, noop.sink());
}

test "basic tools: regex searches a single file and rejects invalid patterns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try guard.CwdGuard.enter(tmp.dir);
    defer cwd.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "alpha 12\nbeta\nALPHA 34\n" });
    var rt = builtin.Runtime.init(.{ .alloc = alloc });
    defer rt.deinit();
    const res = try run(&rt, .grep, .{ .grep = .{ .path = "a.txt", .pattern = "^alpha [0-9]+$", .ignore_case = true, .max_results = 1 } });
    defer rt.deinitResult(res);
    try snap(@src(), "a.txt:1:alpha 12\n", res.out[0].chunk);
    try std.testing.expectError(error.InvalidArgs, run(&rt, .grep, .{ .grep = .{ .path = "a.txt", .pattern = "[" } }));
    const empty = try run(&rt, .grep, .{ .grep = .{ .path = "a.txt", .pattern = "missing" } });
    defer rt.deinitResult(empty);
    try snap(@src(), "", empty.out[0].chunk);
}

test "basic tools: fd glob and grep honor ignore files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try guard.CwdGuard.enter(tmp.dir);
    defer cwd.deinit();
    try tmp.dir.createDirPath(std.testing.io, "lib");
    try tmp.dir.createDirPath(std.testing.io, "ignored");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".ignore", .data = "ignored/\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/a.zig", .data = "needle\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ignored/b.zig", .data = "needle\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/c.txt", .data = "needle\n" });
    var rt = builtin.Runtime.init(.{ .alloc = alloc });
    defer rt.deinit();
    const found = try run(&rt, .find, .{ .find = .{ .pattern = "**/*.zig" } });
    defer rt.deinitResult(found);
    try snap(@src(), "lib/a.zig\n", found.out[0].chunk);
    const hits = try run(&rt, .grep, .{ .grep = .{ .pattern = "needle", .glob = "*.zig" } });
    defer rt.deinitResult(hits);
    try snap(@src(), "lib/a.zig:1:needle\n", hits.out[0].chunk);
}

test "basic tools: patch applies multiple hunks and rejects stale context before writing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try guard.CwdGuard.enter(tmp.dir);
    defer cwd.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "one\ntwo\nthree\nfour\n" });
    var rt = builtin.Runtime.init(.{ .alloc = alloc });
    defer rt.deinit();
    const res = try run(&rt, .patch, .{ .patch = .{ .path = "a", .patch = "--- a\n+++ a\n@@ -1 +1 @@\n-one\n+ONE\n@@ -4 +4 @@\n-four\n+FOUR\n" } });
    defer rt.deinitResult(res);
    try std.testing.expectError(error.PatchMismatch, run(&rt, .patch, .{ .patch = .{ .path = "a", .patch = "@@ -1 +1 @@\n-stale\n+oops\n" } }));
    const data = try tmp.dir.readFileAlloc(std.testing.io, "a", alloc, .limited(1024));
    defer alloc.free(data);
    try snap(@src(), "ONE\ntwo\nthree\nFOUR\n", data);
    const created = try run(&rt, .patch, .{ .patch = .{ .path = "new", .patch = "@@ -0,0 +1 @@\n+new\n" } });
    defer rt.deinitResult(created);
    const new = try tmp.dir.readFileAlloc(std.testing.io, "new", alloc, .limited(1024));
    defer alloc.free(new);
    try snap(@src(), "new\n", new);
}

test "basic tools: patch preserves missing final newline and validates counts" {
    const text = try patch.applyAlloc(alloc, "old", "@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n", 100);
    defer alloc.free(text);
    try snap(@src(), "new", text);
    try std.testing.expectError(error.InvalidPatch, patch.applyAlloc(alloc, "old\n", "@@ -1,2 +1 @@\n-old\n+new\n", 100));
    try std.testing.expectError(error.TooLarge, patch.applyAlloc(alloc, "", "@@ -0,0 +1 @@\n+long\n", 2));
}

test "basic tools: todo persists within runtime and rejects multiple active tasks" {
    var rt = builtin.Runtime.init(.{ .alloc = alloc });
    defer rt.deinit();
    const updated = try run(&rt, .todo, .{ .todo = .{ .items = &.{ .{ .content = "fix", .status = .in_progress }, .{ .content = "verify" } } } });
    defer rt.deinitResult(updated);
    try std.testing.expectError(error.InvalidArgs, run(&rt, .todo, .{ .todo = .{ .items = &.{ .{ .content = "one", .status = .in_progress }, .{ .content = "two", .status = .in_progress } } } }));
    const current = try run(&rt, .todo, .{ .todo = .{} });
    defer rt.deinitResult(current);
    try snap(@src(), "[{\"content\":\"fix\",\"status\":\"in_progress\"},{\"content\":\"verify\",\"status\":\"pending\"}]", current.out[0].chunk);
}

test "basic tools: skill discovers lists and loads an actual project skill" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try guard.CwdGuard.enter(tmp.dir);
    defer cwd.deinit();
    try tmp.dir.createDirPath(std.testing.io, ".pz/skills/probe");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".pz/skills/probe/SKILL.md", .data = "---\nname: probe\ndescription: Smoke skill\n---\nUse this skill.\n" });
    var rt = builtin.Runtime.init(.{ .alloc = alloc });
    defer rt.deinit();
    const listed = try run(&rt, .skill, .{ .skill = .{} });
    defer rt.deinitResult(listed);
    try snap(@src(), "probe: Smoke skill\n", listed.out[0].chunk);
    const loaded = try run(&rt, .skill, .{ .skill = .{ .name = "probe" } });
    defer rt.deinitResult(loaded);
    try std.testing.expect(std.mem.indexOf(u8, loaded.out[0].chunk, "Use this skill.") != null);
}

test "basic tools: github uses default branch and encodes path and slash refs" {
    const url = try github.apiUrlAlloc(alloc, .{ .repo = "https://github.com/abhixdd/ghgrab", .path = "src/a b.rs", .ref = "feature/a&b" });
    defer alloc.free(url);
    try snap(@src(), "https://api.github.com/repos/abhixdd/ghgrab/contents/src/a%20b.rs?ref=feature%2Fa%26b", url);
    const root = try github.apiUrlAlloc(alloc, .{ .repo = "abhixdd/ghgrab" });
    defer alloc.free(root);
    try snap(@src(), "https://api.github.com/repos/abhixdd/ghgrab/contents", root);
    try std.testing.expectError(error.InvalidArgs, github.apiUrlAlloc(alloc, .{ .repo = "https://evil.test/x/y" }));
    try std.testing.expectError(error.InvalidArgs, github.apiUrlAlloc(alloc, .{ .repo = "x/y", .path = "../secret" }));
    const listing = try github.listAlloc(alloc, "[{\"path\":\"src\",\"type\":\"dir\",\"size\":0},{\"path\":\"README.md\",\"type\":\"file\",\"size\":42}]");
    defer alloc.free(listing);
    try snap(@src(), "dir\tsrc\t0 bytes\nfile\tREADME.md\t42 bytes\n", listing);
    const lines = try github.readLinesAlloc(alloc, "one\ntwo\nthree\n", 2, 2);
    defer alloc.free(lines);
    try snap(@src(), "2: two\n", lines);
    try std.testing.expectError(error.BinaryFile, github.readLinesAlloc(alloc, "a\x00b", 1, null));
}

test "basic tools: patch insertion roundtrips arbitrary printable text" {
    const zc = @import("zcheck");
    try zc.check(struct {
        fn prop(args: struct { bytes: [16]u8 }) bool {
            var text: [16]u8 = undefined;
            for (args.bytes, 0..) |byte, i| text[i] = 32 + byte % 95;
            const diff = std.fmt.allocPrint(alloc, "@@ -0,0 +1 @@\n+{s}\n", .{text}) catch return false;
            defer alloc.free(diff);
            const result = patch.applyAlloc(alloc, "", diff, 100) catch return false;
            defer alloc.free(result);
            return result.len == 17 and std.mem.eql(u8, result[0..16], &text) and result[16] == '\n';
        }
    }.prop, .{ .iterations = 100 });
}

test "basic tools: model guidance advertises github and omits disabled tools" {
    var rt = builtin.Runtime.init(.{ .alloc = alloc, .tool_mask = builtin.mask_github | builtin.mask_read });
    defer rt.deinit();
    const prompt = (try builtin.toolPromptAlloc(alloc, rt.registry(), "User instructions")).?;
    defer alloc.free(prompt);
    try std.testing.expect(std.mem.startsWith(u8, prompt, "User instructions\n\nAvailable tools: read github\n"));
    try std.testing.expect(std.mem.indexOf(u8, prompt, "use github before cloning") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Call skill") == null);
    rt.tool_mask = builtin.mask_read;
    const disabled = (try builtin.toolPromptAlloc(alloc, rt.registry(), null)).?;
    defer alloc.free(disabled);
    try snap(@src(), "Available tools: read\n", disabled);
}

test "basic tools: web fetch returns real status body and revalidates redirects" {
    const mock = @import("http_mock.zig");
    const web = @import("../core/tools/web.zig");
    var server = try mock.Server.init(alloc, &.{
        .{ .expect = .{ .target = "/start" }, .resp = .{ .status = "302 Found", .headers = &.{"Location: /final"} } },
        .{ .expect = .{ .target = "/final" }, .resp = .{ .status = "418 Teapot", .body = "actual body" } },
    });
    defer server.deinit();
    const thread = try server.spawn();
    var joined = false;
    defer if (!joined) server.join(thread) catch {};
    const url = try server.urlAlloc(alloc, "/start");
    defer alloc.free(url);
    const policy: web.RedirectPolicy = .{ .allow_private_addrs = true, .egress = .{ .rules = &.{.{ .pattern = "runtime/web/*", .effect = .allow }} } };
    const response = try web.fetchAlloc(alloc, .{ .url = url }, policy, 1024);
    defer alloc.free(response.body);
    try std.testing.expectEqual(@as(u16, 418), response.status);
    try snap(@src(), "actual body", response.body);
    joined = true;
    try server.join(thread);
    try std.testing.expectError(error.BlockedAddr, web.fetchAlloc(alloc, .{ .url = url }, .{ .egress = policy.egress }, 1024));
}

test "basic tools: edit diffs separate lines without final newlines" {
    const text = try @import("../core/tools/shared.zig").formatDiffAlloc(alloc, "a", "old", "old", "new");
    defer alloc.free(text);
    try snap(@src(), "• Edited a (+1 -1)\n@@ -1,1 +1,1 @@\n-old\n+new\n", text);
}

test "basic tools: web bounds status and body together" {
    const mock = @import("http_mock.zig");
    var server = try mock.Server.init(alloc, &.{.{ .resp = .{ .body = "abcdef" } }});
    defer server.deinit();
    const thread = try server.spawn();
    var joined = false;
    defer if (!joined) server.join(thread) catch {};
    const url = try server.urlAlloc(alloc, "/");
    defer alloc.free(url);
    var rt = builtin.Runtime.init(.{ .alloc = alloc, .max_bytes = 8, .egress = .{ .allow_private_addrs = true, .egress = .{ .rules = &.{.{ .pattern = "runtime/web/*", .effect = .allow }} } } });
    defer rt.deinit();
    const res = try run(&rt, .web, .{ .web = .{ .url = url } });
    defer rt.deinitResult(res);
    try snap(@src(), "HTTP 200", res.out[0].chunk);
    try std.testing.expectEqual(@as(usize, 2), res.out.len);
    try std.testing.expect(res.out[0].truncated);
    joined = true;
    try server.join(thread);
}
