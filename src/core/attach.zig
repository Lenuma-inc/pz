//! Local prompt attachments. Conversion is explicit; binary data never becomes prompt text.
const std = @import("std");
const sys = @import("pz_io");
const video = @import("video.zig");
const api = @import("providers/api.zig");

pub const max_bytes = 4 * 1024 * 1024;
pub const max_files = 8;
const max_source_bytes = 100 * 1024 * 1024;

pub const Loaded = struct {
    part: api.Part,
    note: []const u8,
};

pub const Paths = struct {
    text: []const u8,
    pos: usize = 0,
    buf: [std.fs.max_path_bytes]u8 = undefined,

    pub fn next(self: *Paths) !?[]const u8 {
        while (self.pos < self.text.len) {
            while (self.pos < self.text.len and std.ascii.isWhitespace(self.text[self.pos])) self.pos += 1;
            if (self.pos == self.text.len) return null;
            var len: usize = 0;
            var quote: ?u8 = null;
            var literal = false;
            while (self.pos < self.text.len) {
                var c = self.text[self.pos];
                if (quote == null and std.ascii.isWhitespace(c)) break;
                self.pos += 1;
                if (quote != null and c == quote.?) {
                    quote = null;
                    continue;
                }
                if (quote == null and (c == '"' or c == '\'') and len == 0) {
                    quote = c;
                    literal = true;
                    continue;
                }
                if (c == '\\' and quote != '\'' and self.pos < self.text.len) {
                    c = self.text[self.pos];
                    self.pos += 1;
                    literal = true;
                }
                if (len == self.buf.len) return error.AttachmentPathTooLong;
                self.buf[len] = c;
                len += 1;
            }
            var path: []const u8 = self.buf[0..len];
            if (!literal) path = std.mem.trimEnd(u8, path, ",;:!?)]}");
            const uri = std.mem.startsWith(u8, path, "file:///");
            const explicit = uri or std.fs.path.isAbsolute(path) or std.mem.startsWith(u8, path, "./") or
                std.mem.startsWith(u8, path, "../") or std.mem.startsWith(u8, path, "~/") or std.mem.startsWith(u8, path, "@");
            if (!explicit) {
                if (std.fs.path.extension(path).len == 0) continue;
                const st = std.Io.Dir.cwd().statFile(sys.io, path, .{}) catch continue;
                if (st.kind != .file) continue;
            }
            if (quote != null) return error.UnclosedAttachmentQuote;
            if (uri) {
                path = path[7..];
                var out: usize = 0;
                var i: usize = 0;
                while (i < path.len) : (i += 1) {
                    var c = path[i];
                    if (c == '%') {
                        if (i + 2 >= path.len) return error.InvalidAttachmentPath;
                        c = std.fmt.parseInt(u8, path[i + 1 ..][0..2], 16) catch return error.InvalidAttachmentPath;
                        i += 2;
                    }
                    if (c == 0) return error.InvalidAttachmentPath;
                    self.buf[out] = c;
                    out += 1;
                }
                path = self.buf[0..out];
            } else if (std.mem.startsWith(u8, path, "@")) {
                path = path[1..];
            }
            if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidAttachmentPath;
            if (!uri and !std.mem.startsWith(u8, self.buf[0..len], "@")) {
                if (std.Io.Dir.cwd().statFile(sys.io, path, .{})) |st| {
                    if (st.kind == .directory) continue;
                } else |_| {
                    // Missing file references are validated by readAlloc.
                }
            }
            // A bare slash command is not a file reference.
            if (path[0] == '/' and std.mem.indexOfScalar(u8, path[1..], '/') == null and std.fs.path.extension(path).len == 0) continue;
            return path;
        }
        return null;
    }
};

pub fn isPrompt(text: []const u8) bool {
    var paths = Paths{ .text = text };
    return (paths.next() catch return true) != null;
}

pub fn readAlloc(alloc: std.mem.Allocator, input: []const u8) !Loaded {
    const expanded = if (std.mem.startsWith(u8, input, "~/")) blk: {
        var env = try sys.environ().createMap(alloc);
        defer env.deinit();
        const home = env.get("HOME") orelse return error.AttachmentHomeUnavailable;
        break :blk try std.fs.path.join(alloc, &.{ home, input[2..] });
    } else try alloc.dupe(u8, input);
    defer alloc.free(expanded);
    const path = try std.Io.Dir.cwd().realPathFileAlloc(sys.io, expanded, alloc);
    defer alloc.free(path);
    const st = try std.Io.Dir.cwd().statFile(sys.io, path, .{});
    if (st.kind != .file) return error.AttachmentNotRegular;
    if (st.size > max_source_bytes) return error.AttachmentTooLarge;

    var file = try std.Io.Dir.cwd().openFile(sys.io, path, .{});
    defer file.close(sys.io);
    var head: [32]u8 = undefined;
    const n = try file.readStreaming(sys.io, &.{&head});
    const bytes = head[0..n];
    if (imageMime(bytes)) |mime| {
        if (st.size > max_bytes) return error.AttachmentTooLarge;
        const data = try std.Io.Dir.cwd().readFileAlloc(sys.io, path, alloc, .limited(max_bytes));
        return .{ .part = .{ .image = .{ .media_type = mime, .data = data } }, .note = "image (GIF: first frame only)" };
    }
    if (std.mem.startsWith(u8, bytes, "%PDF-")) {
        const data = runAlloc(alloc, &.{ "pdftotext", "-enc", "UTF-8", "-layout", path, "-" }) catch |err| return switch (err) {
            error.FileNotFound => error.PdfToolUnavailable,
            else => err,
        };
        errdefer alloc.free(data);
        if (std.mem.trim(u8, data, " \t\r\n\x0c").len == 0) return error.PdfNeedsOcr;
        try validateText(data);
        return .{ .part = .{ .text = data }, .note = "PDF extracted text only; page images and charts are not included" };
    }
    if (std.mem.startsWith(u8, bytes, "PK\x03\x04") or std.mem.startsWith(u8, bytes, "PK\x05\x06")) {
        const data = runAlloc(alloc, &.{ "python3", "-I", "-c", @embedFile("file_text.py"), path }) catch |err| return switch (err) {
            error.FileNotFound => error.DocumentToolUnavailable,
            else => err,
        };
        return .{ .part = .{ .text = data }, .note = "document text or ZIP directory; embedded images and macros are not executed" };
    }
    if (video.isPath(path)) {
        const image = try video.contactSheetAlloc(alloc, path);
        return .{ .part = .{ .image = .{ .media_type = "image/jpeg", .data = image } }, .note = "video: 8 chronological frames, left to right then top to bottom; audio is not transcribed" };
    }
    if (hasExt(path, &.{ ".mp3", ".wav", ".flac", ".ogg", ".opus", ".aac", ".m4a", ".aiff", ".wma" })) {
        const data = try runAlloc(alloc, &.{ "ffprobe", "-protocol_whitelist", "file,pipe", "-v", "error", "-show_format", "-show_streams", "-of", "json", path });
        return .{ .part = .{ .text = data }, .note = "audio metadata only; speech/music content is NOT transcribed or heard" };
    }
    if (hasExt(path, &.{ ".bmp", ".tif", ".tiff", ".avif", ".heic", ".heif" })) {
        const data = try video.imageAlloc(alloc, path);
        return .{ .part = .{ .image = .{ .media_type = "image/jpeg", .data = data } }, .note = "image converted to JPEG; first frame/page only" };
    }
    if (st.size > max_bytes) return error.AttachmentTooLarge;
    const data = try std.Io.Dir.cwd().readFileAlloc(sys.io, path, alloc, .limited(max_bytes));
    errdefer alloc.free(data);
    try validateText(data);
    return .{ .part = .{ .text = data }, .note = "UTF-8 text" };
}

fn validateText(data: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(data)) return error.AttachmentNotUtf8;
    for (data) |c| {
        if (c < 0x20 and c != '\n' and c != '\r' and c != '\t' and c != 0x0c) return error.UnsupportedBinaryAttachment;
    }
}

fn imageMime(bytes: []const u8) ?[]const u8 {
    const formats = .{
        .{ "\x89PNG\r\n\x1a\n", "image/png" },
        .{ "\xff\xd8\xff", "image/jpeg" },
        .{ "GIF87a", "image/gif" },
        .{ "GIF89a", "image/gif" },
    };
    inline for (formats) |format| {
        if (std.mem.startsWith(u8, bytes, format[0])) return format[1];
    }
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    return null;
}

pub fn isImage(bytes: []const u8, mime: []const u8) bool {
    return std.mem.eql(u8, imageMime(bytes) orelse return false, mime);
}

fn hasExt(path: []const u8, exts: []const []const u8) bool {
    for (exts) |ext| {
        if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ext)) return true;
    }
    return false;
}

fn runAlloc(alloc: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(alloc, sys.io, .{
        .argv = argv,
        .stdout_limit = .limited(max_bytes),
        .stderr_limit = .limited(2048),
    });
    defer alloc.free(result.stderr);
    errdefer alloc.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0) return error.AttachmentConversionFailed;
    return result.stdout;
}

test "attachment paths handle quoted, escaped, URI and multiple files" {
    var paths = Paths{ .text = "Read '/tmp/a b.txt' /tmp/c\\ d.png file:///tmp/e%20f.pdf ./local.csv" };
    try std.testing.expectEqualStrings("/tmp/a b.txt", (try paths.next()).?);
    try std.testing.expectEqualStrings("/tmp/c d.png", (try paths.next()).?);
    try std.testing.expectEqualStrings("/tmp/e f.pdf", (try paths.next()).?);
    try std.testing.expectEqualStrings("./local.csv", (try paths.next()).?);
    try std.testing.expect(try paths.next() == null);
    try std.testing.expect(!isPrompt("/help"));
    try std.testing.expect(!isPrompt("/skill argument"));
    var invalid = Paths{ .text = "file:///tmp/x%00.png" };
    try std.testing.expectError(error.InvalidAttachmentPath, invalid.next());
}

test "attachment paths skip directory context and preserve explicit directory attachments" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(root);
    var paths = Paths{ .text = root };
    try std.testing.expect(try paths.next() == null);
    for ([_][]const u8{ "@", "file://" }) |prefix| {
        const text = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, root });
        defer alloc.free(text);
        paths = .{ .text = text };
        try std.testing.expectEqualStrings(root, (try paths.next()).?);
        try std.testing.expectError(error.AttachmentNotRegular, readAlloc(alloc, root));
    }
}

test "attachment content sniffing rejects renamed binaries and accepts text without extension" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(root);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data = "all:\n\techo ok\n" });
    const path = try std.fs.path.join(alloc, &.{ root, "Makefile" });
    defer alloc.free(path);
    const loaded = try readAlloc(alloc, path);
    defer alloc.free(loaded.part.text);
    try std.testing.expectEqualStrings("all:\n\techo ok\n", loaded.part.text);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data = "binary\x00payload" });
    try std.testing.expectError(error.UnsupportedBinaryAttachment, readAlloc(alloc, path));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Makefile", .data = "\x89PNG\r\n\x1a\npixels" });
    const image = try readAlloc(alloc, path);
    defer alloc.free(image.part.image.data);
    try std.testing.expectEqualStrings("image/png", image.part.image.media_type);
    try std.testing.expectError(error.AttachmentNotRegular, readAlloc(alloc, root));
}
