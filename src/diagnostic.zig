const std = @import("std");
const lex = @import("lex.zig");

pub const Location = lex.Location;

pub const Error = error{
    DiagnosticError,
    TooManyDiagnostics,
};

const Severity = enum { debug, warn, @"error" };

const Diagnostic = struct {
    severity: Severity,
    err: ?anyerror,
    /// Stable slice — caller owns the memory for the parser's lifetime.
    filename: ?[]const u8,
    location: ?Location,
    message_buf: [256]u8,
    message: []const u8,
};

const DiagnosticContext = struct {
    const max = 100;
    count: u8 = 0,
    diagnostics: [max]Diagnostic = undefined,

    const init: DiagnosticContext = .{};

    fn emit(self: *DiagnosticContext, diag: Diagnostic) Error!void {
        if (self.count >= max) return error.TooManyDiagnostics;
        self.diagnostics[self.count] = diag;
        self.count += 1;
    }
};

var context: DiagnosticContext = .init;

fn emit(
    severity: Severity,
    err: ?anyerror,
    filename: ?[]const u8,
    location: ?Location,
    comptime fmt: []const u8,
    args: anytype,
) Error!void {
    var diag: Diagnostic = undefined;
    diag.severity = severity;
    diag.err = err;
    diag.filename = filename;
    diag.location = location;
    diag.message = std.fmt.bufPrint(&diag.message_buf, fmt, args) catch msg: {
        const truncated = "(message truncated)";
        @memcpy(diag.message_buf[0..truncated.len], truncated);
        break :msg diag.message_buf[0..truncated.len];
    };
    // Fix up the message slice to point into *this entry's* buffer after copy.
    const msg_len = diag.message.len;
    try context.emit(diag);
    const entry = &context.diagnostics[context.count - 1];
    entry.message = entry.message_buf[0..msg_len];
    if (err != null) return error.DiagnosticError;
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    emit(.debug, null, null, null, fmt, args) catch {};
}

pub fn warn(filename: ?[]const u8, location: ?Location, comptime fmt: []const u8, args: anytype) void {
    emit(.warn, null, filename, location, fmt, args) catch {};
}

pub fn fail(
    err: anyerror,
    filename: ?[]const u8,
    location: ?Location,
    comptime fmt: []const u8,
    args: anytype,
) Error {
    emit(.@"error", err, filename, location, fmt, args) catch |e| return e;
    return error.DiagnosticError;
}

fn renderDiagnostic(
    writer: *std.Io.Writer,
    diag: *const Diagnostic,
    source: ?[]const u8,
) std.Io.Writer.Error!void {
    const esc = "\x1B";
    const csi = esc ++ "[";
    const ansi_reset = csi ++ "0m";
    const bold = csi ++ "1m";
    const highlight = csi ++ "4:3m" ++ csi ++ "58;2;240;143;104m";
    const highlight_end = csi ++ "59m" ++ csi ++ "4:0m";

    const severity_label = switch (diag.severity) {
        .debug => "debug",
        .warn => "warning",
        .@"error" => "error",
    };
    try writer.print("{s}: {s}\n", .{ severity_label, diag.message });

    if (diag.location) |loc| {
        const file = diag.filename orelse "<unknown>";
        try writer.print("{s}{s}:{d}:{d}{s}\n", .{ bold, file, loc.line, loc.col, ansi_reset });

        if (source) |src| {
            var lines = std.mem.splitScalar(u8, src, '\n');
            var n: usize = 0;
            while (lines.next()) |line| {
                n += 1;
                if (n != loc.line) continue;
                const col = if (loc.col > 0) loc.col - 1 else 0;
                const idx = @min(col, line.len);
                try writer.print("\t{d}: {s}{s}{s}{s}\n", .{
                    loc.line,
                    line[0..idx],
                    highlight,
                    line[idx..],
                    highlight_end,
                });
                break;
            }
        }
    }
    try writer.writeByte('\n');
}

/// Print all collected diagnostics to stderr.  Pass `source` when the input
/// was an inline string (no file to read); pass null to read from `filename`.
/// Re-raises the first error diagnostic after rendering.
pub fn printDiagnostics(
    io: std.Io,
    allocator: std.mem.Allocator,
    source: ?[]const u8,
) anyerror!void {
    var buf: [1024]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stderr(), io, &buf);
    const w = &fw.interface;

    var first_err: ?anyerror = null;

    for (context.diagnostics[0..context.count]) |*diag| {
        var owned: ?[]const u8 = null;
        defer if (owned) |o| allocator.free(o);

        const src: ?[]const u8 = if (source != null)
            source
        else if (diag.filename) |path| blk: {
            owned = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch null;
            break :blk owned;
        } else null;

        try renderDiagnostic(w, diag, src);

        if (diag.err) |e| {
            if (first_err == null) first_err = e;
        }
    }

    try fw.interface.flush();
    if (first_err) |e| return e;
}

pub fn reset() void {
    context = .init;
}
