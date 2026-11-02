//! Offline extraction affects web output only; shared HTTP consumers keep raw bytes.
const std = @import("std");
const sys = @import("pz_io");
const web = @import("web.zig");

pub fn extractAlloc(alloc: std.mem.Allocator, body: []const u8, req: web.Request) ![]u8 {
    if (req.format == .raw) {
        if (req.json_path != null or req.pattern != null) return error.InvalidArgs;
        return alloc.dupe(u8, body);
    }
    var child = std.process.spawn(sys.io, .{ .argv = &.{ "python3", "-I", "-c", @embedFile("web_text.py"), @tagName(req.format), req.json_path orelse "", req.url, req.pattern orelse "" }, .expand_arg0 = .expand, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore }) catch |err| switch (err) {
        error.FileNotFound => return error.WebTextRequiresPython3,
        else => return err,
    };
    defer child.kill(sys.io);
    try child.stdin.?.writeStreamingAll(sys.io, body);
    child.stdin.?.close(sys.io);
    child.stdin = null;
    var buf: std.Io.File.MultiReader.Buffer(1) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(alloc, sys.io, buf.toStreams(), &.{child.stdout.?});
    defer reader.deinit();
    while (reader.fill(1024, .none)) |_| {
        if (reader.reader(0).buffered().len > 8 * 1024 * 1024) return error.TooLarge;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    switch (try child.wait(sys.io)) {
        .exited => |code| if (code != 0) return error.WebTextExtractionFailed,
        else => return error.WebTextExtractionFailed,
    }
    return reader.toOwnedSlice(0);
}

test "web text extracts article HTML from JSON and supports raw and JSON paths" {
    const a = std.testing.allocator;
    const body = "{\"titleHtml\":\"Title\",\"textHtml\":\"<p>Hello &amp; world</p>\",\"metadata\":123}";
    const extracted = try extractAlloc(a, body, .{ .url = "https://example.org" });
    defer a.free(extracted);
    try std.testing.expect(std.mem.indexOf(u8, extracted, "Hello & world") != null);
    try std.testing.expect(std.mem.indexOf(u8, extracted, "metadata omitted") != null);
    const selected = try extractAlloc(a, body, .{ .url = "https://example.org", .json_path = "textHtml" });
    defer a.free(selected);
    try std.testing.expectEqualStrings("Hello & world", selected);
    const raw = try extractAlloc(a, body, .{ .url = "https://example.org", .format = .raw });
    defer a.free(raw);
    try std.testing.expectEqualStrings(body, raw);
    try std.testing.expectError(error.WebTextExtractionFailed, extractAlloc(a, body, .{ .url = "https://example.org", .json_path = "absent" }));
}

test "web text removes HTML noise while retaining article links and code" {
    const a = std.testing.allocator;
    const html = "<!doctype html><html><nav>Menu</nav><script>bad()</script><main><h1>Статья</h1><p>A &amp; B <a href='/source'>source</a></p><pre>  x = 1\n  y = 2</pre><style>bad css</style></main><footer>Ads</footer></html>";
    const text = try extractAlloc(a, html, .{ .url = "https://example.org" });
    defer a.free(text);
    try std.testing.expectEqualStrings("# Статья\nA & B [source](https://example.org/source)\n```\n  x = 1\n  y = 2\n```", text);
    const selected = try extractAlloc(a, "{\"items\":[{\"body\":\"<p>Selected</p>\"}]}", .{ .url = "https://example.org", .json_path = "items.0.body" });
    defer a.free(selected);
    try std.testing.expectEqualStrings("Selected", selected);
    const json = try extractAlloc(a, "[ {\"textHtml\":\"<p>First</p>\"}, {\"textHtml\":\"<p>Second</p>\"} ]", .{ .url = "https://example.org" });
    defer a.free(json);
    try std.testing.expectEqualStrings("[{\"textHtml\":\"<p>First</p>\"},{\"textHtml\":\"<p>Second</p>\"}]", json);
    const plain = try extractAlloc(a, "plain text\nsecond line", .{ .url = "https://example.org" });
    defer a.free(plain);
    try std.testing.expectEqualStrings("plain text\nsecond line", plain);
}

test "web text preserves home news instead of sidebar article cards" {
    const a = std.testing.allocator;
    const body = "<nav>Navigation</nav><div id='content'><h1>Latest News</h1><div><h2><a href='/news'>New release</a></h2><p>News summary</p><a href='/image'><img src='x'></a></div><aside><article>Sidebar card</article></aside></div><article>Featured card</article>";
    const text = try extractAlloc(a, body, .{ .url = "https://example.org" });
    defer a.free(text);
    try std.testing.expectEqualStrings("# Latest News\n## [New release](https://example.org/news)\nNews summary", text);
    const main = try extractAlloc(a, "<main><h1>Post</h1><article>Body</article><p>Continuation</p></main>", .{ .url = "https://example.org" });
    defer a.free(main);
    try std.testing.expectEqualStrings("# Post\nBody\nContinuation", main);
}

test "web text reports verification pages instead of claiming article content" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "<title>Just a moment...</title><script src='https://challenges.cloudflare.com/x'></script>",
        "<title>Reddit</title><script>form.requestSubmit()</script><form hidden><input name=\"solution\"></form>",
    }) |body| {
        const text = try extractAlloc(a, body, .{ .url = "https://example.org" });
        defer a.free(text);
        try std.testing.expect(std.mem.startsWith(u8, text, "[Access blocked:"));
    }
}

test "web text renders RSS and Atom entries and rejects XML entities" {
    const a = std.testing.allocator;
    const rss = try extractAlloc(a, "<?xml version='1.0'?><rss><channel><title>News</title><item><title>Release</title><link>https://example.org/release</link><pubDate>Today</pubDate><description><![CDATA[<p>Game &amp; Linux</p>]]></description></item></channel></rss>", .{ .url = "https://example.org/rss" });
    defer a.free(rss);
    try std.testing.expectEqualStrings("# News\n## Release\nhttps://example.org/release\nToday\nGame & Linux", rss);
    const atom = try extractAlloc(a, "<feed xmlns='http://www.w3.org/2005/Atom'><title>Feed</title><entry><title>Post</title><link href='/post'/><summary>Text</summary></entry></feed>", .{ .url = "https://example.org/feed" });
    defer a.free(atom);
    try std.testing.expectEqualStrings("# Feed\n## Post\nhttps://example.org/post\nText", atom);
    try std.testing.expectError(error.WebTextExtractionFailed, extractAlloc(a, "<?xml version='1.0'?><!DOCTYPE rss [<!ENTITY x 'bad'>]><rss/>", .{ .url = "https://example.org/feed" }));
}

test "web text finds versions in YAML and HTML without shell pipelines" {
    const a = std.testing.allocator;
    const yaml = try extractAlloc(a, "version: 1.2.3\r\nfiles:\n  - url: linux.AppImage\n", .{ .url = "https://example.org/latest.yml", .pattern = "^version:.*" });
    defer a.free(yaml);
    try std.testing.expectEqualStrings("version: 1.2.3", yaml);
    const html = try extractAlloc(a, "<main><h1>Download REAPER 7.55</h1><script>REAPER 0.00</script></main>", .{ .url = "https://example.org/download.php", .pattern = "REAPER [0-9]+\\.[0-9]+(\\.[0-9]+)?" });
    defer a.free(html);
    try std.testing.expectEqualStrings("REAPER 7.55", html);
    const absent = try extractAlloc(a, "Nothing here", .{ .url = "https://example.org", .pattern = "version" });
    defer a.free(absent);
    try std.testing.expectEqualStrings("[No matches for pattern]", absent);
    try std.testing.expectError(error.WebTextExtractionFailed, extractAlloc(a, "text", .{ .url = "https://example.org", .pattern = "[" }));
    try std.testing.expectError(error.InvalidArgs, extractAlloc(a, "text", .{ .url = "https://example.org", .format = .raw, .pattern = "version" }));
}
