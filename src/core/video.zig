//! Bounded MP4 contact-sheet extraction for vision-capable providers.
const builtin = @import("builtin");
const std = @import("std");
const sys = @import("pz_io");

const max_file_bytes = 100 * 1024 * 1024;
const max_duration_s = 300.0;
const max_image_bytes = 4 * 1024 * 1024;

pub fn contactSheetAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const stat = std.Io.Dir.cwd().statFile(sys.io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound => error.VideoNotFound,
        else => error.VideoUnreadable,
    };
    if (stat.kind != .file or stat.size == 0 or stat.size > max_file_bytes) return error.VideoTooLarge;

    const ffprobe = try resolveTool(alloc, "ffprobe");
    defer alloc.free(ffprobe);
    const probe = try std.process.run(alloc, sys.io, .{
        .argv = &.{ ffprobe, "-protocol_whitelist", "file,pipe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", path },
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(1024),
    });
    defer alloc.free(probe.stdout);
    defer alloc.free(probe.stderr);
    if (probe.term != .exited or probe.term.exited != 0) return error.InvalidVideo;
    const duration = try std.fmt.parseFloat(f64, std.mem.trim(u8, probe.stdout, " \t\r\n"));
    if (!std.math.isFinite(duration) or duration <= 0 or duration > max_duration_s) return error.VideoTooLong;

    const ffmpeg = try resolveTool(alloc, "ffmpeg");
    defer alloc.free(ffmpeg);
    const filter = try std.fmt.allocPrint(alloc, "fps={d:.8},scale=320:-2,tile=4x2", .{8.0 / duration});
    defer alloc.free(filter);
    const result = try std.process.run(alloc, sys.io, .{
        .argv = &.{ ffmpeg, "-protocol_whitelist", "file,pipe", "-threads", "1", "-v", "error", "-i", path, "-vf", filter, "-frames:v", "1", "-q:v", "5", "-f", "image2pipe", "-vcodec", "mjpeg", "pipe:1" },
        .stdout_limit = .limited(max_image_bytes),
        .stderr_limit = .limited(2048),
    });
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0 or result.stdout.len == 0) {
        alloc.free(result.stdout);
        return error.VideoDecodeFailed;
    }
    return result.stdout;
}

pub fn findPath(text: []const u8) ?[]const u8 {
    // shortcut: video paths must be whitespace-delimited; replace with a shell-style tokenizer if paths with spaces are needed.
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n\"'<>");
    while (words.next()) |word| {
        const path = std.mem.trimEnd(u8, word, ".,;:!?)]}");
        if (!std.fs.path.isAbsolute(path) or path.len < 5) continue;
        if (std.ascii.eqlIgnoreCase(path[path.len - 4 ..], ".mp4")) return path;
    }
    return null;
}

fn resolveTool(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
    const candidates = if (builtin.os.tag == .macos)
        [_][]const u8{ "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe" }
    else
        [_][]const u8{ "/usr/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffprobe", "/usr/local/bin/ffprobe" };
    for (candidates) |candidate| {
        if (!std.mem.endsWith(u8, candidate, name)) continue;
        std.Io.Dir.accessAbsolute(sys.io, candidate, .{}) catch continue;
        return try alloc.dupe(u8, candidate);
    }
    return error.VideoToolUnavailable;
}

test "findPath extracts only absolute MP4 paths" {
    try std.testing.expectEqualStrings("/home/user/clip.mp4", findPath("Review /home/user/clip.mp4, please").?);
    try std.testing.expect(findPath("/help") == null);
    try std.testing.expect(findPath("clip.mp4") == null);
}

test "contactSheetAlloc reports a missing video path" {
    try std.testing.expectError(error.VideoNotFound, contactSheetAlloc(std.testing.allocator, "/tmp/pz-no-such-video-4f6b8c.mp4"));
}
