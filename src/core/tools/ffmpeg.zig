//! Bounded, fixed-operation video processing tool.
const std = @import("std");
const sys = @import("pz_io");
const tools = @import("../tools.zig");
const video = @import("../video.zig");
const path_guard = @import("path_guard.zig");
const shared = @import("shared.zig");

pub fn run(alloc: std.mem.Allocator, max_bytes: usize, call: tools.Call) !tools.Result {
    if (call.kind != .ffmpeg or std.meta.activeTag(call.args) != .ffmpeg) return error.KindMismatch;
    const args = call.args.ffmpeg;
    if (args.input.len == 0 or !video.isPath(args.input) or !std.math.isFinite(args.start_seconds) or args.start_seconds < 0 or args.start_seconds > 300) return error.InvalidArgs;
    const inspecting = args.op == .inspect;
    if (inspecting != (args.output == null)) return error.InvalidArgs;
    if (args.duration_seconds) |seconds| {
        if (!std.math.isFinite(seconds) or seconds <= 0 or seconds > 300) return error.InvalidArgs;
    }
    if ((args.op == .trim or args.op == .gif or args.op == .audio) and args.duration_seconds == null) return error.InvalidArgs;
    if (args.op == .fit and args.aspect == .original) return error.InvalidArgs;
    if (args.accurate and args.op != .trim) return error.InvalidArgs;
    if (!std.math.isFinite(args.speed) or args.speed < 0.5 or args.speed > 2) return error.InvalidArgs;
    if (args.op != .speed and args.speed != 1) return error.InvalidArgs;
    if (args.op != .transform and args.transform != .clockwise) return error.InvalidArgs;
    if (args.output) |output| {
        if (output.len == 0 or std.mem.eql(u8, output, args.input)) return error.InvalidArgs;
        const ext = std.fs.path.extension(output);
        const valid_ext = switch (args.op) {
            .inspect => false,
            .thumbnail => std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg") or std.ascii.eqlIgnoreCase(ext, ".png"),
            .trim => std.ascii.eqlIgnoreCase(ext, ".mp4"),
            .fit, .transform, .speed, .mute => std.ascii.eqlIgnoreCase(ext, ".mp4"),
            .convert => switch (args.preset) {
                .h264, .hevc => std.ascii.eqlIgnoreCase(ext, ".mp4"),
                .prores => std.ascii.eqlIgnoreCase(ext, ".mov"),
                .webm => std.ascii.eqlIgnoreCase(ext, ".webm"),
            },
            .gif => std.ascii.eqlIgnoreCase(ext, ".gif"),
            .audio => switch (args.audio_format) {
                .mp3 => std.ascii.eqlIgnoreCase(ext, ".mp3"),
                .wav => std.ascii.eqlIgnoreCase(ext, ".wav"),
                .flac => std.ascii.eqlIgnoreCase(ext, ".flac"),
            },
        };
        if (!valid_ext) return error.InvalidArgs;
    }

    var input_file = try path_guard.openFile(args.input, .{ .mode = .read_only });
    defer input_file.close(sys.io);
    const stat = try input_file.stat(sys.io);
    if (stat.kind != .file or stat.size == 0 or stat.size > 100 * 1024 * 1024) return error.VideoTooLarge;

    const image_format = if (args.output) |output| if (std.ascii.eqlIgnoreCase(std.fs.path.extension(output), ".png")) "png" else "jpg" else "jpg";
    if (args.op != .inspect) {
        const seconds = try video.mediaDuration(alloc, args.input);
        if (seconds > 300 or args.start_seconds >= seconds) return error.VideoTooLong;
        const rate = if (args.op == .speed) args.speed else 1;
        if (args.duration_seconds) |duration| {
            if (args.start_seconds + duration * rate > seconds + 0.05) return error.InvalidArgs;
        } else if ((seconds - args.start_seconds) / rate > 300) return error.VideoTooLong;
    }
    const processed = try video.processAlloc(alloc, @tagName(args.op), args.input, args.start_seconds, args.duration_seconds, args.accurate, image_format, @tagName(args.aspect), @tagName(args.fit_mode), @tagName(args.preset), @tagName(args.audio_format), @tagName(args.transform), args.speed);
    defer alloc.free(processed.stderr);
    const data = processed.data orelse {
        const stderr = std.mem.trim(u8, processed.stderr, " \t\r\n");
        const detail = try std.fmt.allocPrint(alloc, "{s} failed: {s}", .{ if (args.op == .inspect) "ffprobe" else "ffmpeg", if (stderr.len == 0) "process returned no output" else stderr });
        return failedResult(alloc, max_bytes, call, detail);
    };
    if (args.output) |output| {
        defer alloc.free(data);
        var file = try path_guard.createFile(output, .{ .exclusive = true });
        defer file.close(sys.io);
        try file.writeStreamingAll(sys.io, data);
        const verified = try video.processAlloc(alloc, "inspect", output, 0, null, false, "jpg", "original", "contain", "h264", "mp3", "clockwise", 1);
        defer alloc.free(verified.stderr);
        const metadata = verified.data orelse {
            const stderr = std.mem.trim(u8, verified.stderr, " \t\r\n");
            const detail = try std.fmt.allocPrint(alloc, "Created {s}, but ffprobe could not verify it: {s}", .{ output, if (stderr.len == 0) "no metadata returned" else stderr });
            return failedResult(alloc, max_bytes, call, detail);
        };
        defer alloc.free(metadata);
        const detail = try std.fmt.allocPrint(alloc, "Created and ffprobe-verified {s} ({d} bytes). Media metadata:\n{s}", .{ output, data.len, metadata });
        return try shared.buildResult(alloc, call.id, call.at_ms, detail, max_bytes, detail.len);
    }
    return try shared.buildResult(alloc, call.id, call.at_ms, data, max_bytes, data.len);
}

fn failedResult(alloc: std.mem.Allocator, max_bytes: usize, call: tools.Call, detail: []u8) !tools.Result {
    errdefer alloc.free(detail);
    var result = try shared.buildResult(alloc, call.id, call.at_ms, detail, max_bytes, detail.len);
    result.final = .{ .failed = .{ .kind = .exec, .msg = detail } };
    return result;
}
