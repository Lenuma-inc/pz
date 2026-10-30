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

test "basic tools: edit and patch large files with compact diffs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try guard.CwdGuard.enter(tmp.dir);
    defer cwd.deinit();
    const text = try alloc.alloc(u8, 128 * 1024 + 4);
    defer alloc.free(text);
    @memset(text, 'x');
    text[128 * 1024 - 1] = '\n';
    @memcpy(text[128 * 1024 ..], "old\n");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "large.py", .data = text });
    var rt = builtin.Runtime.init(.{ .alloc = alloc, .max_bytes = 256 });
    defer rt.deinit();
    const edited = try run(&rt, .edit, .{ .edit = .{ .path = "large.py", .old = "old\n", .new = "EDIT\n" } });
    defer rt.deinitResult(edited);
    try snap(@src(), "• Edited large.py (+1 -1)\n@@ -2,1 +2,1 @@\n-old\n+EDIT\n", edited.out[0].chunk);
    const patched = try run(&rt, .patch, .{ .patch = .{ .path = "large.py", .patch = "@@ -2 +2 @@\n-EDIT\n+PATCH\n" } });
    defer rt.deinitResult(patched);
    try snap(@src(), "• Edited large.py (+1 -1)\n@@ -2,1 +2,1 @@\n-EDIT\n+PATCH\n", patched.out[0].chunk);
    const got = try tmp.dir.readFileAlloc(std.testing.io, "large.py", alloc, .limited(text.len + 2));
    defer alloc.free(got);
    try std.testing.expectEqualStrings(text[0 .. 128 * 1024], got[0 .. 128 * 1024]);
    try std.testing.expectEqualStrings("PATCH\n", got[128 * 1024 ..]);
}

test "basic tools: edit and write bound responses without truncating files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd = try guard.CwdGuard.enter(tmp.dir);
    defer cwd.deinit();
    var rt = builtin.Runtime.init(.{ .alloc = alloc, .max_bytes = 64 });
    defer rt.deinit();
    const text = "changed\n" ** 100;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "old\n" });
    const edited = try run(&rt, .edit, .{ .edit = .{ .path = "a", .old = "old\n", .new = text } });
    defer rt.deinitResult(edited);
    const written = try run(&rt, .write, .{ .write = .{ .path = "b", .text = text } });
    defer rt.deinitResult(written);
    for ([_]tools.Result{ edited, written }) |res| {
        try std.testing.expect(res.out[0].truncated);
        try std.testing.expectEqual(@as(usize, 64), res.out[0].chunk.len);
        try std.testing.expectEqual(@as(usize, 2), res.out.len);
        try std.testing.expect(res.out[1].stream == .meta);
        try std.testing.expect(std.mem.indexOf(u8, res.out[1].chunk, "\"dropped_bytes\":") != null);
    }
    for ([_][]const u8{ "a", "b" }) |path| {
        const got = try tmp.dir.readFileAlloc(std.testing.io, path, alloc, .limited(1024));
        defer alloc.free(got);
        try std.testing.expectEqualStrings(text, got);
    }
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
    try snap(@src(), "src/\nREADME.md 42B file\n", listing);
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

test "github inspector encodes history and comparison revisions and paginates refs" {
    const cases = [_]struct { args: tools.Call.GithubArgs, url: []const u8 }{
        .{ .args = .{ .repo = "x/y", .op = .tree }, .url = "https://api.github.com/repos/x/y/git/trees/HEAD?recursive=1" },
        .{ .args = .{ .repo = "x/y", .op = .history, .path = "src/a b", .ref = "topic/a&b", .page = 2, .per_page = 10 }, .url = "https://api.github.com/repos/x/y/commits?per_page=10&page=2&sha=topic%2Fa%26b&path=src%2Fa%20b" },
        .{ .args = .{ .repo = "x/y", .op = .commit, .ref = "topic/a" }, .url = "https://api.github.com/repos/x/y/commits/topic%2Fa?per_page=30&page=1" },
        .{ .args = .{ .repo = "x/y", .op = .compare, .base = "v1", .ref = "topic/a" }, .url = "https://api.github.com/repos/x/y/compare/v1...topic%2Fa?per_page=30&page=1" },
        .{ .args = .{ .repo = "x/y", .op = .branches, .page = 3 }, .url = "https://api.github.com/repos/x/y/branches?per_page=30&page=3" },
        .{ .args = .{ .repo = "x/y", .op = .tags }, .url = "https://api.github.com/repos/x/y/tags?per_page=30&page=1" },
        .{ .args = .{ .repo = "x/y", .op = .info }, .url = "https://api.github.com/repos/x/y" },
    };
    inline for (cases) |case| {
        const url = try github.apiUrlAlloc(alloc, case.args);
        defer alloc.free(url);
        try snap(@src(), case.url, url);
    }
    const invalid = [_]tools.Call.GithubArgs{
        .{ .repo = "x/y", .op = .commit },
        .{ .repo = "x/y", .op = .compare, .ref = "main" },
        .{ .repo = "x/y", .page = 0 },
        .{ .repo = "x/y", .per_page = 101 },
        .{ .repo = "x/y", .ref = "" },
        .{ .repo = "x/y", .op = .read },
        .{ .repo = "x/y", .from_line = 2, .to_line = 1 },
    };
    for (invalid) |args| try std.testing.expectError(error.InvalidArgs, github.apiUrlAlloc(alloc, args));
}

test "github tree refuses incomplete trees and filters at path boundaries" {
    const body =
        \\{"sha":"root","truncated":false,"tree":[{"path":"src/a.zig","type":"blob","mode":"100644","sha":"a","size":7},{"path":"src2/b.zig","type":"blob","mode":"100644","sha":"b"},{"path":"src/link","type":"blob","mode":"120000","sha":"c","size":3}]}
    ;
    const tree = try github.treeAlloc(alloc, body, "src/");
    defer alloc.free(tree);
    try snap(@src(), "tree root\n100644\tblob\ta\tsrc/a.zig\t7 bytes\n120000\tblob\tc\tsrc/link\t3 bytes\n", tree);
    try std.testing.expectError(error.GitHubTreeTruncated, github.treeAlloc(alloc, "{\"sha\":\"a\",\"truncated\":true,\"tree\":[]}", ""));
    try std.testing.expectError(error.MissingField, github.treeAlloc(alloc, "{\"sha\":\"a\",\"tree\":[]}", ""));
}

test "github history preserves metadata and makes pagination explicit" {
    const text = try github.metadataAlloc(alloc, "[]", .{ .repo = "x/y", .op = .history, .page = 2, .per_page = 10 });
    defer alloc.free(text);
    try snap(@src(), "page 2 count 0\n", text);
    try std.testing.expectError(error.InvalidResponse, github.metadataAlloc(alloc, "{}", .{ .repo = "x/y", .op = .history }));
    try std.testing.expectError(error.InvalidResponse, github.metadataAlloc(alloc, "[]", .{ .repo = "x/y", .op = .commit, .ref = "main" }));
    const commit = try github.metadataAlloc(alloc, "{\"sha\":\"abc\",\"commit\":{\"message\":\"Fix\"},\"files\":[{\"filename\":\"a\",\"patch\":\"+hello\"}]}", .{ .repo = "x/y", .op = .commit, .ref = "main" });
    defer alloc.free(commit);
    try std.testing.expect(std.mem.indexOf(u8, commit, "+hello\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, commit, "missing patch is not proof") != null);
}

test "github history query keeps arbitrary printable refs inside one parameter" {
    const zc = @import("zcheck");
    try zc.check(struct {
        fn prop(args: struct { bytes: [24]u8 }) bool {
            var ref: [24]u8 = undefined;
            for (args.bytes, 0..) |byte, i| ref[i] = 32 + byte % 95;
            const url = github.apiUrlAlloc(alloc, .{ .repo = "x/y", .op = .history, .ref = &ref }) catch return false;
            defer alloc.free(url);
            const value = url[(std.mem.indexOf(u8, url, "&sha=") orelse return false) + 5 ..];
            for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "-._~%", ch) == null) return false;
            return true;
        }
    }.prop, .{ .iterations = 100 });
}

test "github forge URLs encode nested namespaces and reject ambiguous hosts" {
    const Case = struct { args: tools.Call.GithubArgs, url: []const u8 };
    const cases = [_]Case{
        .{ .args = .{ .repo = "https://gitlab.com/group/sub/repo", .op = .read, .path = "src/a b", .ref = "topic/a&b" }, .url = "https://gitlab.com/api/v4/projects/group%2Fsub%2Frepo/repository/files/src%2Fa%20b/raw?ref=topic%2Fa%26b" },
        .{ .args = .{ .repo = "https://gitlab.com/g/r", .op = .tree, .page = 2 }, .url = "https://gitlab.com/api/v4/projects/g%2Fr/repository/tree?per_page=30&page=2&recursive=true&path=" },
        .{ .args = .{ .repo = "https://codeberg.org/forgejo/forgejo", .op = .read, .path = "README.md" }, .url = "https://codeberg.org/api/v1/repos/forgejo/forgejo/raw/README.md" },
        .{ .args = .{ .repo = "https://forge.example/a/b", .api = .gitea, .op = .history, .ref = "a/b", .path = "a b", .page = 3 }, .url = "https://forge.example/api/v1/repos/a/b/commits?limit=30&page=3&sha=a%2Fb&path=a%20b" },
        .{ .args = .{ .repo = "https://gitea.com/a/b", .op = .tags }, .url = "https://gitea.com/api/v1/repos/a/b/tags?limit=30&page=1" },
        .{ .args = .{ .repo = "https://codeberg.org/a/b", .op = .tree }, .url = "https://codeberg.org/api/v1/repos/a/b/git/trees/HEAD?recursive=1&page=1&per_page=30" },
    };
    inline for (cases) |case| {
        const url = try github.apiUrlAlloc(alloc, case.args);
        defer alloc.free(url);
        try snap(@src(), case.url, url);
    }
    const examples = [_]tools.Call.GithubArgs{
        .{ .repo = "https://git.linux-gaming.ru/Linux-Gaming/PortProtonQt", .api = .gitea },
        .{ .repo = "https://altlinux.space/rirusha/Cassette", .api = .forgejo },
    };
    inline for (examples) |args| {
        const url = try github.apiUrlAlloc(alloc, args);
        defer alloc.free(url);
        try snap(@src(), if (args.api.? == .gitea) "https://git.linux-gaming.ru/api/v1/repos/Linux-Gaming/PortProtonQt/contents" else "https://altlinux.space/api/v1/repos/rirusha/Cassette/contents", url);
    }
    const invalid = [_]tools.Call.GithubArgs{
        .{ .repo = "https://unknown.test/a/b" },
        .{ .repo = "https://gitlab.com/a/b", .api = .github },
        .{ .repo = "a/b", .api = .gitlab },
        .{ .repo = "https://user@forge.test/a/b", .api = .gitea },
        .{ .repo = "https://forge.test/a/../b", .api = .gitea },
        .{ .repo = "https://gitlab.com/a/b?token=secret" },
        .{ .repo = "http://gitlab.com/a/b" },
    };
    for (invalid) |args| try std.testing.expectError(error.InvalidArgs, github.apiUrlAlloc(alloc, args));
    try std.testing.expectError(error.UnsupportedOperation, github.apiUrlAlloc(alloc, .{ .repo = "https://gitlab.com/a/b", .op = .compare, .base = "a", .ref = "b" }));
}

test "github compact metadata removes API noise but preserves useful evidence" {
    const history = try github.metadataAlloc(alloc,
        \\[{"sha":"abc123","url":"https://api.test/noise","author":{"avatar_url":"noise"},"commit":{"message":"Fix parser\n\nDetails","author":{"name":"Ada","date":"2026-10-30"}}}]
    , .{ .repo = "x/y", .op = .history, .per_page = 1 });
    defer alloc.free(history);
    try snap(@src(), "page 1 count 1; next page 2\nabc123 2026-10-30 Ada | Fix parser\n", history);
    const gitlab = try github.metadataAlloc(alloc,
        \\[{"id":"def456","message":"Fix parser\nDetails","author_name":"Ada","created_at":"2026-10-30","web_url":"noise"}]
    , .{ .repo = "https://gitlab.com/x/y", .op = .history });
    defer alloc.free(gitlab);
    try snap(@src(), "page 1 count 1; next page 2\ndef456 2026-10-30 Ada | Fix parser\n", gitlab);
    const info = try github.metadataAlloc(alloc,
        \\{"full_name":"x/y","description":"Parser","default_branch":"main","stargazers_count":12,"archived":false,"license":{"spdx_id":"MIT"},"owner":{"avatar_url":"noise"},"hooks_url":"noise"}
    , .{ .repo = "x/y", .op = .info });
    defer alloc.free(info);
    try snap(@src(), "full_name: x/y\ndescription: Parser\ndefault_branch: main\nstargazers_count: 12\narchived: false\nlicense: MIT\n", info);
    const refs = try github.metadataAlloc(alloc, "[{\"name\":\"main\",\"commit\":{\"id\":\"abc\"},\"protected\":true}]", .{ .repo = "x/y", .op = .branches });
    defer alloc.free(refs);
    try snap(@src(), "page 1 count 1; next page 2\nmain abc\n", refs);
    const commit = try github.metadataAlloc(alloc,
        \\{"sha":"abc","commit":{"message":"Fix","author":{"name":"Ada","date":"today"}},"files":[{"filename":"new","previous_filename":"old","status":"renamed","patch":"@@ -1 +1 @@\n-old\n+new"},{"filename":"binary","status":"added"}],"url":"noise"}
    , .{ .repo = "x/y", .op = .commit, .ref = "abc" });
    defer alloc.free(commit);
    try snap(@src(), "page 1; next page 2 (files)\nGitHub patch limits: commit 3000 files; compare 300 files on page 1; missing patch is not proof of no changes.\nabc today Ada | Fix\nrenamed new <- old\n@@ -1 +1 @@\n-old\n+new\nadded binary\n[patch unavailable]\n", commit);
    try std.testing.expectError(error.InvalidResponse, github.metadataAlloc(alloc, "[{\"sha\":\"abc\"}]", .{ .repo = "x/y", .op = .history }));
    try std.testing.expectError(error.InvalidResponse, github.metadataAlloc(alloc, "{\"description\":{\"url\":\"noise\"}}", .{ .repo = "x/y", .op = .info }));
}

test "github forge trees distinguish pagination from incomplete GitHub trees" {
    const body =
        \\{"sha":"root","truncated":true,"tree":[{"path":"src/a","type":"blob","mode":"100644","sha":"a","size":7}]}
    ;
    const page = try github.treePageAlloc(alloc, body, "src", .{ .repo = "https://codeberg.org/a/b", .op = .tree, .page = 2 });
    defer alloc.free(page);
    try snap(@src(), "tree root\npage 2 count 1; next page 3\n100644\tblob\ta\tsrc/a\t7 bytes\n", page);
    try std.testing.expectError(error.GitHubTreeTruncated, github.treeAlloc(alloc, body, "src"));
    const gitlab = try github.gitlabTreeAlloc(alloc, "[{\"path\":\"src\",\"type\":\"tree\",\"mode\":\"040000\",\"id\":\"abc\"}]", .{ .repo = "https://gitlab.com/a/b", .op = .tree });
    defer alloc.free(gitlab);
    try snap(@src(), "page 1 count 1; next page 2\n040000 abc src/\n", gitlab);
}

test "github compact comparison retains status commits and readable patches" {
    const body =
        \\{"status":"ahead","ahead_by":1,"behind_by":0,"total_commits":1,"commits":[{"sha":"abc","commit":{"message":"Fix","author":{"name":"Ada","date":"today"}},"url":"noise"}],"files":[{"filename":"a","status":"modified","patch":"-old\n+new"}],"url":"noise","html_url":"noise","permalink_url":"noise"}
    ;
    const text = try github.metadataAlloc(alloc, body, .{ .repo = "x/y", .op = .compare, .base = "a", .ref = "b" });
    defer alloc.free(text);
    try snap(@src(), "page 1; next page 2 (commits)\nGitHub patch limits: commit 3000 files; compare 300 files on page 1; missing patch is not proof of no changes.\nstatus: ahead\nahead_by: 1\nbehind_by: 0\ntotal_commits: 1\nabc today Ada | Fix\nmodified a\n-old\n+new\n", text);
}
