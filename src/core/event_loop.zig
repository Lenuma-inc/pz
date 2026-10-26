//! Platform-native event loop: kqueue (macOS/BSD) or epoll (Linux).
const std = @import("std");
const sys = @import("pz_io");
const posix = std.posix;

const native_os = @import("builtin").os.tag;
const is_kqueue = native_os.isDarwin() or native_os == .freebsd or native_os == .netbsd or native_os == .openbsd;
const is_epoll = native_os == .linux;

comptime {
    if (!is_kqueue and !is_epoll) @compileError("unsupported OS: need kqueue or epoll");
}

pub const Interest = enum { read, write };

pub const Event = struct {
    fd: posix.fd_t,
    readable: bool,
    writable: bool,
    timer_id: ?TimerId = null, // set when this event is a timer firing
};

/// Max events returned per wait call.
pub const max_events = 64;

pub const TimerId = u32;
const max_timers = 32;
const timer_id_base: usize = 0x7fff_0000; // distinguish timer idents from fds in kqueue

/// Callback for fd readiness events.
pub const Handler = struct {
    vt: *const Vt,

    pub const Vt = struct {
        on_ready: *const fn (self: *Handler, fd: posix.fd_t, readable: bool, writable: bool) void,
    };

    fn call(self: *Handler, fd: posix.fd_t, readable: bool, writable: bool) void {
        self.vt.on_ready(self, fd, readable, writable);
    }

    pub fn Bind(comptime T: type, comptime on_ready_fn: fn (*T, posix.fd_t, bool, bool) void) type {
        return struct {
            pub const vt = Vt{
                .on_ready = onReadyFn,
            };
            fn onReadyFn(h: *Handler, fd: posix.fd_t, readable: bool, writable: bool) void {
                const self: *T = @alignCast(@fieldParentPtr("handler", h));
                on_ready_fn(self, fd, readable, writable);
            }
        };
    }
};

/// Callback for timer events.
pub const TimerHandler = struct {
    vt: *const Vt,

    pub const Vt = struct {
        on_timer: *const fn (self: *TimerHandler, id: TimerId) void,
    };

    fn call(self: *TimerHandler, id: TimerId) void {
        self.vt.on_timer(self, id);
    }

    pub fn Bind(comptime T: type, comptime on_timer_fn: fn (*T, TimerId) void) type {
        return struct {
            pub const vt = Vt{
                .on_timer = onTimerFn,
            };
            fn onTimerFn(th: *TimerHandler, id: TimerId) void {
                const self: *T = @alignCast(@fieldParentPtr("timer_handler", th));
                on_timer_fn(self, id);
            }
        };
    }
};

const max_handlers = 64;

const FdEntry = struct {
    fd: posix.fd_t,
    handler: *Handler,
};

pub const EventLoop = struct {
    backend: posix.fd_t,
    wake_r: posix.fd_t,
    wake_w: posix.fd_t,
    timer_count: u32 = 0,
    timer_fds: if (is_epoll) [max_timers]posix.fd_t else void =
        if (is_epoll) [_]posix.fd_t{-1} ** max_timers else {},
    // Fd → handler dispatch table
    fd_handlers: [max_handlers]FdEntry = [_]FdEntry{.{ .fd = -1, .handler = undefined }} ** max_handlers,
    fd_handler_count: u32 = 0,
    // Timer handlers
    timer_handlers: [max_timers]?*TimerHandler = [_]?*TimerHandler{null} ** max_timers,
    // SIGCHLD signalfd (Linux) or kqueue EVFILT_SIGNAL
    sigchld_fd: posix.fd_t = -1,
    sigchld_handler: ?*Handler = null,

    pub fn init() !EventLoop {
        const pipe = try makePipe();
        errdefer {
            _ = std.c.close(pipe[0]);
            _ = std.c.close(pipe[1]);
        }
        const fd = try backendCreate();
        errdefer _ = std.c.close(fd);
        var self = EventLoop{
            .backend = fd,
            .wake_r = pipe[0],
            .wake_w = pipe[1],
        };
        try self.registerFd(pipe[0], .read);
        return self;
    }

    /// Add a one-shot timer that fires after `ms` milliseconds.
    /// Returns a TimerId that appears in Event.timer_id when it fires.
    pub fn addTimer(self: *EventLoop, ms: u32) !TimerId {
        if (self.timer_count >= max_timers) return error.TooManyTimers;
        const id: TimerId = self.timer_count;
        self.timer_count += 1;

        if (is_kqueue) {
            const changelist = [1]std.posix.Kevent{.{
                .ident = timer_id_base + id,
                .filter = std.posix.system.EVFILT.TIMER,
                .flags = std.posix.system.EV.ADD | std.posix.system.EV.ONESHOT,
                .fflags = 0,
                .data = ms,
                .udata = 0,
            }};
            _ = try kqueueWaitChanges(self.backend, &changelist, &.{}, null);
        } else {
            const tfd = timerfdCreate() catch return error.TimerCreateFailed;
            errdefer _ = std.c.close(tfd);
            try timerfdSet(tfd, ms);
            var ev = std.os.linux.epoll_event{
                .events = std.os.linux.EPOLL.IN,
                .data = .{ .fd = tfd },
            };
            const rc = std.os.linux.epoll_ctl(@intCast(self.backend), std.os.linux.EPOLL.CTL_ADD, @intCast(tfd), &ev);
            if (std.posix.errno(rc) != .SUCCESS) {
                _ = std.c.close(tfd);
                return error.TimerCreateFailed;
            }
            self.timer_fds[id] = tfd;
        }
        return id;
    }

    /// Cancel a pending timer. No-op if already fired.
    pub fn cancelTimer(self: *EventLoop, id: TimerId) void {
        if (is_kqueue) {
            const changelist = [1]std.posix.Kevent{.{
                .ident = timer_id_base + id,
                .filter = std.posix.system.EVFILT.TIMER,
                .flags = std.posix.system.EV.DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            }};
            _ = kqueueWaitChanges(self.backend, &changelist, &.{}, null) catch {}; // cleanup: timer may already have fired
        } else {
            if (id < max_timers and self.timer_fds[id] >= 0) {
                _ = std.os.linux.epoll_ctl(@intCast(self.backend), std.os.linux.EPOLL.CTL_DEL, @intCast(self.timer_fds[id]), null);
                _ = std.c.close(self.timer_fds[id]);
                self.timer_fds[id] = -1;
            }
        }
    }

    /// Add a timer with a handler that's called when it fires.
    pub fn addTimerWithHandler(self: *EventLoop, ms: u32, handler: *TimerHandler) !TimerId {
        const id = try self.addTimer(ms);
        self.timer_handlers[id] = handler;
        return id;
    }

    /// Wait for events and dispatch to registered handlers.
    /// Returns the number of events dispatched. Unhandled fd events
    /// (registered without a handler) are returned in `unhandled`.
    pub fn dispatch(self: *EventLoop, timeout_ms: i32, unhandled: *[max_events]Event) !usize {
        var buf: [max_events]Event = undefined;
        const events = try self.wait(timeout_ms, &buf);
        var uh_count: usize = 0;
        for (events) |ev| {
            if (ev.timer_id) |tid| {
                if (tid < max_timers) {
                    if (self.timer_handlers[tid]) |th| {
                        th.call(tid);
                        self.timer_handlers[tid] = null;
                        continue;
                    }
                }
                // Unhandled timer
                unhandled[uh_count] = ev;
                uh_count += 1;
                continue;
            }
            // Look up fd handler
            var handled = false;
            for (self.fd_handlers[0..self.fd_handler_count]) |entry| {
                if (entry.fd == ev.fd) {
                    entry.handler.call(ev.fd, ev.readable, ev.writable);
                    handled = true;
                    break;
                }
            }
            if (!handled) {
                unhandled[uh_count] = ev;
                uh_count += 1;
            }
        }
        return uh_count;
    }

    /// Register a handler for SIGCHLD (child process exit).
    /// Only one SIGCHLD handler is supported.
    pub fn watchSigchld(self: *EventLoop, handler: *Handler) !void {
        if (self.sigchld_handler != null) return error.AlreadyRegistered;

        if (is_kqueue) {
            // kqueue: use EVFILT_SIGNAL for SIGCHLD
            const changelist = [1]std.posix.Kevent{.{
                .ident = std.posix.SIG.CHLD,
                .filter = std.posix.system.EVFILT.SIGNAL,
                .flags = std.posix.system.EV.ADD,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            }};
            _ = try kqueueWaitChanges(self.backend, &changelist, &.{}, null);
            // Block SIGCHLD so kqueue gets the event instead of the default handler
            var mask = std.mem.zeroes(posix.sigset_t);
            sigaddset(&mask, posix.SIG.CHLD);
            _ = std.c.sigprocmask(posix.SIG.BLOCK, &mask, null);
        } else {
            // Linux: use signalfd
            var mask = std.mem.zeroes(posix.sigset_t);
            sigaddset(&mask, posix.SIG.CHLD);
            _ = std.c.sigprocmask(posix.SIG.BLOCK, &mask, null);
            const sfd = std.c.signalfd(-1, &mask, std.os.linux.SFD.NONBLOCK | std.os.linux.SFD.CLOEXEC);
            if (std.posix.errno(sfd) != .SUCCESS) return error.SignalFdFailed;
            self.sigchld_fd = @intCast(sfd);
            try self.registerFd(self.sigchld_fd, .read);
        }
        self.sigchld_handler = handler;
    }

    pub fn deinit(self: *EventLoop) void {
        // Unblock SIGCHLD if we blocked it via watchSigchld.
        if (self.sigchld_handler != null) {
            var mask = std.mem.zeroes(posix.sigset_t);
            sigaddset(&mask, posix.SIG.CHLD);
            _ = std.c.sigprocmask(posix.SIG.UNBLOCK, &mask, null);
        }
        if (is_epoll) {
            for (self.timer_fds) |tfd| {
                if (tfd >= 0) _ = std.c.close(tfd);
            }
            if (self.sigchld_fd >= 0) _ = std.c.close(self.sigchld_fd);
        }
        _ = std.c.close(self.backend);
        _ = std.c.close(self.wake_r);
        _ = std.c.close(self.wake_w);
        self.* = undefined;
    }

    pub fn register(self: *EventLoop, fd: posix.fd_t, interest: Interest) !void {
        try self.registerFd(fd, interest);
    }

    /// Register fd with a handler that's called on readiness.
    pub fn registerHandler(self: *EventLoop, fd: posix.fd_t, interest: Interest, handler: *Handler) !void {
        try self.registerFd(fd, interest);
        if (self.fd_handler_count >= max_handlers) return error.TooManyHandlers;
        self.fd_handlers[self.fd_handler_count] = .{ .fd = fd, .handler = handler };
        self.fd_handler_count += 1;
    }

    pub fn unregister(self: *EventLoop, fd: posix.fd_t) !void {
        try self.unregisterFd(fd);
        // Remove handler entry if present
        var i: u32 = 0;
        while (i < self.fd_handler_count) {
            if (self.fd_handlers[i].fd == fd) {
                self.fd_handlers[i] = self.fd_handlers[self.fd_handler_count - 1];
                self.fd_handler_count -= 1;
            } else {
                i += 1;
            }
        }
    }

    /// Block until fds are ready or timeout expires. Returns ready events.
    /// `timeout_ms`: -1 for infinite, 0 for poll, >0 for ms.
    /// Caller must use returned slice before next call to wait.
    pub fn wait(self: *EventLoop, timeout_ms: i32, buf: *[max_events]Event) ![]Event {
        var n: usize = 0;
        if (is_kqueue) {
            var kev: [max_events]std.posix.Kevent = undefined;
            const ts: ?*const std.posix.timespec = if (timeout_ms >= 0) &.{
                .sec = @divTrunc(timeout_ms, 1000),
                .nsec = @rem(timeout_ms, 1000) * 1_000_000,
            } else null;
            const count = try kqueueWait(self.backend, &kev, ts);
            for (kev[0..count]) |ev| {
                if (ev.filter == std.posix.system.EVFILT.TIMER) {
                    const tid: TimerId = @intCast(ev.ident - timer_id_base);
                    buf[n] = .{ .fd = -1, .readable = false, .writable = false, .timer_id = tid };
                    n += 1;
                    continue;
                }
                if (ev.filter == std.posix.system.EVFILT.SIGNAL) {
                    // SIGCHLD — dispatch to handler if set
                    if (self.sigchld_handler) |h| {
                        h.call(-1, true, false);
                    }
                    continue;
                }
                const fd: posix.fd_t = @intCast(ev.ident);
                if (fd == self.wake_r) {
                    drain(self.wake_r);
                    continue;
                }
                buf[n] = .{
                    .fd = fd,
                    .readable = ev.filter == std.posix.system.EVFILT.READ,
                    .writable = ev.filter == std.posix.system.EVFILT.WRITE,
                };
                n += 1;
            }
        } else {
            var epev: [max_events]std.os.linux.epoll_event = undefined;
            const count = try epollWait(self.backend, &epev, timeout_ms);
            for (epev[0..count]) |ev| {
                const fd = ev.data.fd;
                if (fd == self.wake_r) {
                    drain(self.wake_r);
                    continue;
                }
                // Check if this fd is a signalfd
                if (fd == self.sigchld_fd and self.sigchld_fd >= 0) {
                    drain(fd);
                    if (self.sigchld_handler) |h| h.call(-1, true, false);
                    continue;
                }
                // Check if this fd is a timerfd
                const tid = self.findTimerId(fd);
                if (tid != null) {
                    drainTimerfd(fd);
                    buf[n] = .{ .fd = -1, .readable = false, .writable = false, .timer_id = tid };
                    n += 1;
                    continue;
                }
                buf[n] = .{
                    .fd = fd,
                    .readable = (ev.events & std.os.linux.EPOLL.IN) != 0,
                    .writable = (ev.events & std.os.linux.EPOLL.OUT) != 0,
                };
                n += 1;
            }
        }
        return buf[0..n];
    }

    /// Interrupt a blocking wait() from another thread or signal handler.
    pub fn wake(self: *EventLoop) void {
        _ = fdWrite(self.wake_w, "\x01") catch return; // cleanup: propagation impossible
    }

    fn findTimerId(self: *const EventLoop, fd: posix.fd_t) ?TimerId {
        if (!is_epoll) return null;
        for (self.timer_fds, 0..) |tfd, i| {
            if (tfd == fd) return @intCast(i);
        }
        return null;
    }

    // -- platform impl --

    fn registerFd(self: *EventLoop, fd: posix.fd_t, interest: Interest) !void {
        if (is_kqueue) {
            const filter: i16 = switch (interest) {
                .read => std.posix.system.EVFILT.READ,
                .write => std.posix.system.EVFILT.WRITE,
            };
            const changelist = [1]std.posix.Kevent{.{
                .ident = @intCast(fd),
                .filter = filter,
                .flags = std.posix.system.EV.ADD,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            }};
            _ = try kqueueWaitChanges(self.backend, &changelist, &.{}, null);
        } else {
            const events: u32 = switch (interest) {
                .read => std.os.linux.EPOLL.IN,
                .write => std.os.linux.EPOLL.OUT,
            };
            var ev = std.os.linux.epoll_event{
                .events = events,
                .data = .{ .fd = fd },
            };
            const rc = std.os.linux.epoll_ctl(@intCast(self.backend), std.os.linux.EPOLL.CTL_ADD, @intCast(fd), &ev);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {},
                .BADF => return error.BadFd,
                .EXIST => return error.AlreadyRegistered,
                .INVAL => return error.InvalidArg,
                .NOMEM => return error.OutOfMemory,
                else => return error.Unexpected,
            }
        }
    }

    fn unregisterFd(self: *EventLoop, fd: posix.fd_t) !void {
        if (is_kqueue) {
            // Remove both read and write filters; ignore ENOENT for the one not registered.
            inline for ([_]i16{ std.posix.system.EVFILT.READ, std.posix.system.EVFILT.WRITE }) |filter| {
                const changelist = [1]std.posix.Kevent{.{
                    .ident = @intCast(fd),
                    .filter = filter,
                    .flags = std.posix.system.EV.DELETE,
                    .fflags = 0,
                    .data = 0,
                    .udata = 0,
                }};
                _ = kqueueWaitChanges(self.backend, &changelist, &.{}, null) catch {}; // cleanup: propagation impossible
            }
        } else {
            const rc = std.os.linux.epoll_ctl(@intCast(self.backend), std.os.linux.EPOLL.CTL_DEL, @intCast(fd), null);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {},
                .BADF => return error.BadFd,
                .NOENT => return error.NotRegistered,
                .INVAL => return error.InvalidArg,
                else => return error.Unexpected,
            }
        }
    }
};

fn backendCreate() !posix.fd_t {
    if (is_kqueue) {
        return try posix.kqueue();
    } else {
        const rc = std.os.linux.epoll_create1(std.os.linux.EPOLL.CLOEXEC);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .MFILE, .NFILE => return error.ProcessFdQuotaExceeded,
            .NOMEM => return error.OutOfMemory,
            else => return error.Unexpected,
        }
    }
}

fn kqueueWait(kq: posix.fd_t, events: []std.posix.Kevent, ts: ?*const std.posix.timespec) !usize {
    return kqueueWaitChanges(kq, &.{}, events, ts);
}

fn kqueueWaitChanges(kq: posix.fd_t, changelist: []const std.posix.Kevent, events: []std.posix.Kevent, ts: ?*const std.posix.timespec) !usize {
    while (true) {
        const rc = posix.system.kevent(
            kq,
            changelist.ptr,
            @intCast(changelist.len),
            events.ptr,
            @intCast(events.len),
            ts,
        );
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF => return error.BadFd,
            .INVAL => return error.InvalidArg,
            .NOENT => return error.NotRegistered,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

fn epollWait(epfd: posix.fd_t, events: []std.os.linux.epoll_event, timeout_ms: i32) !usize {
    while (true) {
        const rc = std.os.linux.epoll_wait(@intCast(epfd), events.ptr, @intCast(events.len), timeout_ms);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .BADF => return error.BadFd,
            .INVAL => return error.InvalidArg,
            else => |e| return posix.unexpectedErrno(e),
        }
    }
}

fn timerfdCreate() !posix.fd_t {
    const rc = std.os.linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
    if (std.posix.errno(rc) != .SUCCESS) return error.TimerCreateFailed;
    return @intCast(rc);
}

fn timerfdSet(fd: posix.fd_t, ms: u32) !void {
    const secs: i64 = @divTrunc(ms, 1000);
    const nsecs: i64 = @rem(ms, 1000) * 1_000_000;
    const spec = std.os.linux.itimerspec{
        .it_interval = .{ .sec = 0, .nsec = 0 }, // one-shot
        .it_value = .{ .sec = secs, .nsec = nsecs },
    };
    const rc = std.os.linux.timerfd_settime(@intCast(fd), .{}, &spec, null);
    if (std.posix.errno(rc) != .SUCCESS) return error.TimerSetFailed;
}

fn drainTimerfd(fd: posix.fd_t) void {
    var buf: [8]u8 = undefined;
    _ = posix.read(fd, &buf) catch {}; // cleanup: drain expiration count
}

fn sigaddset(set: *posix.sigset_t, sig: posix.SIG) void {
    _ = std.c.sigaddset(set, sig);
}

test "libc signal mask works with signalfd" {
    if (!is_epoll) return error.SkipZigTest;
    var mask = std.mem.zeroes(posix.sigset_t);
    sigaddset(&mask, posix.SIG.CHLD);
    const fd = std.c.signalfd(-1, &mask, std.os.linux.SFD.NONBLOCK | std.os.linux.SFD.CLOEXEC);
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
}

fn drain(fd: posix.fd_t) void {
    var buf: [64]u8 = undefined;
    while (true) {
        _ = posix.read(fd, &buf) catch return; // cleanup: propagation impossible
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

test "register pipe, write, wait returns ready" {
    var el = try EventLoop.init();
    defer el.deinit();

    // Create a pipe to monitor.
    const pipe = try makePipe();
    defer _ = std.c.close(pipe[0]);
    defer _ = std.c.close(pipe[1]);

    try el.register(pipe[0], .read);

    // Write to pipe so read end becomes ready.
    _ = try fdWrite(pipe[1], "x");

    var buf: [max_events]Event = undefined;
    const events = try el.wait(1000, &buf);
    try std.testing.expect(events.len >= 1);
    try std.testing.expectEqual(pipe[0], events[0].fd);
    try std.testing.expect(events[0].readable);
}

test "wait times out with no events" {
    var el = try EventLoop.init();
    defer el.deinit();

    var buf: [max_events]Event = undefined;
    const events = try el.wait(0, &buf);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "wake interrupts blocking wait" {
    var el = try EventLoop.init();
    defer el.deinit();

    // Spawn thread that wakes after short delay.
    const t = try std.Thread.spawn(.{}, struct {
        fn run(loop: *EventLoop) void {
            std.Io.sleep(sys.io, .fromMilliseconds(10), .awake) catch @panic("test sleep canceled");
            loop.wake();
        }
    }.run, .{&el});

    var buf: [max_events]Event = undefined;
    // Should return quickly (wake consumed internally), no user events.
    const events = try el.wait(5000, &buf);
    try std.testing.expectEqual(@as(usize, 0), events.len);
    t.join();
}

test "unregister removes fd" {
    var el = try EventLoop.init();
    defer el.deinit();

    const pipe = try makePipe();
    defer _ = std.c.close(pipe[0]);
    defer _ = std.c.close(pipe[1]);

    try el.register(pipe[0], .read);
    try el.unregister(pipe[0]);

    // Write to pipe — should NOT appear in events since unregistered.
    _ = try fdWrite(pipe[1], "y");

    var buf: [max_events]Event = undefined;
    const events = try el.wait(0, &buf);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "multiple fds" {
    var el = try EventLoop.init();
    defer el.deinit();

    const p1 = try makePipe();
    defer _ = std.c.close(p1[0]);
    defer _ = std.c.close(p1[1]);
    const p2 = try makePipe();
    defer _ = std.c.close(p2[0]);
    defer _ = std.c.close(p2[1]);

    try el.register(p1[0], .read);
    try el.register(p2[0], .read);

    _ = try fdWrite(p1[1], "a");
    _ = try fdWrite(p2[1], "b");

    var buf: [max_events]Event = undefined;
    const events = try el.wait(1000, &buf);
    try std.testing.expectEqual(@as(usize, 2), events.len);

    // Both fds should be present (order not guaranteed).
    var saw_p1 = false;
    var saw_p2 = false;
    for (events) |ev| {
        if (ev.fd == p1[0]) saw_p1 = true;
        if (ev.fd == p2[0]) saw_p2 = true;
    }
    try std.testing.expect(saw_p1);
    try std.testing.expect(saw_p2);
}

test "timer fires after delay" {
    var el = try EventLoop.init();
    defer el.deinit();

    const tid = try el.addTimer(50); // 50ms

    var buf: [max_events]Event = undefined;
    const events = try el.wait(2000, &buf); // wait up to 2s
    try std.testing.expect(events.len >= 1);
    try std.testing.expectEqual(tid, events[0].timer_id.?);
    try std.testing.expectEqual(@as(posix.fd_t, -1), events[0].fd);
}

test "cancelled timer does not fire" {
    var el = try EventLoop.init();
    defer el.deinit();

    const tid = try el.addTimer(5000); // 5s — won't fire in time
    _ = tid;
    el.cancelTimer(0);

    var buf: [max_events]Event = undefined;
    const events = try el.wait(100, &buf); // 100ms — timer was cancelled
    // Should get 0 events (timer cancelled, nothing else registered)
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

pub fn makePipe() ![2]posix.fd_t {
    const flags: posix.O = .{ .NONBLOCK = true, .CLOEXEC = true };
    var fds: [2]std.posix.fd_t = undefined;
    if (@import("builtin").os.tag == .linux) {
        if (std.c.pipe2(&fds, flags) != 0) return error.Io;
        return fds;
    }
    if (std.c.pipe(&fds) != 0) return error.Io;
    errdefer for (fds) |fd| {
        _ = std.c.close(fd);
    };
    for (fds) |fd| {
        if (flags.CLOEXEC and std.c.fcntl(fd, std.posix.F.SETFD, @as(c_int, std.posix.FD_CLOEXEC)) < 0) return error.Io;
        if (flags.NONBLOCK and std.c.fcntl(fd, std.posix.F.SETFL, @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true }))) < 0) return error.Io;
    }
    return fds;
}

fn fdWrite(fd: posix.fd_t, bytes: []const u8) !usize {
    while (true) {
        const rc = std.c.write(fd, bytes.ptr, bytes.len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}
