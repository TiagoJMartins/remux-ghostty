//! Generic libghostty C boundary for producing terminal state without a PTY.
//!
//! A producer owns one shared terminal and one persistent VT stream. It is a
//! writer/lifetime boundary only: rendering and transport remain host concerns.

const std = @import("std");
const state = &@import("../global.zig").state;
const SharedTerminal = @import("Shared.zig");
const clipboard = @import("clipboard.zig");
const TerminalStream = @import("stream_terminal.zig").Stream;

pub const Result = enum(c_int) {
    ok,
    invalid_input,
    out_of_memory,
};

pub const Config = extern struct {
    columns: u16 = 80,
    rows: u16 = 24,
    max_scrollback: usize = 10_000,
};

/// One representation of a clipboard write. Both strings are ptr+len rather
/// than NUL-terminated because an OSC 52 payload is base64-DECODED before it
/// reaches here and is therefore arbitrary bytes, NUL included.
///
/// Borrowed: valid only for the duration of the callback.
pub const ClipboardContent = extern struct {
    mime_ptr: [*]const u8,
    mime_len: usize,
    data_ptr: [*]const u8,
    data_len: usize,
};

/// C callbacks for the effects a producer's stream can raise.
///
/// A producer's stream defaults to the READONLY effect set, which drops every
/// sequence needing a response or an outside side effect. That is the right
/// default for a pure state mirror and the wrong one for a terminal a program
/// talks to: with no `write_pty` the stream cannot answer a query at all, and
/// the Kitty graphics protocol gates its response on exactly that
/// (`stream_terminal.zig` checks `effects.write_pty == null` before encoding
/// one), so an embedder without this could never advertise image support.
///
/// Trampolines are installed unconditionally at producer creation and a null
/// member is a no-op, so callbacks may be set, changed or cleared at any time
/// and take effect on the next fed byte.
///
/// THREADING: every callback fires from inside `feed`, holding the producer's
/// terminal mutex. An implementation MUST NOT call back into the same producer
/// (`feed`, `set_size`, `set_callbacks`, `free`) or it will deadlock, and MUST
/// NOT retain any pointer it is handed.
pub const Callbacks = extern struct {
    userdata: ?*anyopaque = null,

    /// Bytes the terminal is answering the program with — a DECRQM reply, a
    /// Kitty graphics response, an XTVERSION report. The embedder is expected
    /// to write them to whatever carries its input back to the program.
    write_pty: ?WritePtyFn = null,

    /// An OSC 52 clipboard WRITE. Read requests never reach here: the stream
    /// handler refuses them before the effect, so a program cannot use this to
    /// exfiltrate the clipboard.
    clipboard_write: ?ClipboardWriteFn = null,

    pub const WritePtyFn = *const fn (
        ?*Producer,
        ?*anyopaque,
        [*]const u8,
        usize,
    ) callconv(.c) void;

    pub const ClipboardWriteFn = *const fn (
        ?*Producer,
        ?*anyopaque,
        clipboard.Location,
        ?[*]const ClipboardContent,
        usize,
    ) callconv(.c) clipboard.WriteResult;
};

pub const Producer = struct {
    alloc: std.mem.Allocator,
    terminal: *SharedTerminal,
    stream: TerminalStream,
    /// C callbacks, reached from the trampolines below. They recover this
    /// struct with `@fieldParentPtr("stream", …)`, which is sound only because
    /// a Producer is heap-allocated once and never copied or moved afterwards.
    callbacks: Callbacks = .{},

    fn init(
        alloc: std.mem.Allocator,
        config: Config,
    ) std.mem.Allocator.Error!*Producer {
        const self = try alloc.create(Producer);
        errdefer alloc.destroy(self);

        const terminal = try SharedTerminal.init(alloc, .{
            .cols = config.columns,
            .rows = config.rows,
            .max_scrollback = config.max_scrollback,
        });
        errdefer terminal.release();

        var stream = terminal.terminal.vtStream();
        // Installed unconditionally, so a callback set later takes effect on
        // the next fed byte without rebuilding the stream. Each trampoline
        // no-ops when its C member is null, which is the readonly behaviour
        // this replaces.
        stream.handler.effects.write_pty = &writePtyTrampoline;
        stream.handler.effects.clipboard_write = &clipboardWriteTrampoline;

        self.* = .{
            .alloc = alloc,
            .terminal = terminal,
            .stream = stream,
        };
        return self;
    }

    fn deinit(self: *Producer) void {
        const alloc = self.alloc;
        self.stream.deinit();
        self.terminal.release();
        alloc.destroy(self);
    }

    fn feed(self: *Producer, bytes: []const u8) void {
        self.terminal.mutex.lock();
        defer self.terminal.mutex.unlock();
        self.stream.nextSlice(bytes);
    }

    /// Recover the owning producer from a stream handler. Sound because a
    /// Producer is created by `alloc.create` and never copied afterwards.
    fn fromHandler(handler: *TerminalStream.Handler) *Producer {
        const stream_ptr: *TerminalStream = @fieldParentPtr("handler", handler);
        return @fieldParentPtr("stream", stream_ptr);
    }

    fn writePtyTrampoline(handler: *TerminalStream.Handler, data: [:0]const u8) void {
        const self = fromHandler(handler);
        const func = self.callbacks.write_pty orelse return;
        func(self, self.callbacks.userdata, data.ptr, data.len);
    }

    fn clipboardWriteTrampoline(
        handler: *TerminalStream.Handler,
        write: clipboard.Write,
    ) clipboard.WriteResult {
        const self = fromHandler(handler);
        const func = self.callbacks.clipboard_write orelse return .unsupported;

        // OSC 52 produces one representation today, so keep that path
        // allocation-free while still passing a multi-MIME write through
        // whole rather than silently dropping representations.
        var stack: [4]ClipboardContent = undefined;
        const spilled = write.contents.len > stack.len;
        const contents: []ClipboardContent = if (!spilled)
            stack[0..write.contents.len]
        else
            self.terminal.terminal.gpa().alloc(ClipboardContent, write.contents.len) catch
                return .io_error;
        defer if (spilled) self.terminal.terminal.gpa().free(contents);

        for (contents, write.contents) |*out, in| {
            out.* = .{
                .mime_ptr = in.mime.ptr,
                .mime_len = in.mime.len,
                .data_ptr = in.data.ptr,
                .data_len = in.data.len,
            };
        }

        return func(
            self,
            self.callbacks.userdata,
            write.location,
            if (contents.len > 0) contents.ptr else null,
            contents.len,
        );
    }

    /// Resize the canonical terminal in place, reflowing the primary screen.
    ///
    /// This goes straight to Terminal.resize rather than through the VT
    /// handler: the handler's only extra work is the mode-2048 in-band size
    /// report, and a producer's stream uses the readonly effect set (no
    /// write_pty), so that report would be dropped anyway. Embedders own the
    /// write-back path and are expected to report size on it themselves.
    fn setSize(self: *Producer, columns: u16, rows: u16) !void {
        self.terminal.mutex.lock();
        defer self.terminal.mutex.unlock();
        const terminal = &self.terminal.terminal;
        try terminal.resize(terminal.gpa(), columns, rows);
    }
};

pub export fn ghostty_terminal_producer_config_new() Config {
    return .{};
}

pub export fn ghostty_terminal_producer_new(
    config_ptr: ?*const Config,
    out_ptr: ?*?*Producer,
) Result {
    const out = out_ptr orelse return .invalid_input;
    out.* = null;
    const config = config_ptr orelse return .invalid_input;
    if (config.columns == 0 or config.rows == 0) return .invalid_input;

    out.* = Producer.init(state.alloc, config.*) catch return .out_of_memory;
    return .ok;
}

pub export fn ghostty_terminal_producer_retain_terminal(
    producer: ?*Producer,
    out_ptr: ?*?*SharedTerminal,
) Result {
    const out = out_ptr orelse return .invalid_input;
    out.* = null;
    const value = producer orelse return .invalid_input;
    out.* = value.terminal.retain();
    return .ok;
}

pub export fn ghostty_terminal_producer_feed(
    producer: ?*Producer,
    data_ptr: ?[*]const u8,
    len: usize,
) Result {
    const value = producer orelse return .invalid_input;
    const bytes: []const u8 = if (len == 0)
        &.{}
    else
        (data_ptr orelse return .invalid_input)[0..len];
    value.feed(bytes);
    return .ok;
}

pub export fn ghostty_terminal_producer_set_size(
    producer: ?*Producer,
    columns: u16,
    rows: u16,
) Result {
    const value = producer orelse return .invalid_input;
    if (columns == 0 or rows == 0) return .invalid_input;
    value.setSize(columns, rows) catch return .out_of_memory;
    return .ok;
}

/// Install (or clear) the producer's C callbacks.
///
/// A null `callbacks` clears every member, returning the producer to the
/// readonly behaviour it has before this is called. Passing a struct with a
/// null member clears that member alone. Safe to call at any time; the change
/// applies to the next fed byte.
pub export fn ghostty_terminal_producer_set_callbacks(
    producer: ?*Producer,
    callbacks: ?*const Callbacks,
) Result {
    const value = producer orelse return .invalid_input;
    value.terminal.mutex.lock();
    defer value.terminal.mutex.unlock();
    value.callbacks = if (callbacks) |c| c.* else .{};
    return .ok;
}

pub export fn ghostty_terminal_producer_free(producer: ?*Producer) void {
    if (producer) |value| value.deinit();
}

pub export fn ghostty_terminal_release(terminal: ?*SharedTerminal) void {
    if (terminal) |value| value.release();
}

fn expectStructLayout(comptime Zig: type, comptime C: type) !void {
    try std.testing.expectEqual(@sizeOf(Zig), @sizeOf(C));
    try std.testing.expectEqual(@alignOf(Zig), @alignOf(C));
    inline for (std.meta.fields(Zig)) |field| {
        try std.testing.expectEqual(
            @offsetOf(Zig, field.name),
            @offsetOf(C, field.name),
        );
    }
}

test "terminal producer C ABI matches ghostty header" {
    const testing = std.testing;
    const c = @import("ghostty.h");

    try testing.expect(@hasDecl(c, "ghostty_terminal_producer_config_new"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_producer_new"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_producer_retain_terminal"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_producer_feed"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_producer_set_size"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_producer_free"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_producer_set_callbacks"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_release"));
    try testing.expectEqual(
        @sizeOf(c_int),
        @sizeOf(c.ghostty_terminal_producer_result_e),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(Result.ok)),
        @as(c_int, c.GHOSTTY_TERMINAL_PRODUCER_RESULT_OK),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(Result.invalid_input)),
        @as(c_int, c.GHOSTTY_TERMINAL_PRODUCER_RESULT_INVALID_INPUT),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(Result.out_of_memory)),
        @as(c_int, c.GHOSTTY_TERMINAL_PRODUCER_RESULT_OUT_OF_MEMORY),
    );
    try expectStructLayout(Config, c.ghostty_terminal_producer_config_s);
    try expectStructLayout(
        ClipboardContent,
        c.ghostty_terminal_producer_clipboard_content_s,
    );
    try expectStructLayout(
        Callbacks,
        c.ghostty_terminal_producer_callbacks_s,
    );

    // The clipboard enums are shared with the VT handler's own types, so a
    // divergence here would silently mislabel a destination or a verdict.
    try testing.expectEqual(
        @as(c_int, @intFromEnum(clipboard.Location.standard)),
        @as(c_int, c.GHOSTTY_TERMINAL_PRODUCER_CLIPBOARD_STANDARD),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(clipboard.Location.selection)),
        @as(c_int, c.GHOSTTY_TERMINAL_PRODUCER_CLIPBOARD_SELECTION),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(clipboard.Location.primary)),
        @as(c_int, c.GHOSTTY_TERMINAL_PRODUCER_CLIPBOARD_PRIMARY),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(clipboard.WriteResult.success)),
        @as(c_int, c.GHOSTTY_TERMINAL_PRODUCER_CLIPBOARD_SUCCESS),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(clipboard.WriteResult.io_error)),
        @as(c_int, c.GHOSTTY_TERMINAL_PRODUCER_CLIPBOARD_IO_ERROR),
    );
}

test "terminal producer C defaults and validation" {
    const testing = std.testing;
    state.alloc = testing.allocator;

    const defaults = ghostty_terminal_producer_config_new();
    try testing.expectEqual(@as(u16, 80), defaults.columns);
    try testing.expectEqual(@as(u16, 24), defaults.rows);
    try testing.expectEqual(@as(usize, 10_000), defaults.max_scrollback);

    var out: ?*Producer = undefined;
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_new(null, &out),
    );
    try testing.expect(out == null);
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_new(&defaults, null),
    );

    var invalid = defaults;
    invalid.columns = 0;
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_new(&invalid, &out),
    );
    try testing.expect(out == null);
    invalid.columns = defaults.columns;
    invalid.rows = 0;
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_new(&invalid, &out),
    );
    try testing.expect(out == null);

    try testing.expectEqual(Result.ok, ghostty_terminal_producer_new(&defaults, &out));
    const producer = out.?;
    defer ghostty_terminal_producer_free(producer);

    var retained: ?*SharedTerminal = undefined;
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_retain_terminal(null, &retained),
    );
    try testing.expect(retained == null);
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_retain_terminal(producer, null),
    );
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_feed(null, null, 0),
    );
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_feed(producer, null, 1),
    );
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_feed(producer, null, 0),
    );
    ghostty_terminal_producer_free(null);
    ghostty_terminal_release(null);
}

test "terminal producer preserves parser state across feeds" {
    const testing = std.testing;
    const producer = try Producer.init(testing.allocator, .{
        .columns = 8,
        .rows = 3,
    });
    defer producer.deinit();

    producer.feed("\x1b[2;");
    try testing.expectEqual(@as(usize, 0), producer.terminal.terminal.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), producer.terminal.terminal.screens.active.cursor.y);

    producer.feed("3HX");
    try testing.expectEqual(@as(usize, 3), producer.terminal.terminal.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 1), producer.terminal.terminal.screens.active.cursor.y);
    const contents = try producer.terminal.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("\n  X", contents);
}

test "terminal producer feed preserves embedded NUL and explicit length" {
    const testing = std.testing;
    state.alloc = testing.allocator;
    const config: Config = .{
        .columns = 8,
        .rows = 2,
    };
    var producer: ?*Producer = null;
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_new(&config, &producer),
    );
    defer ghostty_terminal_producer_free(producer);

    const bytes = "a\x00bignored";
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_feed(producer, bytes.ptr, 3),
    );
    const contents = try producer.?.terminal.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("ab", contents);
}

test "terminal producer config controls size and scrollback" {
    const testing = std.testing;

    const without_scrollback = try Producer.init(testing.allocator, .{
        .columns = 7,
        .rows = 2,
        .max_scrollback = 0,
    });
    defer without_scrollback.deinit();
    try testing.expectEqual(@as(u16, 7), without_scrollback.terminal.terminal.cols);
    try testing.expectEqual(@as(u16, 2), without_scrollback.terminal.terminal.rows);
    try testing.expect(without_scrollback.terminal.terminal.screens.active.no_scrollback);
    without_scrollback.feed("one\r\ntwo\r\nthree");
    try testing.expectEqual(
        @as(usize, 2),
        without_scrollback.terminal.terminal.screens.active.pages.scrollbar().total,
    );

    const with_scrollback = try Producer.init(testing.allocator, .{
        .columns = 7,
        .rows = 2,
        .max_scrollback = 64 * 1024,
    });
    defer with_scrollback.deinit();
    try testing.expect(!with_scrollback.terminal.terminal.screens.active.no_scrollback);
    with_scrollback.feed("one\r\ntwo\r\nthree");
    try testing.expect(
        with_scrollback.terminal.terminal.screens.active.pages.scrollbar().total > 2,
    );
}

test "terminal producer and retained terminal have independent lifetimes" {
    const testing = std.testing;

    const producer_first = try Producer.init(testing.allocator, .{});
    var retained_after: ?*SharedTerminal = null;
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_retain_terminal(producer_first, &retained_after),
    );
    producer_first.feed("producer first");
    ghostty_terminal_producer_free(producer_first);
    {
        defer ghostty_terminal_release(retained_after);
        retained_after.?.mutex.lock();
        defer retained_after.?.mutex.unlock();
        const contents = try retained_after.?.terminal.plainString(testing.allocator);
        defer testing.allocator.free(contents);
        try testing.expectEqualStrings("producer first", contents);
    }

    const producer_last = try Producer.init(testing.allocator, .{});
    var retained_before: ?*SharedTerminal = null;
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_retain_terminal(producer_last, &retained_before),
    );
    ghostty_terminal_release(retained_before);
    producer_last.feed("producer last");
    const contents = try producer_last.terminal.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("producer last", contents);
    ghostty_terminal_producer_free(producer_last);
}

test "terminal producer partial initialization is allocation safe" {
    const testing = std.testing;
    var observed_success = false;

    for (0..256) |fail_index| {
        var failing = testing.FailingAllocator.init(
            testing.allocator,
            .{ .fail_index = fail_index },
        );
        const producer = Producer.init(failing.allocator(), .{}) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        producer.deinit();
        observed_success = true;
        break;
    }

    try testing.expect(observed_success);
}

test "terminal producer set_size reflows and preserves modes" {
    const testing = std.testing;
    state.alloc = testing.allocator;

    const config: Config = .{ .columns = 10, .rows = 4 };
    var producer: ?*Producer = null;
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_new(&config, &producer),
    );
    defer ghostty_terminal_producer_free(producer);

    // A program that enables mouse reporting once at startup, then prints a
    // line long enough to wrap at 10 columns.
    const prologue = "\x1b[?1000h";
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_feed(producer, prologue.ptr, prologue.len),
    );
    const text = "abcdefghijkl";
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_feed(producer, text.ptr, text.len),
    );

    const terminal = &producer.?.terminal.terminal;
    try testing.expect(terminal.modes.get(.mouse_event_normal));
    {
        const wrapped = try terminal.plainString(testing.allocator);
        defer testing.allocator.free(wrapped);
        try testing.expectEqualStrings("abcdefghij\nkl", wrapped);
    }

    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_set_size(null, 20, 4),
    );
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_set_size(producer, 0, 4),
    );
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_set_size(producer, 20, 0),
    );

    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_set_size(producer, 20, 4),
    );
    try testing.expectEqual(@as(u16, 20), terminal.cols);
    try testing.expectEqual(@as(u16, 4), terminal.rows);

    // The wrapped line reflowed into the wider grid, and the mode the program
    // set once at startup survived — the whole reason this exists instead of
    // recreating the producer.
    const reflowed = try terminal.plainString(testing.allocator);
    defer testing.allocator.free(reflowed);
    try testing.expectEqualStrings("abcdefghijkl", reflowed);
    try testing.expect(terminal.modes.get(.mouse_event_normal));
}

/// Captures what the C callbacks were handed, so the tests below assert on the
/// values that actually crossed the boundary rather than on internal state.
const CaptureCallbacks = struct {
    var written: ?[]u8 = null;
    var userdata: ?*anyopaque = null;
    var producer_seen: ?*Producer = null;
    var clipboard_mime: ?[]u8 = null;
    var clipboard_data: ?[]u8 = null;
    var clipboard_location: clipboard.Location = .standard;
    var clipboard_count: usize = 0;
    var clipboard_verdict: clipboard.WriteResult = .success;

    fn reset() void {
        const alloc = std.testing.allocator;
        if (written) |w| alloc.free(w);
        if (clipboard_mime) |m| alloc.free(m);
        if (clipboard_data) |d| alloc.free(d);
        written = null;
        clipboard_mime = null;
        clipboard_data = null;
        userdata = null;
        producer_seen = null;
        clipboard_count = 0;
        clipboard_verdict = .success;
    }

    fn writePty(
        producer: ?*Producer,
        ud: ?*anyopaque,
        ptr: [*]const u8,
        len: usize,
    ) callconv(.c) void {
        const alloc = std.testing.allocator;
        if (written) |w| alloc.free(w);
        written = alloc.dupe(u8, ptr[0..len]) catch @panic("OOM");
        userdata = ud;
        producer_seen = producer;
    }

    fn clipboardWrite(
        producer: ?*Producer,
        ud: ?*anyopaque,
        location: clipboard.Location,
        contents: ?[*]const ClipboardContent,
        contents_len: usize,
    ) callconv(.c) clipboard.WriteResult {
        const alloc = std.testing.allocator;
        userdata = ud;
        producer_seen = producer;
        clipboard_location = location;
        clipboard_count = contents_len;
        if (contents) |ptr| if (contents_len > 0) {
            const first = ptr[0];
            if (clipboard_mime) |m| alloc.free(m);
            if (clipboard_data) |d| alloc.free(d);
            clipboard_mime = alloc.dupe(u8, first.mime_ptr[0..first.mime_len]) catch
                @panic("OOM");
            clipboard_data = alloc.dupe(u8, first.data_ptr[0..first.data_len]) catch
                @panic("OOM");
        };
        return clipboard_verdict;
    }
};

test "terminal producer answers a query only once write_pty is installed" {
    const testing = std.testing;
    state.alloc = testing.allocator;
    CaptureCallbacks.reset();
    defer CaptureCallbacks.reset();

    const config: Config = .{ .columns = 20, .rows = 4 };
    var out: ?*Producer = null;
    try testing.expectEqual(Result.ok, ghostty_terminal_producer_new(&config, &out));
    const producer = out.?;
    defer ghostty_terminal_producer_free(producer);

    // Before any callback the producer is mute: this is the readonly default
    // every embedder used to be stuck with.
    _ = ghostty_terminal_producer_feed(producer, "\x1b[?7$p", 6);
    try testing.expect(CaptureCallbacks.written == null);

    var sentinel: u8 = 42;
    var callbacks: Callbacks = .{
        .userdata = @ptrCast(&sentinel),
        .write_pty = &CaptureCallbacks.writePty,
    };
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_set_callbacks(producer, &callbacks),
    );

    // DECRQM for wraparound (mode 7, set by default) now round-trips.
    _ = ghostty_terminal_producer_feed(producer, "\x1b[?7$p", 6);
    try testing.expectEqualStrings("\x1B[?7;1$y", CaptureCallbacks.written.?);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), CaptureCallbacks.userdata);
    try testing.expectEqual(producer, CaptureCallbacks.producer_seen);
}

test "terminal producer answers a kitty graphics support query" {
    const testing = std.testing;
    state.alloc = testing.allocator;
    CaptureCallbacks.reset();
    defer CaptureCallbacks.reset();

    const config: Config = .{ .columns = 20, .rows = 4 };
    var out: ?*Producer = null;
    try testing.expectEqual(Result.ok, ghostty_terminal_producer_new(&config, &out));
    const producer = out.?;
    defer ghostty_terminal_producer_free(producer);

    var callbacks: Callbacks = .{ .write_pty = &CaptureCallbacks.writePty };
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_set_callbacks(producer, &callbacks),
    );

    // The support probe every image-capable tool sends before transmitting:
    // a 1x1 RGB direct transmission with a=q. An unanswered probe is read as
    // "this terminal has no image support", which is why a mute producer
    // never sees an image at all.
    const probe = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\";
    _ = ghostty_terminal_producer_feed(producer, probe, probe.len);

    const reply = CaptureCallbacks.written orelse
        return testing.expect(false) catch error.NoKittyResponse;
    try testing.expect(std.mem.startsWith(u8, reply, "\x1b_G"));
    try testing.expect(std.mem.indexOf(u8, reply, "i=31") != null);
    try testing.expect(std.mem.indexOf(u8, reply, "OK") != null);
}

test "terminal producer forwards an OSC 52 write and refuses a read" {
    const testing = std.testing;
    state.alloc = testing.allocator;
    CaptureCallbacks.reset();
    defer CaptureCallbacks.reset();

    const config: Config = .{ .columns = 20, .rows = 4 };
    var out: ?*Producer = null;
    try testing.expectEqual(Result.ok, ghostty_terminal_producer_new(&config, &out));
    const producer = out.?;
    defer ghostty_terminal_producer_free(producer);

    var callbacks: Callbacks = .{
        .write_pty = &CaptureCallbacks.writePty,
        .clipboard_write = &CaptureCallbacks.clipboardWrite,
    };
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_set_callbacks(producer, &callbacks),
    );

    // OSC 52 write: "aGk=" is base64 for "hi".
    const write_seq = "\x1b]52;c;aGk=\x1b\\";
    _ = ghostty_terminal_producer_feed(producer, write_seq, write_seq.len);
    try testing.expectEqual(@as(usize, 1), CaptureCallbacks.clipboard_count);
    try testing.expectEqual(clipboard.Location.standard, CaptureCallbacks.clipboard_location);
    try testing.expectEqualStrings("hi", CaptureCallbacks.clipboard_data.?);

    // A READ request must never reach the callback: the handler drops it
    // before the effect, so a program cannot exfiltrate the clipboard.
    CaptureCallbacks.clipboard_count = 0;
    const read_seq = "\x1b]52;c;?\x1b\\";
    _ = ghostty_terminal_producer_feed(producer, read_seq, read_seq.len);
    try testing.expectEqual(@as(usize, 0), CaptureCallbacks.clipboard_count);
}

test "terminal producer callbacks clear back to readonly" {
    const testing = std.testing;
    state.alloc = testing.allocator;
    CaptureCallbacks.reset();
    defer CaptureCallbacks.reset();

    const config: Config = .{ .columns = 20, .rows = 4 };
    var out: ?*Producer = null;
    try testing.expectEqual(Result.ok, ghostty_terminal_producer_new(&config, &out));
    const producer = out.?;
    defer ghostty_terminal_producer_free(producer);

    var callbacks: Callbacks = .{ .write_pty = &CaptureCallbacks.writePty };
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_set_callbacks(producer, &callbacks),
    );
    _ = ghostty_terminal_producer_feed(producer, "\x1b[?7$p", 6);
    try testing.expect(CaptureCallbacks.written != null);

    // A null pointer restores the readonly default rather than leaving a
    // stale function pointer installed.
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_set_callbacks(producer, null),
    );
    CaptureCallbacks.reset();
    _ = ghostty_terminal_producer_feed(producer, "\x1b[?7$p", 6);
    try testing.expect(CaptureCallbacks.written == null);

    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_set_callbacks(null, &callbacks),
    );
}
