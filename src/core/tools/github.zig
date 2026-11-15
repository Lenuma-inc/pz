//! Inspect public Git forges without a local checkout; compact model-facing output.
const std = @import("std");
const tools = @import("../tools.zig");
const web = @import("web.zig");
const shared = @import("shared.zig");

pub fn run(alloc: std.mem.Allocator, max_bytes: usize, policy: web.RedirectPolicy, call: tools.Call) !tools.Result {
    const args = call.args.github;
    const repo = try parseRepo(args);
    const url = try apiUrlAlloc(alloc, args);
    defer alloc.free(url);
    const response = try web.fetchAlloc(alloc, .{
        .url = url,
        .headers = &.{
            .{ .name = "Accept", .value = if (repo.api == .github) (if (args.op == .read) "application/vnd.github.raw+json" else "application/vnd.github+json") else if (repo.api == .cgit) "text/html, text/plain" else "application/json" },
            .{ .name = "User-Agent", .value = "pz" },
        },
    }, policy, if (args.op == .read) 2 * 1024 * 1024 else 8 * 1024 * 1024);
    defer alloc.free(response.body);
    switch (response.status) {
        200 => {},
        401 => return error.Unauthorized,
        403, 429 => return error.GitHubRateLimited,
        404 => return error.NotFound,
        else => return error.GitHubHttpStatus,
    }
    var text = if (repo.api == .cgit)
        try cgitTextAlloc(alloc, response.body, args, url)
    else if (repo.api == .gitoskop)
        try gitoskopTextAlloc(alloc, response.body, args)
    else switch (args.op) {
        .list => if (repo.api == .gitlab) try gitlabTreeAlloc(alloc, response.body, args) else try listAlloc(alloc, response.body),
        .read => try readLinesAlloc(alloc, response.body, args.from_line, args.to_line),
        .tree => if (repo.api == .gitlab) try gitlabTreeAlloc(alloc, response.body, args) else try treePageAlloc(alloc, response.body, args.path, if (repo.api == .github) null else args),
        else => try metadataAlloc(alloc, response.body, args),
    };
    errdefer alloc.free(text);
    if (repo.api == .github and (args.op == .list or args.op == .tree)) {
        const paged = try pageLinesAlloc(alloc, text, args.page, args.per_page);
        alloc.free(text);
        text = paged;
    }
    if (text.len > max_bytes) return error.TooLarge;
    return shared.buildResult(alloc, call.id, call.at_ms, text, max_bytes, text.len);
}

fn pageLinesAlloc(alloc: std.mem.Allocator, text: []const u8, page: u32, per_page: u32) ![]u8 {
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    const start = (@as(u64, page) - 1) * per_page;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var index: u64 = 0;
    while (lines.next()) |line| : (index += 1) {
        if (index < start) continue;
        if (index == start + per_page) {
            try out.writer.print("next page {d} (same op/path/ref)\n", .{@as(u64, page) + 1});
            break;
        }
        try out.writer.print("{s}\n", .{line});
    }
    return out.toOwnedSlice();
}

pub fn apiUrlAlloc(alloc: std.mem.Allocator, args: tools.Call.GithubArgs) ![]u8 {
    const repo = try parseRepo(args);
    if (std.mem.startsWith(u8, args.path, "/") or std.mem.indexOfScalar(u8, args.path, '\\') != null) return error.InvalidArgs;
    var path = std.mem.splitScalar(u8, args.path, '/');
    while (path.next()) |seg| if (std.mem.eql(u8, seg, "..") or std.mem.eql(u8, seg, ".")) return error.InvalidArgs;
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    if (args.page == 0 or args.per_page == 0 or args.per_page > 100) return error.InvalidArgs;
    if (args.from_line == 0 or args.to_line != null and args.to_line.? < args.from_line) return error.InvalidArgs;
    if (args.ref) |ref| if (ref.len == 0) return error.InvalidArgs;
    if (args.base) |base| if (base.len == 0) return error.InvalidArgs;
    if (args.op == .read and args.path.len == 0) return error.InvalidArgs;
    if (args.number) |number| if (number == 0 or (args.op != .issue and args.op != .comments)) return error.InvalidArgs;
    if ((args.op == .issue or args.op == .comments) and args.number == null) return error.InvalidArgs;
    if (args.offset != null and !(repo.api == .cgit and args.op == .history)) return error.InvalidArgs;
    if (repo.api == .cgit) return cgitUrlAlloc(alloc, args, repo);
    if (repo.api == .gitoskop) return gitoskopUrlAlloc(alloc, args, repo);
    if (repo.api != .github and (args.op == .commit or args.op == .compare)) return error.UnsupportedOperation;
    if (repo.api == .gitlab) return gitlabUrlAlloc(alloc, args, repo);
    if (repo.api == .github) {
        try out.writer.writeAll("https://api.github.com/repos/");
    } else {
        try out.writer.print("https://{s}/api/v1/repos/", .{repo.host});
    }
    try out.writer.writeAll(repo.path);
    switch (args.op) {
        .list, .read => {
            try out.writer.writeAll(if (repo.api != .github and args.op == .read) "/raw" else "/contents");
            if (args.path.len > 0) {
                try out.writer.writeByte('/');
                try std.Uri.Component.percentEncode(&out.writer, args.path, pathChar);
            }
            if (args.ref) |ref| {
                try out.writer.writeAll("?ref=");
                try std.Uri.Component.percentEncode(&out.writer, ref, unreserved);
            }
        },
        .tree => {
            try out.writer.writeAll("/git/trees/");
            try std.Uri.Component.percentEncode(&out.writer, args.ref orelse "HEAD", unreserved);
            try out.writer.writeAll("?recursive=1");
            if (repo.api != .github) try out.writer.print("&page={d}&per_page={d}", .{ args.page, args.per_page });
        },
        .history => {
            try out.writer.print("/commits?{s}={d}&page={d}", .{ if (repo.api == .github) "per_page" else "limit", args.per_page, args.page });
            if (args.ref) |ref| {
                try out.writer.writeAll("&sha=");
                try std.Uri.Component.percentEncode(&out.writer, ref, unreserved);
            }
            if (args.path.len > 0) {
                try out.writer.writeAll("&path=");
                try std.Uri.Component.percentEncode(&out.writer, args.path, unreserved);
            }
        },
        .commit => {
            try out.writer.writeAll("/commits/");
            try std.Uri.Component.percentEncode(&out.writer, args.ref orelse return error.InvalidArgs, unreserved);
            try out.writer.print("?per_page={d}&page={d}", .{ args.per_page, args.page });
        },
        .compare => {
            try out.writer.writeAll("/compare/");
            try std.Uri.Component.percentEncode(&out.writer, args.base orelse return error.InvalidArgs, unreserved);
            try out.writer.writeAll("...");
            try std.Uri.Component.percentEncode(&out.writer, args.ref orelse return error.InvalidArgs, unreserved);
            try out.writer.print("?per_page={d}&page={d}", .{ args.per_page, args.page });
        },
        .branches, .tags => try out.writer.print("/{s}?{s}={d}&page={d}", .{ @tagName(args.op), if (repo.api == .github) "per_page" else "limit", args.per_page, args.page }),
        .issues => try out.writer.print("/issues?state={s}&{s}={d}&page={d}", .{ @tagName(args.state), if (repo.api == .github) "per_page" else "limit", args.per_page, args.page }),
        .issue, .comments => {
            try out.writer.print("/issues/{d}", .{args.number.?});
            if (args.op == .comments) try out.writer.print("/comments?{s}={d}&page={d}", .{ if (repo.api == .github) "per_page" else "limit", args.per_page, args.page });
        },
        .info => {},
    }
    return out.toOwnedSlice();
}

fn unreserved(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "-._~", ch) != null;
}

fn pathChar(ch: u8) bool {
    return ch == '/' or unreserved(ch);
}

pub fn listAlloc(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    const Item = struct { path: []const u8, type: []const u8, size: u64 = 0 };
    const parsed = try std.json.parseFromSlice([]const Item, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.len >= 1000) return error.GitHubDirectoryLimit;
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    for (parsed.value) |item| {
        try out.writer.print("{s}{s}", .{ item.path, if (std.mem.eql(u8, item.type, "dir")) "/" else "" });
        if (!std.mem.eql(u8, item.type, "dir")) try out.writer.print(" {d}B {s}", .{ item.size, item.type });
        try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice();
}

pub fn readLinesAlloc(alloc: std.mem.Allocator, body: []const u8, from: u32, to: ?u32) ![]u8 {
    if (std.mem.indexOfScalar(u8, body, 0) != null or !std.unicode.utf8ValidateSlice(body)) return error.BinaryFile;
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    var lines = std.mem.splitScalar(u8, body, '\n');
    var n: u32 = 0;
    while (lines.next()) |line| {
        if (line.len == 0 and lines.index == null) break;
        n += 1;
        if (to) |end| if (n > end) break;
        if (n >= from) try out.writer.print("{d}: {s}\n", .{ n, line });
    }
    return out.toOwnedSlice();
}

pub fn treeAlloc(alloc: std.mem.Allocator, body: []const u8, path: []const u8) ![]u8 {
    return treePageAlloc(alloc, body, path, null);
}

pub fn treePageAlloc(alloc: std.mem.Allocator, body: []const u8, path: []const u8, args: ?tools.Call.GithubArgs) ![]u8 {
    const Item = struct { path: []const u8, type: []const u8, mode: []const u8, sha: []const u8, size: u64 = 0 };
    const Tree = struct { sha: []const u8, truncated: bool, tree: []const Item };
    const parsed = try std.json.parseFromSlice(Tree, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.truncated and args == null) return error.GitHubTreeTruncated;
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    try out.writer.print("tree {s}\n", .{parsed.value.sha});
    if (args) |a| {
        try out.writer.print("page {d} count {d}", .{ a.page, parsed.value.tree.len });
        if (parsed.value.truncated) try out.writer.print("; next page {d}", .{@as(u64, a.page) + 1});
        try out.writer.writeByte('\n');
    }
    const prefix = std.mem.trimEnd(u8, path, "/");
    for (parsed.value.tree) |item| {
        if (prefix.len > 0 and !std.mem.eql(u8, item.path, prefix) and
            !(std.mem.startsWith(u8, item.path, prefix) and item.path.len > prefix.len and item.path[prefix.len] == '/')) continue;
        try out.writer.print("{s}\t{s}\t{s}\t{s}\t{d} bytes\n", .{ item.mode, item.type, item.sha, item.path, item.size });
    }
    return out.toOwnedSlice();
}

const Api = @typeInfo(@FieldType(tools.Call.GithubArgs, "api")).optional.child;
const Repo = struct { api: Api, host: []const u8, path: []const u8 };

fn parseRepo(args: tools.Call.GithubArgs) !Repo {
    var repo: Repo = .{ .api = args.api orelse .github, .host = "github.com", .path = args.repo };
    if (std.mem.startsWith(u8, args.repo, "https://")) {
        const rest = args.repo[8..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidArgs;
        repo.host = rest[0..slash];
        repo.path = rest[slash + 1 ..];
        for (repo.host) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '-') return error.InvalidArgs;
        if (repo.host.len == 0) return error.InvalidArgs;
        // Backend selection is explicit, never inferred from a host allowlist.
        // GitHub's public API has a fixed origin; do not silently send an
        // unrelated HTTPS repository path to api.github.com.
        if (repo.api == .github and !std.mem.eql(u8, repo.host, "github.com")) return error.InvalidArgs;
    } else if (repo.api != .github) return error.InvalidArgs;
    var parts = std.mem.splitScalar(u8, repo.path, '/');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidArgs;
        for (part) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "-_.", ch) == null) return error.InvalidArgs;
        count += 1;
    }
    if (repo.api == .cgit or repo.api == .gitoskop) {
        if (count == 0) return error.InvalidArgs;
    } else if (count < 2 or (repo.api != .gitlab and count != 2)) return error.InvalidArgs;
    return repo;
}

fn gitlabUrlAlloc(alloc: std.mem.Allocator, args: tools.Call.GithubArgs, repo: Repo) ![]u8 {
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    try out.writer.print("https://{s}/api/v4/projects/", .{repo.host});
    try std.Uri.Component.percentEncode(&out.writer, repo.path, unreserved);
    switch (args.op) {
        .read => {
            try out.writer.writeAll("/repository/files/");
            try std.Uri.Component.percentEncode(&out.writer, args.path, unreserved);
            try out.writer.writeAll("/raw?ref=");
            try std.Uri.Component.percentEncode(&out.writer, args.ref orelse "HEAD", unreserved);
        },
        .list, .tree => {
            try out.writer.print("/repository/tree?per_page={d}&page={d}&recursive={s}&path=", .{ args.per_page, args.page, if (args.op == .tree) "true" else "false" });
            try std.Uri.Component.percentEncode(&out.writer, args.path, unreserved);
            if (args.ref) |ref| {
                try out.writer.writeAll("&ref=");
                try std.Uri.Component.percentEncode(&out.writer, ref, unreserved);
            }
        },
        .history => {
            try out.writer.print("/repository/commits?per_page={d}&page={d}", .{ args.per_page, args.page });
            if (args.ref) |ref| {
                try out.writer.writeAll("&ref_name=");
                try std.Uri.Component.percentEncode(&out.writer, ref, unreserved);
            }
            if (args.path.len > 0) {
                try out.writer.writeAll("&path=");
                try std.Uri.Component.percentEncode(&out.writer, args.path, unreserved);
            }
        },
        .branches, .tags => try out.writer.print("/repository/{s}?per_page={d}&page={d}", .{ @tagName(args.op), args.per_page, args.page }),
        .info => {},
        .issues => try out.writer.print("/issues?state={s}&per_page={d}&page={d}", .{ if (args.state == .open) "opened" else @tagName(args.state), args.per_page, args.page }),
        .issue, .comments => {
            try out.writer.print("/issues/{d}", .{args.number.?});
            if (args.op == .comments) try out.writer.print("/notes?per_page={d}&page={d}&sort=asc&order_by=created_at", .{ args.per_page, args.page });
        },
        .commit, .compare => return error.UnsupportedOperation,
    }
    return out.toOwnedSlice();
}

pub fn gitlabTreeAlloc(alloc: std.mem.Allocator, body: []const u8, args: tools.Call.GithubArgs) ![]u8 {
    const Item = struct { path: []const u8, type: []const u8, mode: []const u8, id: []const u8 };
    const parsed = try std.json.parseFromSlice([]const Item, alloc, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    try pageHeader(&out.writer, args, parsed.value.len);
    for (parsed.value) |item| try out.writer.print("{s} {s} {s}{s}\n", .{ item.mode, item.id, item.path, if (std.mem.eql(u8, item.type, "tree")) "/" else "" });
    return out.toOwnedSlice();
}

const Value = std.json.Value;
fn field(value: Value, key: []const u8) Value {
    return if (value == .object) value.object.get(key) orelse .null else .null;
}
fn str(value: Value) []const u8 {
    return if (value == .string) value.string else "";
}
fn textField(value: Value, key: []const u8) []const u8 {
    return str(field(value, key));
}
fn first(a: []const u8, b: []const u8) []const u8 {
    return if (a.len > 0) a else b;
}
fn oneLine(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| try w.writeByte(if (std.ascii.isControl(ch)) ' ' else ch);
}
fn pageHeader(w: *std.Io.Writer, args: tools.Call.GithubArgs, count: usize) !void {
    try w.print("page {d} count {d}", .{ args.page, count });
    if (count > 0) try w.print("; next page {d}", .{@as(u64, args.page) + 1});
    try w.writeByte('\n');
}
fn commitLine(w: *std.Io.Writer, value: Value) !void {
    const commit = field(value, "commit");
    const author = field(commit, "author");
    const msg = first(textField(commit, "message"), textField(value, "message"));
    if (first(textField(value, "sha"), textField(value, "id")).len == 0 or msg.len == 0) return error.InvalidResponse;
    try w.print("{s} {s} ", .{ first(textField(value, "sha"), textField(value, "id")), first(textField(author, "date"), textField(value, "created_at")) });
    try oneLine(w, first(textField(author, "name"), textField(value, "author_name")));
    try w.writeAll(" | ");
    try oneLine(w, msg[0 .. std.mem.indexOfScalar(u8, msg, '\n') orelse msg.len]);
    try w.writeByte('\n');
}

pub fn metadataAlloc(alloc: std.mem.Allocator, body: []const u8, args: tools.Call.GithubArgs) ![]u8 {
    const parsed = try std.json.parseFromSlice(Value, alloc, body, .{});
    defer parsed.deinit();
    const value = parsed.value;
    if (args.op == .issues or args.op == .issue or args.op == .comments) return discussionAlloc(alloc, value, args);
    switch (args.op) {
        .history, .branches, .tags => if (value != .array) return error.InvalidResponse,
        .info, .commit, .compare => if (value != .object) return error.InvalidResponse,
        else => return error.InvalidArgs,
    }
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    switch (args.op) {
        .history, .branches, .tags => {
            try pageHeader(w, args, value.array.items.len);
            for (value.array.items) |item| {
                if (item != .object) return error.InvalidResponse;
                if (args.op == .history) {
                    try commitLine(w, item);
                } else {
                    try oneLine(w, textField(item, "name"));
                    const commit = field(item, "commit");
                    try w.print(" {s}\n", .{first(textField(commit, "sha"), textField(commit, "id"))});
                }
            }
        },
        .info => {
            const keys = [_][]const u8{ "full_name", "path_with_namespace", "description", "default_branch", "language", "stargazers_count", "star_count", "forks_count", "archived", "visibility" };
            for (keys) |key| {
                const v = field(value, key);
                if (v == .null or v == .string and v.string.len == 0) continue;
                try w.print("{s}: ", .{key});
                switch (v) {
                    .string => |text| try oneLine(w, text),
                    .integer, .bool => try std.json.Stringify.value(v, .{}, w),
                    else => return error.InvalidResponse,
                }
                try w.writeByte('\n');
            }
            const license = field(value, "license");
            if (license == .object) try w.print("license: {s}\n", .{textField(license, "spdx_id")});
        },
        .commit, .compare => {
            try w.print("page {d}; next page {d} ({s})\n", .{ args.page, @as(u64, args.page) + 1, if (args.op == .commit) "files" else "commits" });
            try w.writeAll("GitHub patch limits: commit 3000 files; compare 300 files on page 1; missing patch is not proof of no changes.\n");
            if (args.op == .commit) {
                try commitLine(w, value);
                const msg = textField(field(value, "commit"), "message");
                if (std.mem.indexOfScalar(u8, msg, '\n') != null) try w.print("{s}\n", .{msg});
            } else {
                for ([_][]const u8{ "status", "ahead_by", "behind_by", "total_commits" }) |key| {
                    const v = field(value, key);
                    if (v == .null) continue;
                    try w.print("{s}: ", .{key});
                    switch (v) {
                        .string => |text| try oneLine(w, text),
                        .integer, .bool => try std.json.Stringify.value(v, .{}, w),
                        else => return error.InvalidResponse,
                    }
                    try w.writeByte('\n');
                }
                const commits = field(value, "commits");
                if (commits == .array) for (commits.array.items) |commit| {
                    try commitLine(w, commit);
                };
            }
            const files = field(value, "files");
            if (files == .array) for (files.array.items) |file| {
                try oneLine(w, textField(file, "status"));
                try w.writeByte(' ');
                try oneLine(w, textField(file, "filename"));
                const previous = textField(file, "previous_filename");
                if (previous.len > 0) {
                    try w.writeAll(" <- ");
                    try oneLine(w, previous);
                }
                try w.writeByte('\n');
                const patch = field(file, "patch");
                if (patch == .string) try w.print("{s}\n", .{patch.string}) else try w.writeAll("[patch unavailable]\n");
            };
        },
        else => return error.InvalidArgs,
    }
    return windowAlloc(alloc, &out, args);
}

fn cgitUrlAlloc(alloc: std.mem.Allocator, args: tools.Call.GithubArgs, repo: Repo) ![]u8 {
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    const verb: []const u8 = switch (args.op) {
        .list, .tree => "tree",
        .read => "plain",
        .history => "log",
        .commit, .compare => "patch",
        .branches, .tags => "refs",
        .info => "summary",
        else => return error.UnsupportedOperation,
    };
    if (args.page != 1) return error.UnsupportedOperation;
    try out.writer.print("https://{s}/{s}/{s}/", .{ repo.host, repo.path, verb });
    if (args.op == .list or args.op == .tree or args.op == .read or args.op == .history or args.op == .compare) try std.Uri.Component.percentEncode(&out.writer, args.path, pathChar);
    if (args.op == .branches or args.op == .tags) try out.writer.writeAll(if (args.op == .branches) "heads" else "tags");
    try out.writer.writeAll("?");
    if (args.op == .commit or args.op == .compare) {
        try out.writer.writeAll("id=");
        try std.Uri.Component.percentEncode(&out.writer, args.ref orelse return error.InvalidArgs, unreserved);
        if (args.op == .compare) {
            try out.writer.writeAll("&id2=");
            try std.Uri.Component.percentEncode(&out.writer, args.base orelse return error.InvalidArgs, unreserved);
        }
    } else if (args.ref) |ref| {
        try out.writer.writeAll("h=");
        try std.Uri.Component.percentEncode(&out.writer, ref, unreserved);
    }
    if (args.op == .history) try out.writer.print("&ofs={d}", .{args.offset orelse 0});
    return out.toOwnedSlice();
}

fn gitoskopUrlAlloc(alloc: std.mem.Allocator, args: tools.Call.GithubArgs, repo: Repo) ![]u8 {
    for ([_]?[]const u8{ args.ref, args.base }) |maybe| if (maybe) |ref| {
        if (ref[0] == '/' or std.mem.indexOf(u8, ref, "..") != null) return error.InvalidArgs;
        var segments = std.mem.splitScalar(u8, ref, '/');
        while (segments.next()) |segment| if (segment.len == 0 or std.mem.eql(u8, segment, ".")) return error.InvalidArgs;
    };
    if (args.op == .history and (@as(u64, args.page) - 1) * args.per_page > 50000) return error.InvalidArgs;
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    try out.writer.print("https://{s}/{s}", .{ repo.host, repo.path });
    switch (args.op) {
        .info => {},
        .branches, .tags => try out.writer.print("/{s}", .{@tagName(args.op)}),
        .list, .tree, .read => {
            try out.writer.print("/{s}/", .{if (args.op == .read) "raw" else "tree"});
            try std.Uri.Component.percentEncode(&out.writer, args.ref orelse "HEAD", pathChar);
            try out.writer.writeByte('/');
            try std.Uri.Component.percentEncode(&out.writer, args.path, pathChar);
        },
        .history => {
            try out.writer.writeAll("/log");
            if (args.ref) |ref| {
                try out.writer.writeByte('/');
                try std.Uri.Component.percentEncode(&out.writer, ref, pathChar);
            }
            try out.writer.print("?limit={d}&offset={d}&path=", .{ args.per_page, (@as(u64, args.page) - 1) * args.per_page });
            try std.Uri.Component.percentEncode(&out.writer, args.path, unreserved);
        },
        .commit => {
            try out.writer.writeAll("/show/");
            try std.Uri.Component.percentEncode(&out.writer, args.ref orelse return error.InvalidArgs, pathChar);
        },
        .compare => {
            try out.writer.writeAll("/patch/");
            try std.Uri.Component.percentEncode(&out.writer, args.base orelse return error.InvalidArgs, pathChar);
            try out.writer.writeAll("..");
            try std.Uri.Component.percentEncode(&out.writer, args.ref orelse return error.InvalidArgs, pathChar);
        },
        else => return error.UnsupportedOperation,
    }
    if ((args.op == .commit or args.op == .compare or args.op == .info or args.op == .read) and args.page != 1) return error.UnsupportedOperation;
    return out.toOwnedSlice();
}

fn discussionAlloc(alloc: std.mem.Allocator, value: Value, args: tools.Call.GithubArgs) ![]u8 {
    if (args.op == .issue and value != .object) return error.InvalidResponse;
    if (args.op != .issue and value != .array) return error.InvalidResponse;
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    const items = if (args.op == .issue) &[_]Value{value} else value.array.items;
    if (args.op != .issue) try pageHeader(w, args, items.len);
    for (items) |item| {
        if (item != .object) return error.InvalidResponse;
        const id = if (args.op == .comments) field(item, "id") else if (field(item, "number") != .null) field(item, "number") else field(item, "iid");
        if (id != .integer) return error.InvalidResponse;
        try w.print("{s} #{d}", .{ if (args.op == .comments) "comment" else "issue", id.integer });
        const state = textField(item, "state");
        if (state.len > 0) {
            try w.writeAll(" [");
            try oneLine(w, state);
            try w.writeByte(']');
        }
        const user = field(item, "user");
        const author = field(item, "author");
        try w.writeByte(' ');
        try oneLine(w, first(textField(user, "login"), textField(author, "username")));
        const title = textField(item, "title");
        if (title.len > 0) {
            try w.writeAll(" | ");
            try oneLine(w, title);
        }
        if (args.op == .comments) {
            try w.writeByte(' ');
            try oneLine(w, textField(item, "created_at"));
        }
        try w.writeByte('\n');
        if (args.op == .issue) {
            const url = first(textField(item, "html_url"), textField(item, "web_url"));
            if (url.len > 0) try w.print("{s}\n", .{url});
        }
        if (args.op != .issues) {
            const body = field(item, "body");
            const description = field(item, "description");
            if (body != .null and body != .string or description != .null and description != .string) return error.InvalidResponse;
            try w.print("{s}\n", .{first(str(body), str(description))});
        }
    }
    return windowAlloc(alloc, &out, args);
}

pub fn cgitTextAlloc(alloc: std.mem.Allocator, body: []const u8, args: tools.Call.GithubArgs, url: []const u8) ![]u8 {
    if (args.op == .read or args.op == .commit or args.op == .compare) return readLinesAlloc(alloc, body, args.from_line, args.to_line);
    const extracted = try @import("web_text.zig").extractAlloc(alloc, body, .{ .url = url });
    defer alloc.free(extracted);
    return std.fmt.allocPrint(alloc, "cgit: directory trees are non-recursive; log page size is server-defined. Continue log using offset from the next link's ofs parameter (not a guessed page stride).\n{s}", .{extracted});
}

pub fn gitoskopTextAlloc(alloc: std.mem.Allocator, body: []const u8, args: tools.Call.GithubArgs) ![]u8 {
    if (args.op == .read or args.op == .compare) return readLinesAlloc(alloc, body, args.from_line, args.to_line);
    const parsed = try std.json.parseFromSlice(Value, alloc, body, .{});
    defer parsed.deinit();
    const value = parsed.value;
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    switch (args.op) {
        .list, .tree => {
            const entries = field(value, "entries");
            if (entries != .array) return error.InvalidResponse;
            if (field(value, "truncated") == .bool and field(value, "truncated").bool) return error.GitTreeTruncated;
            try w.writeAll("Directory listing (non-recursive)\n");
            const start = @min((@as(u64, args.page) - 1) * args.per_page, entries.array.items.len);
            const end = @min(start + args.per_page, entries.array.items.len);
            for (entries.array.items[@intCast(start)..@intCast(end)]) |entry| {
                try w.print("{s}\t{s}\n", .{ first(textField(entry, "kind"), textField(entry, "mode")), textField(entry, "name") });
            }
            if (end < entries.array.items.len) try w.print("next page {d} (same op/path/ref)\n", .{@as(u64, args.page) + 1});
        },
        .branches, .tags, .history => {
            if (value != .array) return error.InvalidResponse;
            const local = args.op != .history;
            const start = if (local) @min((@as(u64, args.page) - 1) * args.per_page, value.array.items.len) else 0;
            const end = if (local) @min(start + args.per_page, value.array.items.len) else value.array.items.len;
            try pageHeader(w, args, @intCast(end - start));
            for (value.array.items[@intCast(start)..@intCast(end)]) |entry| {
                if (entry != .object) return error.InvalidResponse;
                if (args.op == .history) try gitoskopCommitLine(w, entry) else try w.print("{s} {s}\n", .{ textField(entry, "name"), textField(entry, "target") });
            }
        },
        .info => {
            if (value != .object) return error.InvalidResponse;
            for ([_][]const u8{ "default_branch", "branches", "tags", "size_bytes", "merge_status", "merge_with" }) |key| {
                const v = field(value, key);
                if (v == .null) continue;
                try w.print("{s}: ", .{key});
                switch (v) {
                    .string => |text| try oneLine(w, text),
                    .integer => |n| try w.print("{d}", .{n}),
                    else => return error.InvalidResponse,
                }
                try w.writeByte('\n');
            }
            const commit = field(value, "last_commit");
            if (commit != .null) try gitoskopCommitLine(w, commit);
        },
        .commit => {
            if (value != .object) return error.InvalidResponse;
            try w.print("{s} {s}\n{s}\n{s}\n", .{ textField(value, "oid"), textField(value, "author"), textField(value, "message"), textField(value, "patch") });
            if (field(value, "truncated") == .bool and field(value, "truncated").bool) try w.writeAll("[server truncated commit output; missing patch is not proof of no changes]\n");
        },
        else => return error.UnsupportedOperation,
    }
    return windowAlloc(alloc, &out, args);
}

fn gitoskopCommitLine(w: *std.Io.Writer, commit: Value) !void {
    if (commit != .object or textField(commit, "oid").len == 0) return error.InvalidResponse;
    try oneLine(w, textField(commit, "oid"));
    try w.writeByte(' ');
    try oneLine(w, textField(commit, "author"));
    try w.writeAll(" | ");
    try oneLine(w, textField(commit, "subject"));
    try w.writeByte('\n');
}

fn windowAlloc(alloc: std.mem.Allocator, out: *std.Io.Writer.Allocating, args: tools.Call.GithubArgs) ![]u8 {
    if (args.from_line == 1 and args.to_line == null) return out.toOwnedSlice();
    const text = try readLinesAlloc(alloc, out.written(), args.from_line, args.to_line);
    out.deinit();
    return text;
}
