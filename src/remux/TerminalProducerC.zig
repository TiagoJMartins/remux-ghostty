//! Generic libghostty C boundary for producing terminal state without a PTY.
//!
//! A producer owns one shared terminal and one persistent VT stream. It is a
//! writer/lifetime boundary only: rendering and transport remain host concerns.

const std = @import("std");
const global = @import("../global.zig");
const SharedTerminal = @import("Shared.zig");
const clipboard = @import("../terminal/clipboard.zig");
const device_attributes = @import("../terminal/device_attributes.zig");
const TerminalStream = @import("../terminal/stream_terminal.zig").Stream;

pub const Result = enum(c_int) {
    ok,
    invalid_input,
    out_of_memory,
    semantic_failure,
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
/// (`feed`, `resize`, `set_callbacks`, `free`) or it will deadlock, and MUST
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
    ) callconv(.c) clipboard.Write.Status;
};

pub const Producer = struct {
    alloc: std.mem.Allocator,
    terminal: *SharedTerminal,
    stream: TerminalStream,
    /// C callbacks, reached from the trampolines below. They recover this
    /// struct with `@fieldParentPtr("stream", …)`, which is sound only because
    /// a Producer is heap-allocated once and never copied or moved afterwards.
    callbacks: Callbacks = .{},

    /// Set once the terminal may no longer reflect the fed sequence: the
    /// stream reported a semantic failure or a resize failed partway. A
    /// poisoned producer rejects further feeds and resizes; its terminal
    /// stays valid for display until the host replaces the producer.
    poisoned: bool = false,

    fn init(
        alloc: std.mem.Allocator,
        config: Config,
    ) std.mem.Allocator.Error!*Producer {
        const self = try alloc.create(Producer);
        errdefer alloc.destroy(self);

        const terminal = try SharedTerminal.init(global.io(), alloc, .{
            .cols = config.columns,
            .rows = config.rows,
            .max_scrollback_bytes = config.max_scrollback,
        });
        errdefer terminal.release();

        var stream = terminal.terminal.vtStream();
        // Installed unconditionally, so a callback set later takes effect on
        // the next fed byte without rebuilding the stream. Each trampoline
        // no-ops when its C member is null, which is the readonly behaviour
        // this replaces.
        stream.handler.effects.write_pty = &writePtyTrampoline;
        stream.handler.effects.clipboard_write = &clipboardWriteTrampoline;
        stream.handler.effects.device_attributes = &deviceAttributesEffect;

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

    /// Recover the owning producer from a stream handler. Sound because a
    /// Producer is created by `alloc.create` and never copied afterwards.
    fn fromHandler(handler: *TerminalStream.Handler) *Producer {
        const stream_ptr: *TerminalStream = @fieldParentPtr("handler", handler);
        return @fieldParentPtr("stream", stream_ptr);
    }

    /// DA1/DA2 replies, the same values desktop Ghostty sends
    /// (termio/stream_handler.zig): a VT220 with colour, and clipboard access
    /// when the embedder installed `clipboard_write`. The reply still travels
    /// through `write_pty`, so a producer without it stays mute.
    fn deviceAttributesEffect(handler: *TerminalStream.Handler) device_attributes.Attributes {
        const self = fromHandler(handler);
        return .{
            .primary = .{
                .conformance_level = .level_2,
                .features = if (self.callbacks.clipboard_write != null)
                    &.{ .ansi_color, .clipboard }
                else
                    &.{.ansi_color},
            },
            .secondary = .{ .device_type = .vt220, .firmware_version = 10 },
        };
    }

    fn writePtyTrampoline(handler: *TerminalStream.Handler, data: []const u8) void {
        const self = fromHandler(handler);
        const func = self.callbacks.write_pty orelse return;
        func(self, self.callbacks.userdata, data.ptr, data.len);
    }

    fn clipboardWriteTrampoline(
        handler: *TerminalStream.Handler,
        write: clipboard.Write,
    ) void {
        write.reply(statusResult(clipboardWriteStatus(fromHandler(handler), write)));
    }

    fn statusResult(status: clipboard.Write.Status) clipboard.Write.Result {
        return switch (status) {
            .success => .{ .success = .{} },
            .denied => .denied,
            .unsupported => .unsupported,
            .busy => .busy,
            .invalid_data => .invalid_data,
            else => .io_error,
        };
    }

    fn clipboardWriteStatus(self: *Producer, write: clipboard.Write) clipboard.Write.Status {
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

    fn feed(self: *Producer, bytes: []const u8) Result {
        self.terminal.mutex.lockUncancelable(self.terminal.terminal.io());
        defer self.terminal.mutex.unlock(self.terminal.terminal.io());
        return self.feedLocked(bytes);
    }

    fn resize(
        self: *Producer,
        columns: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) Result {
        self.terminal.mutex.lockUncancelable(self.terminal.terminal.io());
        defer self.terminal.mutex.unlock(self.terminal.terminal.io());
        return self.resizeLocked(columns, rows, cell_width_px, cell_height_px);
    }

    /// Resizes and feeds under one hold of the terminal lock, so a renderer
    /// never observes the resized terminal before the bytes written for the
    /// new size.
    fn resizeAndFeed(
        self: *Producer,
        columns: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
        bytes: []const u8,
    ) Result {
        self.terminal.mutex.lockUncancelable(self.terminal.terminal.io());
        defer self.terminal.mutex.unlock(self.terminal.terminal.io());
        const resized = self.resizeLocked(columns, rows, cell_width_px, cell_height_px);
        if (resized != .ok) return resized;
        return self.feedLocked(bytes);
    }

    fn feedLocked(self: *Producer, bytes: []const u8) Result {
        if (self.poisoned) return .semantic_failure;
        self.stream.nextSlice(bytes);
        if (self.stream.handler.semantic_failure) {
            self.poisoned = true;
            return .semantic_failure;
        }
        return .ok;
    }

    fn resizeLocked(
        self: *Producer,
        columns: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) Result {
        if (self.poisoned) return .semantic_failure;
        const terminal = &self.terminal.terminal;
        terminal.resize(terminal.gpa(), .{
            .cols = columns,
            .rows = rows,
            .cell_size_px = .{ .width = cell_width_px, .height = cell_height_px },
        }) catch |err| switch (err) {
            // Rejected before any terminal state changes.
            error.InvalidValue => return .invalid_input,
            // The grid may not match the requested size, so later input
            // written for that size can't be applied safely.
            error.OutOfMemory => {
                self.poisoned = true;
                return .semantic_failure;
            },
        };
        return .ok;
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

    out.* = Producer.init(global.alloc(), config.*) catch return .out_of_memory;
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
    return value.feed(bytes);
}

pub export fn ghostty_terminal_producer_resize(
    producer: ?*Producer,
    columns: u16,
    rows: u16,
    cell_width_px: u32,
    cell_height_px: u32,
) Result {
    const value = producer orelse return .invalid_input;
    if (columns == 0 or rows == 0 or cell_width_px == 0 or cell_height_px == 0) {
        return .invalid_input;
    }
    return value.resize(columns, rows, cell_width_px, cell_height_px);
}

pub export fn ghostty_terminal_producer_resize_and_feed(
    producer: ?*Producer,
    columns: u16,
    rows: u16,
    cell_width_px: u32,
    cell_height_px: u32,
    data_ptr: ?[*]const u8,
    len: usize,
) Result {
    const value = producer orelse return .invalid_input;
    if (columns == 0 or rows == 0 or cell_width_px == 0 or cell_height_px == 0) {
        return .invalid_input;
    }
    const bytes: []const u8 = if (len == 0)
        &.{}
    else
        (data_ptr orelse return .invalid_input)[0..len];
    return value.resizeAndFeed(columns, rows, cell_width_px, cell_height_px, bytes);
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
    value.terminal.mutex.lockUncancelable(value.terminal.terminal.io());
    defer value.terminal.mutex.unlock(value.terminal.terminal.io());
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
    try testing.expect(@hasDecl(c, "ghostty_terminal_producer_resize"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_producer_resize_and_feed"));
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
    try testing.expectEqual(
        @as(c_int, @intFromEnum(Result.semantic_failure)),
        @as(c_int, c.GHOSTTY_TERMINAL_PRODUCER_RESULT_SEMANTIC_FAILURE),
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
        @as(c_int, @intFromEnum(clipboard.Write.Status.success)),
        @as(c_int, c.GHOSTTY_TERMINAL_PRODUCER_CLIPBOARD_SUCCESS),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(clipboard.Write.Status.io_error)),
        @as(c_int, c.GHOSTTY_TERMINAL_PRODUCER_CLIPBOARD_IO_ERROR),
    );
}

test "terminal producer C defaults and validation" {
    const testing = std.testing;

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

    try std.testing.expectEqual(Result.ok, producer.feed("\x1b[2;"));
    try testing.expectEqual(@as(usize, 0), producer.terminal.terminal.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), producer.terminal.terminal.screens.active.cursor.y);

    try std.testing.expectEqual(Result.ok, producer.feed("3HX"));
    try testing.expectEqual(@as(usize, 3), producer.terminal.terminal.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 1), producer.terminal.terminal.screens.active.cursor.y);
    const contents = try producer.terminal.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("\n  X", contents);
}

test "terminal producer feed preserves embedded NUL and explicit length" {
    const testing = std.testing;
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
    try std.testing.expectEqual(Result.ok, without_scrollback.feed("one\r\ntwo\r\nthree"));
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
    try std.testing.expectEqual(Result.ok, with_scrollback.feed("one\r\ntwo\r\nthree"));
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
    try std.testing.expectEqual(Result.ok, producer_first.feed("producer first"));
    ghostty_terminal_producer_free(producer_first);
    {
        defer ghostty_terminal_release(retained_after);
        retained_after.?.mutex.lockUncancelable(testing.io);
        defer retained_after.?.mutex.unlock(testing.io);
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
    try std.testing.expectEqual(Result.ok, producer_last.feed("producer last"));
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

test "terminal producer resize keeps ownership, parser state and pixel geometry" {
    const testing = std.testing;
    const producer = try Producer.init(testing.allocator, .{ .columns = 8, .rows = 3 });
    defer producer.deinit();
    var retained: ?*SharedTerminal = null;
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_retain_terminal(producer, &retained),
    );
    defer ghostty_terminal_release(retained);

    // A sequence split across a resize still completes on the same parser.
    try testing.expectEqual(Result.ok, producer.feed("\x1b[2;"));
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_resize(producer, 12, 4, 9, 18),
    );
    try testing.expect(retained.? == producer.terminal);
    try testing.expectEqual(Result.ok, producer.feed("3HX"));

    const terminal = &retained.?.terminal;
    try testing.expectEqual(@as(u16, 12), terminal.cols);
    try testing.expectEqual(@as(u16, 4), terminal.rows);
    try testing.expectEqual(@as(u32, 108), terminal.width_px);
    try testing.expectEqual(@as(u32, 72), terminal.height_px);
    const contents = try terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("\n  X", contents);

    // A same-size resize still applies new cell pixel geometry.
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_resize(producer, 12, 4, 10, 20),
    );
    try testing.expectEqual(@as(u32, 120), terminal.width_px);
    try testing.expectEqual(@as(u32, 80), terminal.height_px);
}

test "terminal producer resize validates input without poisoning" {
    const testing = std.testing;
    const producer = try Producer.init(testing.allocator, .{ .columns = 8, .rows = 3 });
    defer producer.deinit();

    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_resize(null, 8, 3, 9, 18),
    );
    for ([_][4]u32{
        .{ 0, 3, 9, 18 },
        .{ 8, 0, 9, 18 },
        .{ 8, 3, 0, 18 },
        .{ 8, 3, 9, 0 },
    }) |args| {
        try testing.expectEqual(
            Result.invalid_input,
            ghostty_terminal_producer_resize(
                producer,
                @intCast(args[0]),
                @intCast(args[1]),
                args[2],
                args[3],
            ),
        );
    }
    try testing.expectEqual(@as(u16, 8), producer.terminal.terminal.cols);
    try testing.expectEqual(@as(u16, 3), producer.terminal.terminal.rows);
    try testing.expectEqual(Result.ok, producer.feed("still live"));
}

test "terminal producer failed resize rejects later mutations" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const producer = try Producer.init(failing.allocator(), .{ .columns = 8, .rows = 3 });
    defer producer.deinit();
    try testing.expectEqual(Result.ok, producer.feed("before"));

    failing.fail_index = failing.alloc_index;
    try testing.expectEqual(
        Result.semantic_failure,
        ghostty_terminal_producer_resize(producer, 1000, 1000, 9, 18),
    );
    failing.fail_index = std.math.maxInt(usize);

    try testing.expectEqual(Result.semantic_failure, producer.feed("after"));
    try testing.expectEqual(
        Result.semantic_failure,
        ghostty_terminal_producer_resize(producer, 8, 3, 9, 18),
    );

    // The terminal stays readable for display; it just doesn't advance.
    const contents = try producer.terminal.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("before", contents);
}

test "terminal producer reports a stream semantic failure and stays poisoned" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const producer = try Producer.init(failing.allocator(), .{ .columns = 10, .rows = 2 });
    defer producer.deinit();

    // Setting the title is a terminal-owned update; force its allocation
    // to fail, as upstream's stream_terminal test does.
    failing.fail_index = failing.alloc_index;
    try testing.expectEqual(
        Result.semantic_failure,
        producer.feed("\x1B]2;unavailable\x1B\\"),
    );
    failing.fail_index = std.math.maxInt(usize);

    try testing.expectEqual(Result.semantic_failure, producer.feed("ignored"));
    try testing.expectEqual(
        Result.semantic_failure,
        ghostty_terminal_producer_resize(producer, 10, 2, 9, 18),
    );
    const contents = try producer.terminal.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("", contents);
}

test "terminal producer resize and feed applies content written for the new size" {
    const testing = std.testing;
    const producer = try Producer.init(testing.allocator, .{ .columns = 8, .rows = 3 });
    defer producer.deinit();
    var retained: ?*SharedTerminal = null;
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_retain_terminal(producer, &retained),
    );
    defer ghostty_terminal_release(retained);

    // A sequence split before the call completes on the same parser.
    try testing.expectEqual(Result.ok, producer.feed("\x1b[3;"));
    const repaint = "5Hnew";
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_resize_and_feed(producer, 12, 4, 9, 18, repaint.ptr, repaint.len),
    );

    const terminal = &retained.?.terminal;
    try testing.expectEqual(@as(u16, 12), terminal.cols);
    try testing.expectEqual(@as(u16, 4), terminal.rows);
    try testing.expectEqual(@as(u32, 108), terminal.width_px);
    try testing.expectEqual(@as(u32, 72), terminal.height_px);
    const contents = try terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("\n\n    new", contents);

    // Empty data resizes only.
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_resize_and_feed(producer, 12, 4, 10, 20, null, 0),
    );
    try testing.expectEqual(@as(u32, 120), terminal.width_px);
}

test "terminal producer resize and feed validates input without changing the terminal" {
    const testing = std.testing;
    const producer = try Producer.init(testing.allocator, .{ .columns = 8, .rows = 3 });
    defer producer.deinit();
    try testing.expectEqual(Result.ok, producer.feed("before"));

    const data = "after";
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_resize_and_feed(null, 8, 3, 9, 18, data.ptr, data.len),
    );
    for ([_][4]u32{
        .{ 0, 3, 9, 18 },
        .{ 8, 0, 9, 18 },
        .{ 8, 3, 0, 18 },
        .{ 8, 3, 9, 0 },
    }) |args| {
        try testing.expectEqual(
            Result.invalid_input,
            ghostty_terminal_producer_resize_and_feed(
                producer,
                @intCast(args[0]),
                @intCast(args[1]),
                args[2],
                args[3],
                data.ptr,
                data.len,
            ),
        );
    }
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_resize_and_feed(producer, 12, 4, 9, 18, null, 1),
    );

    try testing.expectEqual(@as(u16, 8), producer.terminal.terminal.cols);
    try testing.expectEqual(@as(u16, 3), producer.terminal.terminal.rows);
    const contents = try producer.terminal.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("before", contents);
    try testing.expectEqual(Result.ok, producer.feed(" still live"));
}

test "terminal producer resize and feed feeds nothing when the resize fails" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const producer = try Producer.init(failing.allocator(), .{ .columns = 8, .rows = 3 });
    defer producer.deinit();
    try testing.expectEqual(Result.ok, producer.feed("before"));

    const data = "\x1b[H\x1b[2Jafter";
    failing.fail_index = failing.alloc_index;
    try testing.expectEqual(
        Result.semantic_failure,
        ghostty_terminal_producer_resize_and_feed(producer, 1000, 1000, 9, 18, data.ptr, data.len),
    );
    failing.fail_index = std.math.maxInt(usize);

    try testing.expectEqual(Result.semantic_failure, producer.feed("ignored"));
    try testing.expectEqual(
        Result.semantic_failure,
        ghostty_terminal_producer_resize_and_feed(producer, 8, 3, 9, 18, data.ptr, data.len),
    );
    const contents = try producer.terminal.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("before", contents);
}

test "terminal producer resize and feed poisons on a feed failure after the resize" {
    const testing = std.testing;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const producer = try Producer.init(failing.allocator(), .{ .columns = 10, .rows = 2 });
    defer producer.deinit();

    // A same-size resize allocates nothing, so the forced failure lands on the
    // title update in the feed, as in the plain feed test above.
    const data = "\x1B]2;unavailable\x1B\\";
    failing.fail_index = failing.alloc_index;
    try testing.expectEqual(
        Result.semantic_failure,
        ghostty_terminal_producer_resize_and_feed(producer, 10, 2, 11, 22, data.ptr, data.len),
    );
    failing.fail_index = std.math.maxInt(usize);

    // The resize applied before the feed failed.
    try testing.expectEqual(@as(u32, 110), producer.terminal.terminal.width_px);
    try testing.expectEqual(Result.semantic_failure, producer.feed("ignored"));
}

test "terminal producer resize and feed is never observed between its steps" {
    const testing = std.testing;
    const producer = try Producer.init(testing.allocator, .{
        .columns = 10,
        .rows = 3,
        .max_scrollback = 0,
    });
    defer producer.deinit();
    try testing.expectEqual(Result.ok, producer.feed("ten"));

    // Plays the renderer: takes the terminal lock and checks that the content
    // on screen is the content written for the size on screen.
    const Observer = struct {
        shared: *SharedTerminal,
        stop: std.atomic.Value(bool) = .init(false),
        observed: std.atomic.Value(usize) = .init(0),
        mismatches: std.atomic.Value(usize) = .init(0),

        fn run(self: *@This()) void {
            const io = self.shared.terminal.io();
            while (!self.stop.load(.acquire)) {
                self.shared.mutex.lockUncancelable(io);
                defer self.shared.mutex.unlock(io);
                const contents = self.shared.terminal.plainString(std.testing.allocator) catch continue;
                defer std.testing.allocator.free(contents);
                const expected: []const u8 = if (self.shared.terminal.cols == 10) "ten" else "twelve";
                if (!std.mem.eql(u8, contents, expected)) _ = self.mismatches.fetchAdd(1, .monotonic);
                _ = self.observed.fetchAdd(1, .monotonic);
            }
        }
    };
    var observer: Observer = .{ .shared = producer.terminal };
    const thread = try std.Thread.spawn(.{}, Observer.run, .{&observer});
    // A failed assertion must not free the producer under the running observer.
    errdefer {
        observer.stop.store(true, .release);
        thread.join();
    }
    while (observer.observed.load(.monotonic) == 0) {}

    const twelve = "\x1b[H\x1b[2Jtwelve";
    const ten = "\x1b[H\x1b[2Jten";
    for (0..2_000) |_| {
        try testing.expectEqual(
            Result.ok,
            ghostty_terminal_producer_resize_and_feed(producer, 12, 3, 9, 18, twelve.ptr, twelve.len),
        );
        try testing.expectEqual(
            Result.ok,
            ghostty_terminal_producer_resize_and_feed(producer, 10, 3, 9, 18, ten.ptr, ten.len),
        );
    }
    observer.stop.store(true, .release);
    thread.join();

    try testing.expect(observer.observed.load(.monotonic) > 0);
    try testing.expectEqual(@as(usize, 0), observer.mismatches.load(.monotonic));
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
    var clipboard_verdict: clipboard.Write.Status = .success;

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
    ) callconv(.c) clipboard.Write.Status {
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

test "terminal producer answers DA1, DA2 and XTVERSION through write_pty" {
    const testing = std.testing;

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

    _ = ghostty_terminal_producer_feed(producer, "\x1b[c", 3);
    try testing.expectEqualStrings("\x1B[?62;22c", CaptureCallbacks.written.?);
    _ = ghostty_terminal_producer_feed(producer, "\x1b[>c", 4);
    try testing.expectEqualStrings("\x1B[>1;10;0c", CaptureCallbacks.written.?);
    _ = ghostty_terminal_producer_feed(producer, "\x1b[>q", 4);
    try testing.expect(std.mem.startsWith(u8, CaptureCallbacks.written.?, "\x1BP>|"));
}

test "terminal producer answers a kitty graphics support query" {
    const testing = std.testing;
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
