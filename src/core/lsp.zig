//! Small stdio LSP client for on-demand project diagnostics.
const std = @import("std");
const sys = @import("pz_io");
const path_guard = @import("tools/path_guard.zig");
const sandbox = @import("sandbox.zig");

const max_frame = 1024 * 1024;
const timeout_ms = 5000;

const ServerDef = struct { name: []const u8, extension: []const u8, command: []const u8, args: []const []const u8 = &.{}, extensions: ?[]const []const u8 = null, env: ?std.json.ArrayHashMap([]const u8) = null, initialization: ?std.json.Value = null };
const servers = [_]ServerDef{
    .{ .name = "bash", .extension = ".sh", .command = "bash-language-server", .args = &.{"start"} },
    .{ .name = "pyright", .extension = ".py", .command = "pyright-langserver", .args = &.{"--stdio"} },
    .{ .name = "zls", .extension = ".zig", .command = "zls" },
    .{ .name = "gopls", .extension = ".go", .command = "gopls" },
    .{ .name = "clangd", .extension = ".c", .command = "clangd" },
    .{ .name = "rust-analyzer", .extension = ".rs", .command = "rust-analyzer" },
    .{ .name = "typescript-language-server", .extension = ".ts", .command = "typescript-language-server", .args = &.{"--stdio"} },
    .{ .name = "yaml-language-server", .extension = ".yaml", .command = "yaml-language-server", .args = &.{"--stdio"} },
    .{ .name = "vscode-json-language-server", .extension = ".json", .command = "vscode-json-language-server", .args = &.{"--stdio"} },
    .{ .name = "lua-language-server", .extension = ".lua", .command = "lua-language-server" },
    .{ .name = "nixd", .extension = ".nix", .command = "nixd" },
    .{ .name = "marksman", .extension = ".md", .command = "marksman", .args = &.{"server"} },
    .{ .name = "taplo", .extension = ".toml", .command = "taplo", .args = &.{ "lsp", "stdio" } },
};

const Download = struct {
    name: []const u8,
    installer: enum { npm, go, cargo },
    packages: []const []const u8,
};
const downloads = [_]Download{
    .{ .name = "bash", .installer = .npm, .packages = &.{"bash-language-server"} },
    .{ .name = "pyright", .installer = .npm, .packages = &.{"pyright"} },
    .{ .name = "typescript-language-server", .installer = .npm, .packages = &.{ "typescript-language-server", "typescript" } },
    .{ .name = "yaml-language-server", .installer = .npm, .packages = &.{"yaml-language-server"} },
    .{ .name = "vscode-json-language-server", .installer = .npm, .packages = &.{"vscode-langservers-extracted"} },
    .{ .name = "gopls", .installer = .go, .packages = &.{"golang.org/x/tools/gopls@latest"} },
    .{ .name = "taplo", .installer = .cargo, .packages = &.{"taplo-cli"} },
};

pub const download_labels = labels: {
    var result: [downloads.len][]const u8 = undefined;
    for (downloads, 0..) |item, i| {
        result[i] = item.name ++ switch (item.installer) {
            .npm => " — requires Node.js + npm",
            .go => " — requires Go",
            .cargo => " — requires Rust + Cargo",
        };
    }
    break :labels result;
};

pub fn downloadName(index: usize) []const u8 {
    return downloads[index].name;
}

fn downloadMenuAlloc(alloc: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("Choose a server with /lsp download <server>:\n");
    for (download_labels) |label| try out.writer.print("{s}\n", .{label});
    return alloc.dupe(u8, out.written());
}

pub fn downloadAlloc(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    if (name.len == 0) return downloadMenuAlloc(alloc);
    if (name.len != 0) {
        var known = false;
        for (downloads) |item| if (std.mem.eql(u8, item.name, name)) {
            known = true;
            break;
        };
        if (!known) return downloadMenuAlloc(alloc);
    }
    var count: usize = 0;
    while (std.c.environ[count] != null) : (count += 1) {}
    var env = try std.process.Environ.createMap(.{ .block = .{ .slice = std.c.environ[0..count :null] } }, alloc);
    defer env.deinit();
    sandbox.scrubEnv(&env);
    const home = env.get("HOME") orelse return error.HomeUnavailable;
    if (!std.fs.path.isAbsolute(home)) return error.HomeUnavailable;
    const prefix = try std.fs.path.join(alloc, &.{ home, ".local" });
    defer alloc.free(prefix);
    const bin = try std.fs.path.join(alloc, &.{ prefix, "bin" });
    defer alloc.free(bin);
    try std.Io.Dir.cwd().createDirPath(sys.io, bin);
    try env.put("GOBIN", bin);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    for (downloads) |item| {
        if (!std.mem.eql(u8, item.name, name)) continue;
        const installer = @tagName(item.installer);
        if (item.installer == .npm and !commandAvailable("node")) {
            try out.writer.print("{s}: install Node.js + npm first.\n", .{item.name});
            continue;
        }
        if (!commandAvailable(installer)) {
            try out.writer.print("{s}: skipped; install {s} first.\n", .{ item.name, installer });
            continue;
        }
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(alloc);
        switch (item.installer) {
            .npm => try argv.appendSlice(alloc, &.{ "npm", "install", "--global", "--prefix", prefix, "--no-audit", "--no-fund", "--loglevel=error" }),
            .go => try argv.appendSlice(alloc, &.{ "go", "install" }),
            .cargo => try argv.appendSlice(alloc, &.{ "cargo", "install", "--locked", "--quiet", "--root", prefix }),
        }
        try argv.appendSlice(alloc, item.packages);
        const result = std.process.run(alloc, sys.io, .{
            .argv = argv.items,
            .environ_map = &env,
            .cwd = .{ .path = prefix },
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        }) catch |err| {
            try out.writer.print("{s}: download failed ({s}).\n", .{ item.name, @errorName(err) });
            continue;
        };
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0) {
            try out.writer.print("{s}: installed in {s}.\n", .{ item.name, bin });
        } else {
            const details = if (result.stderr.len > 0) result.stderr else result.stdout;
            try out.writer.print("{s}: download failed.\n{s}\n", .{ item.name, details[0..@min(details.len, 4096)] });
        }
    }
    return alloc.dupe(u8, out.written());
}

const ServerConfig = struct {
    command: ?[]const []const u8 = null,
    extensions: ?[]const []const u8 = null,
    env: ?std.json.ArrayHashMap([]const u8) = null,
    initialization: ?std.json.Value = null,
    disabled: bool = false, // Legacy setting accepted for compatibility; servers are always enabled.
};
const ConfigMap = std.json.ArrayHashMap(ServerConfig);

pub fn validate(value: std.json.Value) !void {
    if (value == .bool) return;
    if (value != .object or value.object.count() + servers.len > 64) return error.InvalidLspConfig;
    const parsed = std.json.parseFromValue(ConfigMap, std.heap.page_allocator, value, .{}) catch return error.InvalidLspConfig;
    defer parsed.deinit();
    for (parsed.value.map.keys(), parsed.value.map.values()) |name, cfg| {
        if (name.len == 0) return error.InvalidLspConfig;
        var builtin = false;
        for (servers) |def| if (std.mem.eql(u8, def.name, name)) {
            builtin = true;
            break;
        };
        if (cfg.command) |cmd| {
            if (cmd.len == 0) return error.InvalidLspConfig;
            for (cmd) |arg| if (arg.len == 0 or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidLspConfig;
        } else if (!builtin) return error.InvalidLspConfig;
        if (!builtin and cfg.extensions == null) return error.InvalidLspConfig;
        if (cfg.extensions) |exts| {
            if (exts.len == 0) return error.InvalidLspConfig;
            for (exts) |ext| if (ext.len < 2 or ext[0] != '.') return error.InvalidLspConfig;
        }
        if (cfg.initialization) |init| if (init != .object) return error.InvalidLspConfig;
    }
}

pub const Args = struct {
    operation: enum { diagnostics, goToDefinition, findReferences, hover, documentSymbol, workspaceSymbol, goToImplementation, prepareCallHierarchy, incomingCalls, outgoingCalls },
    filePath: []const u8,
    line: u32 = 1,
    character: u32 = 1,
    query: []const u8 = "",
};

const Diagnostic = struct { line: usize, character: usize, severity: usize, message: []const u8 };
const Client = struct {
    def: ServerDef,
    child: std.process.Child,
    root_uri: []u8,
    pending: std.ArrayList(u8) = .empty,
    diagnostics: std.StringHashMapUnmanaged([]Diagnostic) = .empty,
    documents: std.StringHashMapUnmanaged(u32) = .empty,
    next_id: i64 = 0,
    closed: bool = false,
    supports_pull: bool = false,

    fn deinit(self: *Client, alloc: std.mem.Allocator) void {
        self.close();
        self.pending.deinit(alloc);
        var it = self.diagnostics.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |d| alloc.free(d.message);
            alloc.free(entry.value_ptr.*);
        }
        self.diagnostics.deinit(alloc);
        var docs = self.documents.iterator();
        while (docs.next()) |entry| alloc.free(entry.key_ptr.*);
        self.documents.deinit(alloc);
        alloc.free(self.root_uri);
    }

    fn close(self: *Client) void {
        if (self.closed) return;
        if (self.child.id) |pid| std.posix.kill(-pid, std.posix.SIG.KILL) catch {};
        self.child.kill(sys.io);
        self.closed = true;
    }

    fn frame(self: *Client, alloc: std.mem.Allocator, value: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(alloc, value, .{});
        defer alloc.free(json);
        if (json.len > max_frame) return error.LspFrameTooLarge;
        const bytes = try std.fmt.allocPrint(alloc, "Content-Length: {d}\r\n\r\n{s}", .{ json.len, json });
        defer alloc.free(bytes);
        if (self.closed) return error.LspClosed;
        const deadline = sys.nowMs() + timeout_ms;
        var at: usize = 0;
        while (at < bytes.len) {
            const remaining = deadline - sys.nowMs();
            if (remaining <= 0) return error.LspTimeout;
            var fds = [_]std.posix.pollfd{.{ .fd = self.child.stdin.?.handle, .events = std.posix.POLL.OUT, .revents = 0 }};
            if (try std.posix.poll(&fds, @intCast(@min(remaining, 50))) == 0) continue;
            const n = std.c.write(self.child.stdin.?.handle, bytes[at..].ptr, bytes.len - at);
            switch (std.posix.errno(n)) {
                .SUCCESS => {},
                .AGAIN, .INTR => continue,
                .PIPE => return error.LspClosed,
                else => return error.LspIo,
            }
            if (n == 0) return error.LspClosed;
            at += @intCast(n);
        }
    }

    fn receive(self: *Client, alloc: std.mem.Allocator, deadline: i64) !std.json.Parsed(std.json.Value) {
        while (true) {
            if (std.mem.indexOf(u8, self.pending.items, "\r\n\r\n")) |sep| {
                const headers = self.pending.items[0..sep];
                var length: ?usize = null;
                var lines = std.mem.splitSequence(u8, headers, "\r\n");
                while (lines.next()) |line| if (std.ascii.startsWithIgnoreCase(line, "Content-Length:")) {
                    length = std.fmt.parseInt(usize, std.mem.trim(u8, line[15..], " \t"), 10) catch return error.LspInvalidFrame;
                };
                const size = length orelse return error.LspInvalidFrame;
                if (size > max_frame) return error.LspFrameTooLarge;
                const start = sep + 4;
                if (self.pending.items.len >= start + size) {
                    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, self.pending.items[start .. start + size], .{ .allocate = .alloc_always, .max_value_len = max_frame });
                    const rest = self.pending.items.len - start - size;
                    std.mem.copyForwards(u8, self.pending.items[0..rest], self.pending.items[start + size ..]);
                    self.pending.items.len = rest;
                    return parsed;
                }
            }
            const remain = deadline - std.Io.Clock.real.now(sys.io).toMilliseconds();
            if (remain <= 0) return error.LspTimeout;
            var fds = [_]std.posix.pollfd{.{ .fd = self.child.stdout.?.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&fds, @intCast(@min(remain, 50))) == 0) continue;
            var buf: [4096]u8 = undefined;
            const n = std.posix.read(self.child.stdout.?.handle, &buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return err,
            };
            if (n == 0) return error.LspClosed;
            if (self.pending.items.len + n > max_frame + 65536) return error.LspFrameTooLarge;
            try self.pending.appendSlice(alloc, buf[0..n]);
        }
    }

    fn request(self: *Client, alloc: std.mem.Allocator, method: []const u8, params: anytype) !std.json.Parsed(std.json.Value) {
        if (self.closed) return error.LspClosed;
        errdefer self.close();
        self.next_id += 1;
        const id = self.next_id;
        try self.frame(alloc, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params });
        const deadline = std.Io.Clock.real.now(sys.io).toMilliseconds() + timeout_ms;
        while (true) {
            const reply = try self.receive(alloc, deadline);
            const v = reply.value;
            if (v == .object) {
                if (v.object.get("method") != null) {
                    self.handleMessage(alloc, v) catch {};
                } else if (v.object.get("id")) |rid| {
                    if (rid == .integer and rid.integer == id) return reply;
                }
            }
            reply.deinit();
        }
    }

    fn handleMessage(self: *Client, alloc: std.mem.Allocator, value: std.json.Value) !void {
        if (value != .object) return;
        const method = value.object.get("method") orelse return;
        if (method != .string) return;
        const params = value.object.get("params") orelse .null;
        if (value.object.get("id")) |id| {
            if (std.mem.eql(u8, method.string, "workspace/configuration")) {
                var items: std.ArrayList(std.json.Value) = .empty;
                defer items.deinit(alloc);
                if (params == .object) if (params.object.get("items")) |list| {
                    if (list == .array) for (list.array.items) |item| {
                        var result = self.def.initialization orelse .null;
                        if (item == .object) if (item.object.get("section")) |section| {
                            if (section == .string) {
                                var parts = std.mem.splitScalar(u8, section.string, '.');
                                while (parts.next()) |part| result = if (result == .object) result.object.get(part) orelse .null else .null;
                            }
                        };
                        try items.append(alloc, result);
                    };
                };
                try self.frame(alloc, .{ .jsonrpc = "2.0", .id = id, .result = items.items });
            } else if (std.mem.eql(u8, method.string, "workspace/workspaceFolders")) {
                try self.frame(alloc, .{ .jsonrpc = "2.0", .id = id, .result = .{.{ .uri = self.root_uri, .name = "workspace" }} });
            } else if (std.mem.eql(u8, method.string, "window/workDoneProgress/create") or std.mem.eql(u8, method.string, "workspace/diagnostic/refresh")) {
                try self.frame(alloc, .{ .jsonrpc = "2.0", .id = id, .result = @as(?u8, null) });
            } else {
                try self.frame(alloc, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = @as(i32, -32601), .message = "Client capability not supported" } });
            }
        } else if (std.mem.eql(u8, method.string, "textDocument/publishDiagnostics")) {
            try self.storeDiagnostics(alloc, params);
        }
    }

    fn storeDiagnostics(self: *Client, alloc: std.mem.Allocator, params: std.json.Value) !void {
        if (params != .object) return;
        const uri = params.object.get("uri") orelse return;
        if (params.object.get("version")) |version| {
            if (uri == .string and version == .integer) if (self.documents.get(uri.string)) |current| {
                if (version.integer < current) return;
            };
        }
        const list = params.object.get("diagnostics") orelse return;
        if (uri != .string or list != .array) return;
        try self.storeDiagnosticList(alloc, uri.string, list);
    }

    fn storeDiagnosticList(self: *Client, alloc: std.mem.Allocator, uri: []const u8, list: std.json.Value) !void {
        if (list != .array) return;
        const key = try alloc.dupe(u8, uri);
        errdefer alloc.free(key);
        const out = try alloc.alloc(Diagnostic, list.array.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |d| alloc.free(d.message);
            alloc.free(out);
        }
        for (list.array.items) |item| {
            if (item != .object) continue;
            const range = item.object.get("range") orelse continue;
            const msg = item.object.get("message") orelse continue;
            if (range != .object or msg != .string) continue;
            const start = range.object.get("start") orelse continue;
            if (start != .object) continue;
            const line = start.object.get("line") orelse continue;
            const col = start.object.get("character") orelse continue;
            const sev = item.object.get("severity") orelse .null;
            out[n] = .{ .line = if (line == .integer and line.integer >= 0 and line.integer < std.math.maxInt(i64)) @intCast(line.integer + 1) else 1, .character = if (col == .integer and col.integer >= 0 and col.integer < std.math.maxInt(i64)) @intCast(col.integer + 1) else 1, .severity = if (sev == .integer) @intCast(@max(1, sev.integer)) else 3, .message = try alloc.dupe(u8, msg.string) };
            n += 1;
        }
        try self.diagnostics.ensureUnusedCapacity(alloc, 1);
        const owned = try alloc.realloc(out, n);
        if (self.diagnostics.fetchRemove(key)) |old| {
            alloc.free(old.key);
            for (old.value) |d| alloc.free(d.message);
            alloc.free(old.value);
        }
        self.diagnostics.putAssumeCapacity(key, owned);
    }
};

pub const Manager = struct {
    alloc: std.mem.Allocator,
    root_uri: []u8,
    clients: std.ArrayList(Client) = .empty,
    unavailable: [64]bool = @splat(false),
    definitions: std.ArrayList(ServerDef) = .empty,
    config: ?std.json.Parsed(ConfigMap) = null,

    pub fn create(alloc: std.mem.Allocator, raw: []const u8) !Manager {
        const root = try std.Io.Dir.cwd().realPathFileAlloc(sys.io, ".", alloc);
        defer alloc.free(root);
        var manager = Manager{ .alloc = alloc, .root_uri = try pathUriAlloc(alloc, root) };
        errdefer manager.deinit();
        const value = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
        defer value.deinit();
        try validate(value.value);
        try manager.definitions.appendSlice(alloc, &servers);
        if (value.value == .object) {
            manager.config = try std.json.parseFromSlice(ConfigMap, alloc, raw, .{ .allocate = .alloc_always });
            const map = manager.config.?.value.map;
            for (map.keys(), map.values()) |name, cfg| {
                var def = ServerDef{ .name = name, .extension = "", .command = "" };
                var index: ?usize = null;
                for (manager.definitions.items, 0..) |item, i| if (std.mem.eql(u8, item.name, name)) {
                    def = item;
                    index = i;
                    break;
                };
                if (cfg.command) |cmd| {
                    def.command = cmd[0];
                    def.args = cmd[1..];
                }
                def.extensions = cfg.extensions;
                def.env = cfg.env;
                def.initialization = cfg.initialization;
                if (index) |i| manager.definitions.items[i] = def else try manager.definitions.append(alloc, def);
            }
        }
        return manager;
    }

    pub fn deinit(self: *Manager) void {
        for (self.clients.items) |*client| client.deinit(self.alloc);
        self.clients.deinit(self.alloc);
        self.alloc.free(self.root_uri);
        self.definitions.deinit(self.alloc);
        if (self.config) |cfg| cfg.deinit();
    }

    fn clientFor(self: *Manager, def: ServerDef) ?*Client {
        for (self.clients.items) |*client| if (std.mem.eql(u8, client.def.name, def.name)) return client;
        return null;
    }

    fn start(self: *Manager, def: ServerDef) !?*Client {
        if (self.clientFor(def)) |client| return client;
        if (self.unavailable[self.indexOf(def)]) return null;
        const command = def.command;
        const argv = try self.alloc.alloc([]const u8, def.args.len + 1);
        defer self.alloc.free(argv);
        argv[0] = command;
        @memcpy(argv[1..], def.args);
        var env_count: usize = 0;
        while (std.c.environ[env_count] != null) : (env_count += 1) {}
        var env = try std.process.Environ.createMap(.{ .block = .{ .slice = std.c.environ[0..env_count :null] } }, self.alloc);
        defer env.deinit();
        if (def.env) |extra| for (extra.map.keys(), extra.map.values()) |key, value| try env.put(key, value);
        sandbox.scrubEnv(&env);
        var child = std.process.spawn(sys.io, .{ .argv = argv, .environ_map = &env, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore, .pgid = 0 }) catch |err| switch (err) {
            error.FileNotFound => {
                self.unavailable[self.indexOf(def)] = true;
                return null;
            },
            else => return err,
        };
        const root_uri = self.alloc.dupe(u8, self.root_uri) catch |err| {
            child.kill(sys.io);
            return err;
        };
        var client = Client{ .def = def, .child = child, .root_uri = root_uri };
        errdefer client.deinit(self.alloc);
        try nonblock(client.child.stdin.?.handle);
        try nonblock(client.child.stdout.?.handle);
        const response = try client.request(self.alloc, "initialize", .{
            .processId = @as(?i64, null),
            .rootUri = client.root_uri,
            .initializationOptions = def.initialization,
            .workspaceFolders = .{.{ .uri = client.root_uri, .name = "workspace" }},
            .capabilities = .{ .textDocument = .{ .publishDiagnostics = .{ .versionSupport = true }, .diagnostic = .{ .dynamicRegistration = false } } },
        });
        defer response.deinit();
        if (response.value != .object or response.value.object.get("result") == null) return error.LspInitializeFailed;
        if (response.value.object.get("result")) |result| {
            if (result == .object) if (result.object.get("capabilities")) |caps| {
                if (caps == .object) if (caps.object.get("diagnosticProvider")) |provider| {
                    client.supports_pull = provider == .object or (provider == .bool and provider.bool);
                };
            };
        }
        try client.frame(self.alloc, .{ .jsonrpc = "2.0", .method = "initialized", .params = struct {}{} });

        try self.clients.append(self.alloc, client);
        return &self.clients.items[self.clients.items.len - 1];
    }

    pub fn touchFile(self: *Manager, path: []const u8) void {
        for (self.definitions.items) |def| {
            if (!supports(def, std.fs.path.extension(path))) continue;
            const client = self.start(def) catch {
                self.unavailable[self.indexOf(def)] = true;
                continue;
            } orelse continue;
            if (client.closed) continue;
            const uri = pathUriAlloc(self.alloc, path) catch continue;
            defer self.alloc.free(uri);
            const text = readFileAlloc(self.alloc, path) catch continue;
            defer self.alloc.free(text);
            if (client.diagnostics.fetchRemove(uri)) |old| {
                self.alloc.free(old.key);
                for (old.value) |d| self.alloc.free(d.message);
                self.alloc.free(old.value);
            }
            const version = if (client.documents.get(uri)) |v| v + 1 else 1;
            const method = if (client.documents.contains(uri)) "textDocument/didChange" else "textDocument/didOpen";
            if (std.mem.eql(u8, method, "textDocument/didOpen")) {
                client.frame(self.alloc, .{ .jsonrpc = "2.0", .method = method, .params = .{ .textDocument = .{ .uri = uri, .languageId = languageId(def, path), .version = version, .text = text } } }) catch {
                    client.close();
                    continue;
                };
            } else {
                client.frame(self.alloc, .{ .jsonrpc = "2.0", .method = method, .params = .{ .textDocument = .{ .uri = uri, .version = version }, .contentChanges = .{.{ .text = text }} } }) catch {
                    client.close();
                    continue;
                };
            }
            if (client.documents.contains(uri)) {
                client.documents.put(self.alloc, uri, version) catch continue;
            } else {
                const owned_uri = self.alloc.dupe(u8, uri) catch continue;
                client.documents.put(self.alloc, owned_uri, version) catch {
                    self.alloc.free(owned_uri);
                    continue;
                };
            }
            client.frame(self.alloc, .{ .jsonrpc = "2.0", .method = "textDocument/didSave", .params = .{ .textDocument = .{ .uri = uri }, .text = text } }) catch {
                client.close();
                continue;
            };
            const wait_until = std.Io.Clock.real.now(sys.io).toMilliseconds() + 700;
            while (std.Io.Clock.real.now(sys.io).toMilliseconds() < wait_until) {
                const parsed = client.receive(self.alloc, wait_until) catch break;
                client.handleMessage(self.alloc, parsed.value) catch {};
                const received = client.diagnostics.contains(uri);
                parsed.deinit();
                if (received) break;
            }
            if (client.supports_pull) {
                const report = client.request(self.alloc, "textDocument/diagnostic", .{ .textDocument = .{ .uri = uri } }) catch continue;
                defer report.deinit();
                if (report.value == .object) if (report.value.object.get("result")) |result| {
                    if (result == .object) if (result.object.get("items")) |items| client.storeDiagnosticList(self.alloc, uri, items) catch {};
                };
            }
        }
    }

    pub fn reportAlloc(self: *Manager) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        for (self.definitions.items, 0..) |def, i| {
            if (i > 0) try out.writer.writeByte('\n');
            const client = self.clientFor(def);
            const installed = commandAvailable(def.command);
            try out.writer.print("{s} — {s}", .{ def.name, if (client != null and client.?.closed) "failed" else if (client != null) "running" else if (self.unavailable[i] and installed) "failed to start" else if (self.unavailable[i]) "not installed" else if (installed) "installed; starts on matching file" else "not installed" });
        }
        return try self.alloc.dupe(u8, out.written());
    }

    pub fn summaryAlloc(self: *Manager) !?[]u8 {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        for (self.definitions.items) |def| {
            const client = self.clientFor(def);
            if (client == null and !commandAvailable(def.command)) continue;
            if (out.written().len > 0) try out.writer.writeAll(", ");
            try out.writer.print("{s} ({s})", .{ def.name, if (client) |c| if (c.closed) "failed" else "running" else if (self.unavailable[self.indexOf(def)]) "failed to start" else "installed" });
        }
        if (out.written().len == 0) return null;
        return try self.alloc.dupe(u8, out.written());
    }

    pub fn diagnosticsAlloc(self: *Manager, path: []const u8) !?[]u8 {
        const uri = try pathUriAlloc(self.alloc, path);
        defer self.alloc.free(uri);
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        var count: usize = 0;
        for (self.clients.items) |*client| {
            const list = client.diagnostics.get(uri) orelse continue;
            for (list) |d| {
                if (count == 30) break;
                try out.writer.print("{s}:{d}:{d}: {s}\n", .{ client.def.name, d.line, d.character, d.message });
                count += 1;
            }
        }
        if (count == 0) return null;
        return try self.alloc.dupe(u8, out.written());
    }

    pub fn queryAlloc(self: *Manager, args: Args) ![]u8 {
        if (args.line == 0 or args.character == 0) return error.InvalidLspPosition;
        // Read through the same path guard as the file tools before sending content to a server.
        const text = try readFileAlloc(self.alloc, args.filePath);
        self.alloc.free(text);
        self.touchFile(args.filePath);
        if (args.operation == .diagnostics) {
            var available = false;
            for (self.clients.items) |*client| if (!client.closed and supports(client.def, std.fs.path.extension(args.filePath))) {
                available = true;
                break;
            };
            if (!available) return error.LspUnavailable;
            return (try self.diagnosticsAlloc(args.filePath)) orelse try self.alloc.dupe(u8, "No diagnostics received.");
        }
        const uri = try pathUriAlloc(self.alloc, args.filePath);
        defer self.alloc.free(uri);
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        var available = false;
        for (self.clients.items) |*client| {
            if (client.closed or !supports(client.def, std.fs.path.extension(args.filePath))) continue;
            available = true;
            const params = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = args.line - 1, .character = args.character - 1 } };
            const response = switch (args.operation) {
                .goToDefinition => try client.request(self.alloc, "textDocument/definition", params),
                .findReferences => try client.request(self.alloc, "textDocument/references", .{ .textDocument = params.textDocument, .position = params.position, .context = .{ .includeDeclaration = true } }),
                .hover => try client.request(self.alloc, "textDocument/hover", params),
                .documentSymbol => try client.request(self.alloc, "textDocument/documentSymbol", .{ .textDocument = params.textDocument }),
                .workspaceSymbol => try client.request(self.alloc, "workspace/symbol", .{ .query = args.query }),
                .goToImplementation => try client.request(self.alloc, "textDocument/implementation", params),
                .prepareCallHierarchy, .incomingCalls, .outgoingCalls => try client.request(self.alloc, "textDocument/prepareCallHierarchy", params),
                .diagnostics => unreachable,
            };
            defer response.deinit();
            if (response.value != .object) return error.LspInvalidResponse;
            if (response.value.object.get("error") != null) return error.LspRequestFailed;
            var result = response.value.object.get("result") orelse return error.LspInvalidResponse;
            var calls: ?std.json.Parsed(std.json.Value) = null;
            defer if (calls) |c| c.deinit();
            if (args.operation == .incomingCalls or args.operation == .outgoingCalls) {
                if (result != .array or result.array.items.len == 0) continue;
                calls = try client.request(self.alloc, if (args.operation == .incomingCalls) "callHierarchy/incomingCalls" else "callHierarchy/outgoingCalls", .{ .item = result.array.items[0] });
                if (calls.?.value != .object or calls.?.value.object.get("error") != null) return error.LspRequestFailed;
                result = calls.?.value.object.get("result") orelse return error.LspInvalidResponse;
            }
            try out.writer.print("{s}:\n", .{client.def.name});
            const before = out.written().len;
            var remaining: usize = 40;
            try formatResult(&out.writer, result, args.filePath, self.root_uri, &remaining, 0);
            if (remaining == 0) try out.writer.writeAll("… result limit reached; narrow the query.\n");
            if (out.written().len == before) try out.writer.writeAll("No results.\n");
        }
        if (!available) return error.LspUnavailable;
        return try self.alloc.dupe(u8, out.written());
    }

    fn indexOf(self: *Manager, def: ServerDef) usize {
        for (self.definitions.items, 0..) |item, i| if (std.mem.eql(u8, item.name, def.name)) return i;
        unreachable;
    }
};

fn field(value: std.json.Value, name: []const u8) std.json.Value {
    return if (value == .object) value.object.get(name) orelse .null else .null;
}

fn formatLocation(writer: *std.Io.Writer, uri: std.json.Value, range: std.json.Value, path: []const u8, root_uri: []const u8) !void {
    var display = if (uri == .string) uri.string else path;
    if (std.mem.startsWith(u8, display, root_uri) and display.len > root_uri.len and display[root_uri.len] == '/') {
        display = display[root_uri.len + 1 ..];
    } else if (std.mem.startsWith(u8, display, "file://")) display = display[7..];
    try writer.writeAll(display);
    const start = field(range, "start");
    const line = field(start, "line");
    const character = field(start, "character");
    if (line == .integer and line.integer >= 0 and line.integer < std.math.maxInt(i64)) {
        try writer.print(":{d}", .{line.integer + 1});
        if (character == .integer and character.integer >= 0 and character.integer < std.math.maxInt(i64)) try writer.print(":{d}", .{character.integer + 1});
    }
}

fn formatResult(writer: *std.Io.Writer, value: std.json.Value, path: []const u8, root_uri: []const u8, remaining: *usize, depth: usize) anyerror!void {
    if (remaining.* == 0 or depth > 12) return;
    if (value == .array) {
        for (value.array.items) |item| {
            if (remaining.* == 0) break;
            try formatResult(writer, item, path, root_uri, remaining, depth);
        }
        return;
    }
    if (value == .string) {
        remaining.* -= 1;
        try writer.print("{s}\n", .{value.string});
        return;
    }
    if (value != .object) return;
    const contents = field(value, "contents");
    if (contents != .null) return formatResult(writer, contents, path, root_uri, remaining, depth + 1);
    const text = field(value, "value");
    if (text == .string) return formatResult(writer, text, path, root_uri, remaining, depth + 1);
    var target = field(value, "from");
    if (target == .null) target = field(value, "to");
    if (target != .null) return formatResult(writer, target, path, root_uri, remaining, depth + 1);
    const location = field(value, "location");
    const node = if (location == .object) location else value;
    var uri = field(node, "uri");
    if (uri == .null) uri = field(node, "targetUri");
    var range = field(node, "selectionRange");
    if (range == .null) range = field(node, "targetSelectionRange");
    if (range == .null) range = field(node, "range");
    const name = field(value, "name");
    if (name == .string or uri == .string or range == .object) {
        remaining.* -= 1;
        for (0..@min(depth, 6)) |_| try writer.writeAll("  ");
        try formatLocation(writer, uri, range, path, root_uri);
        if (name == .string) try writer.print(" {s}", .{name.string});
        const detail = field(value, "detail");
        if (detail == .string and detail.string.len > 0) try writer.print(" — {s}", .{detail.string});
        try writer.writeByte('\n');
    }
    const children = field(value, "children");
    if (children == .array) try formatResult(writer, children, path, root_uri, remaining, depth + 1);
}

fn supports(def: ServerDef, ext: []const u8) bool {
    if (def.extensions) |exts| {
        for (exts) |item| if (std.mem.eql(u8, item, ext)) return true;
        return false;
    }
    if (std.mem.eql(u8, def.extension, ".sh")) return extensionIn(ext, ".sh .bash .zsh .ksh");
    if (std.mem.eql(u8, def.extension, ".py")) return std.mem.eql(u8, ext, ".py") or std.mem.eql(u8, ext, ".pyi");
    if (std.mem.eql(u8, def.extension, ".zig")) return std.mem.eql(u8, ext, ".zig") or std.mem.eql(u8, ext, ".zon");
    if (std.mem.eql(u8, def.extension, ".c")) return extensionIn(ext, ".c .h .cc .cpp .cxx .hpp .hh .hxx");
    if (std.mem.eql(u8, def.extension, ".ts")) return extensionIn(ext, ".ts .tsx .js .jsx .mts .cts .mjs .cjs");
    if (std.mem.eql(u8, def.extension, ".yaml")) return std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml");
    return std.mem.eql(u8, ext, def.extension);
}

fn extensionIn(ext: []const u8, list: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |item| if (std.mem.eql(u8, item, ext)) return true;
    return false;
}

fn commandAvailable(command: []const u8) bool {
    if (std.mem.indexOfScalar(u8, command, '/') != null) {
        std.Io.Dir.cwd().access(sys.io, command, .{}) catch return false;
        return true;
    }
    var path: ?[]const u8 = null;
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const value = std.mem.span(entry);
        if (std.mem.startsWith(u8, value, "PATH=")) {
            path = value[5..];
            break;
        }
    }
    var dirs = std.mem.tokenizeScalar(u8, path orelse return false, ':');
    while (dirs.next()) |dir| {
        const candidate = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ dir, command }) catch return false;
        defer std.heap.page_allocator.free(candidate);
        std.Io.Dir.accessAbsolute(sys.io, candidate, .{}) catch continue;
        return true;
    }
    return false;
}

fn languageId(def: ServerDef, path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".cjs")) return "javascript";
    if (std.mem.eql(u8, ext, ".jsx")) return "javascriptreact";
    if (std.mem.eql(u8, ext, ".tsx")) return "typescriptreact";
    if (extensionIn(ext, ".cc .cpp .cxx .hpp .hh .hxx")) return "cpp";
    if (def.extension.len == 0) return if (ext.len > 1) ext[1..] else "plaintext";
    if (std.mem.eql(u8, def.extension, ".py")) return "python";
    if (std.mem.eql(u8, def.extension, ".zig")) return "zig";
    if (std.mem.eql(u8, def.extension, ".go")) return "go";
    if (std.mem.eql(u8, def.extension, ".rs")) return "rust";
    if (std.mem.eql(u8, def.extension, ".ts")) return "typescript";
    if (std.mem.eql(u8, def.extension, ".yaml")) return "yaml";
    if (std.mem.eql(u8, def.extension, ".json")) return "json";
    if (std.mem.eql(u8, def.extension, ".lua")) return "lua";
    if (std.mem.eql(u8, def.extension, ".nix")) return "nix";
    if (std.mem.eql(u8, def.extension, ".md")) return "markdown";
    if (std.mem.eql(u8, def.extension, ".toml")) return "toml";
    if (std.mem.eql(u8, def.extension, ".c")) return "c";
    return "shellscript";
}

fn pathUriAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const root = try std.Io.Dir.cwd().realPathFileAlloc(sys.io, ".", alloc);
    defer alloc.free(root);
    const abs = try std.fs.path.resolve(alloc, &.{ root, path });
    defer alloc.free(abs);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("file://");
    for (abs) |c| {
        if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/-._~:", c) != null) try out.writer.writeByte(c) else try out.writer.print("%{X:0>2}", .{c});
    }
    return try alloc.dupe(u8, out.written());
}

fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try path_guard.openFile(path, .{ .mode = .read_only });
    defer file.close(sys.io);
    var buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(sys.io, &buf);
    return reader.interface.allocRemaining(alloc, .limited(1024 * 1024));
}

fn nonblock(fd: std.posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (std.posix.errno(flags) != .SUCCESS) return error.LspIo;
    const bit: c_int = @bitCast(std.posix.O{ .NONBLOCK = true });
    if (std.posix.errno(std.c.fcntl(fd, std.posix.F.SETFL, flags | bit)) != .SUCCESS) return error.LspIo;
}
