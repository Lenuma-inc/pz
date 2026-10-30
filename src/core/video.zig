//! Bounded local video contact sheets and image conversion.
const builtin = @import("builtin");
const std = @import("std");
const sys = @import("pz_io");

const max_file_bytes = 100 * 1024 * 1024;
const max_duration_s = 300.0;
const max_image_bytes = 4 * 1024 * 1024;

pub fn mediaDuration(alloc: std.mem.Allocator, path: []const u8) !f64 {
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
    const seconds = try std.fmt.parseFloat(f64, std.mem.trim(u8, probe.stdout, " \t\r\n"));
    if (!std.math.isFinite(seconds) or seconds <= 0) return error.InvalidVideo;
    return seconds;
}

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

pub const ProcessResult = struct { data: ?[]u8, stderr: []u8 };

pub fn processAlloc(alloc: std.mem.Allocator, op: []const u8, input: []const u8, start: f64, duration: ?f64, accurate: bool, image_format: []const u8, aspect: []const u8, fit_mode: []const u8, preset: []const u8, audio_format: []const u8) !ProcessResult {
    if (std.mem.eql(u8, op, "inspect")) {
        const ffprobe = try resolveTool(alloc, "ffprobe");
        defer alloc.free(ffprobe);
        const probe = try std.process.run(alloc, sys.io, .{
            .argv = &.{ ffprobe, "-protocol_whitelist", "file,pipe", "-v", "error", "-show_format", "-show_streams", "-of", "json", input },
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(2048),
        });
        if (probe.term != .exited or probe.term.exited != 0) {
            alloc.free(probe.stdout);
            return .{ .data = null, .stderr = probe.stderr };
        }
        return .{ .data = probe.stdout, .stderr = probe.stderr };
    }
    const ffmpeg = try resolveTool(alloc, "ffmpeg");
    defer alloc.free(ffmpeg);

    var argv: [64][]const u8 = undefined;
    var len: usize = 0;
    var start_buf: [32]u8 = undefined;
    var duration_buf: [32]u8 = undefined;
    var filter_buf: ?[]u8 = null;
    defer if (filter_buf) |filter| alloc.free(filter);
    argv[len] = ffmpeg; len += 1;
    argv[len] = "-nostdin"; len += 1;
    argv[len] = "-protocol_whitelist"; len += 1;
    argv[len] = "file,pipe"; len += 1;
    argv[len] = "-threads"; len += 1;
    argv[len] = "1"; len += 1;
    argv[len] = "-v"; len += 1;
    argv[len] = "error"; len += 1;
    if (start > 0) {
        argv[len] = "-ss"; len += 1;
        argv[len] = try std.fmt.bufPrint(&start_buf, "{d:.3}", .{start});
    }
    argv[len] = "-i"; len += 1;
    argv[len] = input; len += 1;
    if (duration) |seconds| {
        argv[len] = "-t"; len += 1;
        argv[len] = try std.fmt.bufPrint(&duration_buf, "{d:.3}", .{seconds});
    }
    argv[len] = "-y"; len += 1;
    if (std.mem.eql(u8, op, "thumbnail")) {
        argv[len] = "-map"; len += 1; argv[len] = "0:v:0"; len += 1;
        argv[len] = "-frames:v"; len += 1; argv[len] = "1"; len += 1;
        argv[len] = "-vf"; len += 1; argv[len] = "scale=1920:1920:force_original_aspect_ratio=decrease"; len += 1;
        argv[len] = "-f"; len += 1; argv[len] = "image2pipe"; len += 1;
        argv[len] = "-vcodec"; len += 1;
        argv[len] = if (std.mem.eql(u8, image_format, "png")) "png" else "mjpeg";
        len += 1;
        if (!std.mem.eql(u8, image_format, "png")) {
            argv[len] = "-q:v"; len += 1; argv[len] = "3"; len += 1;
        }
    } else if (std.mem.eql(u8, op, "trim")) {
        argv[len] = "-map"; len += 1; argv[len] = "0:v:0?"; len += 1;
        argv[len] = "-map"; len += 1; argv[len] = "0:a:0?"; len += 1;
        if (accurate) {
            argv[len] = "-c:v"; len += 1; argv[len] = "libx264"; len += 1;
            argv[len] = "-c:a"; len += 1; argv[len] = "aac"; len += 1;
        } else {
            argv[len] = "-c"; len += 1; argv[len] = "copy"; len += 1;
        }
        argv[len] = "-movflags"; len += 1; argv[len] = "+frag_keyframe+empty_moov"; len += 1;
        argv[len] = "-f"; len += 1; argv[len] = "mp4"; len += 1;
    } else if (std.mem.eql(u8, op, "fit")) {
        const dims: [2]u32 = if (std.mem.eql(u8, aspect, "landscape")) .{ 1920, 1080 } else if (std.mem.eql(u8, aspect, "portrait")) .{ 1080, 1920 } else if (std.mem.eql(u8, aspect, "square")) .{ 1080, 1080 } else return error.InvalidVideoOperation;
        filter_buf = if (std.mem.eql(u8, fit_mode, "crop"))
            try std.fmt.allocPrint(alloc, "scale={d}:{d}:force_original_aspect_ratio=increase,crop={d}:{d},setsar=1", .{ dims[0], dims[1], dims[0], dims[1] })
        else
            try std.fmt.allocPrint(alloc, "scale={d}:{d}:force_original_aspect_ratio=decrease,pad={d}:{d}:(ow-iw)/2:(oh-ih)/2:black,setsar=1", .{ dims[0], dims[1], dims[0], dims[1] });
        argv[len] = "-map"; len += 1; argv[len] = "0:v:0"; len += 1;
        argv[len] = "-map"; len += 1; argv[len] = "0:a:0?"; len += 1;
        argv[len] = "-vf"; len += 1; argv[len] = filter_buf.?; len += 1;
        argv[len] = "-c:v"; len += 1; argv[len] = "libx264"; len += 1;
        argv[len] = "-preset"; len += 1; argv[len] = "medium"; len += 1;
        argv[len] = "-crf"; len += 1; argv[len] = "22"; len += 1;
        argv[len] = "-pix_fmt"; len += 1; argv[len] = "yuv420p"; len += 1;
        argv[len] = "-c:a"; len += 1; argv[len] = "aac"; len += 1;
        argv[len] = "-movflags"; len += 1; argv[len] = "+frag_keyframe+empty_moov"; len += 1;
        argv[len] = "-f"; len += 1; argv[len] = "mp4"; len += 1;
    } else if (std.mem.eql(u8, op, "convert")) {
        argv[len] = "-map"; len += 1; argv[len] = "0:v:0?"; len += 1;
        argv[len] = "-map"; len += 1; argv[len] = "0:a:0?"; len += 1;
        if (std.mem.eql(u8, preset, "h264")) {
            argv[len] = "-c:v"; len += 1; argv[len] = "libx264"; len += 1;
            argv[len] = "-crf"; len += 1; argv[len] = "22"; len += 1;
            argv[len] = "-c:a"; len += 1; argv[len] = "aac"; len += 1;
            argv[len] = "-f"; len += 1; argv[len] = "mp4"; len += 1;
        } else if (std.mem.eql(u8, preset, "hevc")) {
            argv[len] = "-c:v"; len += 1; argv[len] = "libx265"; len += 1;
            argv[len] = "-crf"; len += 1; argv[len] = "27"; len += 1;
            argv[len] = "-c:a"; len += 1; argv[len] = "aac"; len += 1;
            argv[len] = "-f"; len += 1; argv[len] = "mp4"; len += 1;
        } else if (std.mem.eql(u8, preset, "prores")) {
            argv[len] = "-c:v"; len += 1; argv[len] = "prores_ks"; len += 1;
            argv[len] = "-profile:v"; len += 1; argv[len] = "3"; len += 1;
            argv[len] = "-c:a"; len += 1; argv[len] = "pcm_s16le"; len += 1;
            argv[len] = "-f"; len += 1; argv[len] = "mov"; len += 1;
        } else if (std.mem.eql(u8, preset, "webm")) {
            argv[len] = "-c:v"; len += 1; argv[len] = "libvpx-vp9"; len += 1;
            argv[len] = "-crf"; len += 1; argv[len] = "32"; len += 1;
            argv[len] = "-b:v"; len += 1; argv[len] = "0"; len += 1;
            argv[len] = "-c:a"; len += 1; argv[len] = "libopus"; len += 1;
            argv[len] = "-f"; len += 1; argv[len] = "webm"; len += 1;
        } else return error.InvalidVideoOperation;
        if (!std.mem.eql(u8, preset, "webm")) {
            argv[len] = "-movflags"; len += 1; argv[len] = "+frag_keyframe+empty_moov"; len += 1;
        }
    } else if (std.mem.eql(u8, op, "gif")) {
        argv[len] = "-filter_complex"; len += 1; argv[len] = "[0:v]fps=12,scale=640:-1:flags=lanczos,split[v][p0];[p0]palettegen=stats_mode=diff[p];[v][p]paletteuse=dither=sierra2_4a[out]"; len += 1;
        argv[len] = "-map"; len += 1; argv[len] = "[out]"; len += 1;
        argv[len] = "-loop"; len += 1; argv[len] = "0"; len += 1;
        argv[len] = "-f"; len += 1; argv[len] = "gif"; len += 1;
    } else if (std.mem.eql(u8, op, "audio")) {
        argv[len] = "-map"; len += 1; argv[len] = "0:a:0"; len += 1;
        argv[len] = "-vn"; len += 1;
        if (std.mem.eql(u8, audio_format, "mp3")) {
            argv[len] = "-codec:a"; len += 1; argv[len] = "libmp3lame"; len += 1;
            argv[len] = "-f"; len += 1; argv[len] = "mp3"; len += 1;
        } else if (std.mem.eql(u8, audio_format, "wav")) {
            argv[len] = "-codec:a"; len += 1; argv[len] = "pcm_s16le"; len += 1;
            argv[len] = "-f"; len += 1; argv[len] = "wav"; len += 1;
        } else if (std.mem.eql(u8, audio_format, "flac")) {
            argv[len] = "-codec:a"; len += 1; argv[len] = "flac"; len += 1;
            argv[len] = "-f"; len += 1; argv[len] = "flac"; len += 1;
        } else return error.InvalidVideoOperation;
    } else return error.InvalidVideoOperation;
    argv[len] = "pipe:1"; len += 1;
    const result = try std.process.run(alloc, sys.io, .{
        .argv = argv[0..len],
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(2048),
    });
    if (result.term != .exited or result.term.exited != 0 or result.stdout.len == 0) {
        alloc.free(result.stdout);
        return .{ .data = null, .stderr = result.stderr };
    }
    return .{ .data = result.stdout, .stderr = result.stderr };
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
