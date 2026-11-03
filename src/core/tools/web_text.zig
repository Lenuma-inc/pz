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
    const wrapped = try extractAlloc(a, "{\"titleHtml\":\"Title\",\"textHtml\":\"<div class='article-formatted-body'>Body</div>\"}", .{ .url = "https://example.org" });
    defer a.free(wrapped);
    try std.testing.expectEqualStrings("[Article text extracted from JSON; metadata omitted]\nTitle\nBody", wrapped);
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

/// Apply the byte budget while selecting lines, reserving space for continuation.
pub fn pageAlloc(alloc: std.mem.Allocator, body: []const u8, status: u16, req: web.Request, limit: usize) ![]u8 {
    if (req.from_line == 0 or (req.to_line != null and req.to_line.? < req.from_line)) return error.InvalidArgs;
    if (!std.unicode.utf8ValidateSlice(body)) return error.BinaryFile;
    if (limit < 192) return error.TooLarge;
    const total = std.mem.count(u8, body, "\n") + @intFromBool(body.len > 0 and body[body.len - 1] != '\n');
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    try out.writer.print("HTTP {d} | extracted text: {d} lines\n", .{ status, total });
    if (out.written().len + 160 >= limit) return error.TooLarge;
    const end_line = req.to_line orelse (req.from_line +| 79);
    var lines = std.mem.splitScalar(u8, body, '\n');
    var n: usize = 0;
    var last: ?usize = null;
    var next: ?usize = null;
    var offset: usize = 0;
    var in_code = false;
    while (lines.next()) |line| {
        if (line.len == 0 and lines.index == null) break;
        n += 1;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "```")) in_code = !in_code;
        if (n < req.from_line) continue;
        const start: usize = if (n == req.from_line) req.line_offset else 0;
        if (start > line.len or (start < line.len and (line[start] & 0xc0) == 0x80)) return error.InvalidArgs;
        if (n > end_line) {
            next = n;
            break;
        }
        var prefix_buf: [64]u8 = undefined;
        const prefix = if (start == 0) try std.fmt.bufPrint(&prefix_buf, "{d}: ", .{n}) else try std.fmt.bufPrint(&prefix_buf, "{d} (+{d} bytes): ", .{ n, start });
        const available = limit - out.written().len - 160;
        const remaining = line[start..];
        if (last != null and start == 0 and !in_code and tableRow(line)) {
            var probe = lines;
            if (probe.next()) |divider| {
                if (tableDivider(divider)) {
                    var table_bytes = prefix.len + line.len + 1;
                    var table_end = n;
                    var row: ?[]const u8 = divider;
                    while (row) |text| {
                        if (!tableRow(text)) break;
                        table_end += 1;
                        table_bytes += std.fmt.count("{d}: {s}\n", .{ table_end, text });
                        row = probe.next();
                    }
                    if (table_bytes > available or table_end > end_line) {
                        next = n;
                        break;
                    }
                }
            }
        }
        if (prefix.len + remaining.len + 1 > available) {
            next = n;
            if (last == null) {
                if (available <= prefix.len + 1) return error.TooLarge;
                var bytes = available - prefix.len - 1;
                while (bytes > 0 and (remaining[bytes] & 0xc0) == 0x80) bytes -= 1;
                if (bytes == 0) return error.TooLarge;
                try out.writer.print("{s}{s}\n", .{ prefix, remaining[0..bytes] });
                offset = start + bytes;
            }
            break;
        }
        try out.writer.print("{s}{s}\n", .{ prefix, remaining });
        last = n;
    }
    if (last) |line| {
        try out.writer.print("last_complete_line={d}; ", .{line});
    } else {
        try out.writer.writeAll("last_complete_line=none; ");
    }
    if (next) |line| {
        try out.writer.print("next from_line={d}, line_offset={d}\n", .{ line, offset });
    } else {
        try out.writer.writeAll("next=none\n");
    }
    std.debug.assert(out.written().len <= limit);
    return out.toOwnedSlice();
}

fn tableRow(line: []const u8) bool {
    const text = std.mem.trim(u8, line, " \t");
    return text.len >= 2 and text[0] == '|' and text[text.len - 1] == '|';
}

fn tableDivider(line: []const u8) bool {
    if (!tableRow(line)) return false;
    var dashes: usize = 0;
    for (line) |ch| switch (ch) {
        '-' => dashes += 1,
        '|', ':', ' ', '\t' => {},
        else => return false,
    };
    return dashes >= 3;
}

test "web text keeps table columns and excludes article surroundings" {
    const a = std.testing.allocator;
    const html = "<main><h1>Benchmark</h1><div class='article-formatted-body'><p>Results</p><table><tr><th>Model</th><th>Tokens</th></tr><tr><td>A <a href='/a'>link</a></td><td><p>42.2k</p></td></tr><tr><td>B | C</td><td>52k</td></tr></table><pre>log: 1\nlog: 2</pre></div><p>Tags and comments</p><article>Related</article></main>";
    const text = try extractAlloc(a, html, .{ .url = "https://example.org" });
    defer a.free(text);
    try std.testing.expectEqualStrings("# Benchmark\nResults\n| Model | Tokens |\n| --- | --- |\n| A [link](https://example.org/a) | 42.2k |\n| B \\| C | 52k |\n```\nlog: 1\nlog: 2\n```", text);
    const no_header = try extractAlloc(a, "<table><tr><td>1</td><td>2</td></tr></table>", .{ .url = "https://example.org" });
    defer a.free(no_header);
    try std.testing.expectEqualStrings("| 1 | 2 |\n| --- | --- |", no_header);
}

test "web text pagination reports exact whole line continuation within byte limit" {
    const a = std.testing.allocator;
    const body = "first line\nsecond line\nthird line\nfourth line";
    const first = try pageAlloc(a, body, 200, .{ .url = "https://example.org" }, 235);
    defer a.free(first);
    try std.testing.expect(first.len <= 235);
    try std.testing.expect(std.mem.indexOf(u8, first, "1: first line\n2: second line\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "last_complete_line=2; next from_line=3, line_offset=0") != null);
    const rest = try pageAlloc(a, body, 200, .{ .url = "https://example.org", .from_line = 3 }, 300);
    defer a.free(rest);
    try std.testing.expect(std.mem.indexOf(u8, rest, "3: third line\n4: fourth line\nlast_complete_line=4; next=none") != null);
    const range = try pageAlloc(a, body, 200, .{ .url = "https://example.org", .to_line = 1 }, 300);
    defer a.free(range);
    try std.testing.expect(std.mem.indexOf(u8, range, "next from_line=2, line_offset=0") != null);
}

test "web text oversized Unicode line resumes at exact byte offset" {
    const a = std.testing.allocator;
    const body = "Привет" ** 50;
    const first = try pageAlloc(a, body, 200, .{ .url = "https://example.org" }, 256);
    defer a.free(first);
    try std.testing.expect(first.len <= 256);
    try std.testing.expect(std.unicode.utf8ValidateSlice(first));
    const marker = "next from_line=1, line_offset=";
    const at = (std.mem.indexOf(u8, first, marker) orelse return error.TestUnexpectedResult) + marker.len;
    const offset = try std.fmt.parseInt(u32, std.mem.trim(u8, first[at..], "\n"), 10);
    try std.testing.expect(offset > 0 and offset < body.len);
    try std.testing.expect(std.mem.indexOf(u8, first, body[0..offset]) != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "last_complete_line=none") != null);
    const rest = try pageAlloc(a, body, 200, .{ .url = "https://example.org", .line_offset = offset }, 2048);
    defer a.free(rest);
    try std.testing.expect(std.mem.indexOf(u8, rest, body[offset..]) != null);
    try std.testing.expect(std.mem.indexOf(u8, rest, "last_complete_line=1; next=none") != null);
    try std.testing.expectError(error.InvalidArgs, pageAlloc(a, body, 200, .{ .url = "https://example.org", .line_offset = 1 }, 256));
}

test "web text retains news titles with multiple article bodies and table captions" {
    const a = std.testing.allocator;
    const listing = try extractAlloc(a, "<main><h1>News</h1><h2>First</h2><div class='entry-content'>Body A</div><h2>Second</h2><div class='entry-content'>Body B</div></main>", .{ .url = "https://example.org" });
    defer a.free(listing);
    try std.testing.expectEqualStrings("# News\n## First\nBody A\n## Second\nBody B", listing);
    const caption = try extractAlloc(a, "<table><caption>Times in seconds</caption><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>", .{ .url = "https://example.org" });
    defer a.free(caption);
    try std.testing.expect(std.mem.startsWith(u8, caption, "Times in seconds\n| A | B |"));
    const empty = try extractAlloc(a, "<table><tr><td></td></tr></table>", .{ .url = "https://example.org" });
    defer a.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "web text pagination continues after default line limit" {
    const a = std.testing.allocator;
    const page = try pageAlloc(a, "line\n" ** 100, 200, .{ .url = "https://example.org" }, 8192);
    defer a.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "80: line\nlast_complete_line=80; next from_line=81, line_offset=0") != null);
    try std.testing.expectError(error.TooLarge, pageAlloc(a, "text", 200, .{ .url = "https://example.org" }, 192));
}

test "web text prefers explicit body over recommendation cards and joins list paragraphs" {
    const a = std.testing.allocator;
    const html = "<main><h1>Article</h1><div class='article-formatted-body'><ul><li><p>First <strong>item</strong></p></li><li><div><p><a href='/x'>Second</a> item</p></div></li></ul><table><tr><td></td><td></td></tr><tr><td>Configuration</td><td>Tokens</td></tr><tr><td>Model A</td><td>42k</td></tr></table></div><div class='article-content'>Qwen recommendation</div><div class='article-content'>Linux recommendation</div></main>";
    const text = try extractAlloc(a, html, .{ .url = "https://example.org" });
    defer a.free(text);
    try std.testing.expectEqualStrings("# Article\n- First item\n- [Second](https://example.org/x) item\n| Configuration | Tokens |\n| --- | --- |\n| Model A | 42k |", text);
}

test "web text pagination moves tables to a fresh page when necessary" {
    const a = std.testing.allocator;
    const table = "| Configuration | Tokens | Time |\n| --- | --- | --- |\n| Model A | 42k | 15 min |\n| Model B | 52k | 12 min |";
    const body = "intro " ** 15 ++ "\n" ++ table ++ "\nConclusion";
    const first = try pageAlloc(a, body, 200, .{ .url = "https://example.org" }, 400);
    defer a.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "Configuration") == null);
    try std.testing.expect(std.mem.indexOf(u8, first, "last_complete_line=1; next from_line=2, line_offset=0") != null);
    const rest = try pageAlloc(a, body, 200, .{ .url = "https://example.org", .from_line = 2 }, 400);
    defer a.free(rest);
    try std.testing.expect(std.mem.indexOf(u8, rest, "2: | Configuration") != null);
    try std.testing.expect(std.mem.indexOf(u8, rest, "5: | Model B | 52k | 12 min |") != null);
    const range = try pageAlloc(a, body, 200, .{ .url = "https://example.org", .to_line = 3 }, 8192);
    defer a.free(range);
    try std.testing.expect(std.mem.indexOf(u8, range, "Configuration") == null);
    try std.testing.expect(std.mem.indexOf(u8, range, "next from_line=2, line_offset=0") != null);
    const oversized = try pageAlloc(a, table ++ "\n| Model C | 100k | 30 min |\n" ** 20, 200, .{ .url = "https://example.org" }, 400);
    defer a.free(oversized);
    try std.testing.expect(std.mem.indexOf(u8, oversized, "1: | Configuration") != null);
    try std.testing.expect(std.mem.indexOf(u8, oversized, "next from_line=") != null);
}

test "web text bounded Next.js Flight fallback" {
    const a = std.testing.allocator;
    const script = "<script nonce='x'>self.__next_f.push([1,\"0:[\\\"$\\\",\\\"main\\\",null,{\\\"children\\\":[\\\"$L1\\\",\\\"$2\\\"]}]\\n1:[\\\"$\\\",\\\"h1\\\",null,{\\\"children\\\":\\\"RSC article\\\"}]\\n2:[\\\"$\\\",\\\"p\\\",null,{\\\"children\\\":\\\"Recovered body & text\\\",\\\"secret\\\":\\\"DO NOT SHOW\\\"}]\\n\"])</script>";
    const text = try extractAlloc(a, "<main>Loading</main>" ++ script, .{ .url = "https://example.org" });
    defer a.free(text);
    try std.testing.expectEqualStrings("[Text extracted from Next.js/RSC data]\n# RSC article\nRecovered body & text", text);
    const existing = "<main>" ++ ("Useful server-rendered content. " ** 10) ++ "</main>";
    const kept = try extractAlloc(a, existing ++ script, .{ .url = "https://example.org" });
    defer a.free(kept);
    try std.testing.expect(std.mem.indexOf(u8, kept, "RSC") == null);
    const malformed = try extractAlloc(a, "<main>Loading</main><script>self.__next_f.push(not_json())</script>", .{ .url = "https://example.org" });
    defer a.free(malformed);
    try std.testing.expectEqualStrings("Loading", malformed);
    const cycle = try extractAlloc(a, "<script>self.__next_f.push([1,\"0:[\\\"$\\\",\\\"p\\\",null,{\\\"children\\\":\\\"$0\\\"}]\\n\"])</script>", .{ .url = "https://example.org" });
    defer a.free(cycle);
    try std.testing.expectEqualStrings("", cycle);
}

test "web text selects prose inside broad containers without trimming short pages" {
    const a = std.testing.allocator;
    const prose = "A detailed article paragraph explains the measurements and their implications for readers, with enough context to distinguish it from navigation.";
    const html = "<main><h1>Article title</h1><div><a href='/ads'>" ++ ("Promoted link " ** 30) ++ "</a></div><div><p>" ++ prose ++ "</p><p>" ++ prose ++ "</p><p>" ++ prose ++ "</p></div></main>";
    const text = try extractAlloc(a, html, .{ .url = "https://example.org" });
    defer a.free(text);
    try std.testing.expectEqualStrings("# Article title\n" ++ prose ++ "\n" ++ prose ++ "\n" ++ prose, text);
    const short = try extractAlloc(a, "Introduction<div><p>Small body</p></div>Conclusion", .{ .url = "https://example.org" });
    defer a.free(short);
    try std.testing.expectEqualStrings("Introduction\nSmall body\nConclusion", short);
    const explicit = try extractAlloc(a, "<main><div class='article-content'><p>Selected body</p></div><div>Other content</div></main>", .{ .url = "https://example.org" });
    defer a.free(explicit);
    try std.testing.expectEqualStrings("Selected body", explicit);
}
