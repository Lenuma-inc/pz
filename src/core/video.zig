//! Bounded local video contact sheets and image conversion.
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
    // Pad short clips so every sheet has eight cells; constrain portrait and landscape frames alike.
    const filter = try std.fmt.allocPrint(alloc, "fps={d:.8}:round=up,scale=480:360:force_original_aspect_ratio=decrease,pad=480:360:(ow-iw)/2:(oh-ih)/2,tpad=stop_mode=clone:stop=8,tile=4x2", .{8.0 / duration});
    defer alloc.free(filter);
    const result = try std.process.run(alloc, sys.io, .{
        .argv = &.{ ffmpeg, "-nostdin", "-protocol_whitelist", "file,pipe", "-threads", "1", "-v", "error", "-i", path, "-map", "0:v:0", "-an", "-sn", "-vf", filter, "-frames:v", "1", "-q:v", "4", "-f", "image2pipe", "-vcodec", "mjpeg", "pipe:1" },
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

pub fn isPath(path: []const u8) bool {
    const exts = [_][]const u8{ ".mp4", ".mov", ".mkv", ".webm", ".avi", ".m4v", ".mpg", ".mpeg", ".3gp", ".mts", ".m2ts", ".flv", ".wmv" };
    for (exts) |ext| {
        if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ext)) return true;
    }
    return false;
}

pub fn imageAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const ffmpeg = try resolveTool(alloc, "ffmpeg");
    defer alloc.free(ffmpeg);
    const result = try std.process.run(alloc, sys.io, .{
        .argv = &.{ ffmpeg, "-nostdin", "-protocol_whitelist", "file,pipe", "-threads", "1", "-v", "error", "-i", path, "-vf", "scale=1920:1920:force_original_aspect_ratio=decrease", "-frames:v", "1", "-q:v", "3", "-f", "image2pipe", "-vcodec", "mjpeg", "pipe:1" },
        .stdout_limit = .limited(max_image_bytes),
        .stderr_limit = .limited(2048),
    });
    defer alloc.free(result.stderr);
    errdefer alloc.free(result.stdout);
    if (result.term != .exited or result.term.exited != 0 or result.stdout.len == 0) return error.ImageDecodeFailed;
    return result.stdout;
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

test "contactSheetAlloc reports a missing video path" {
    try std.testing.expectError(error.VideoNotFound, contactSheetAlloc(std.testing.allocator, "/tmp/pz-no-such-video-4f6b8c.mp4"));
}
