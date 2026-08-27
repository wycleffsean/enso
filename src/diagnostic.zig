const std = @import("std");

pub const Error = error{
    DiagnosticError,
    TooManyDiagnostics,
};

const SourceSpan = struct {
    filepath_buf: [std.Io.Dir.max_path_bytes]u8,
    filepath: []const u8,
    line: usize,
    column: usize,

    pub fn init(line: usize, column: usize, fmt: []const u8, args: anytype) SourceSpan {
        var span: SourceSpan = undefined;

        // we already have max path bytes buffer, technically
        // that could fail but a panic is fine in this case
        span.filepath = std.fmt.bufPrint(&span.filepath_buf, fmt, args) catch unreachable;
        span.line = line;
        span.column = column;

        return span;
    }
};

const Severity = enum {
    debug,
    warn,
    @"error",
};

const Diagnostic = struct {
    severity: Severity,
    source: ?SourceSpan,
    err: ?anyerror,
    message_buf: [100]u8,
    message: []const u8,
};

const DiagnosticContext = struct {
    const max = 100;
    i: u8 = 0,
    diagnostics: [max]Diagnostic = undefined,

    const init: DiagnosticContext = .{};

    fn emit(self: *DiagnosticContext, diag: Diagnostic) Error!void {
        if (self.i < max) {
            self.diagnostics[self.i] = diag;
            self.i += 1;
        } else {
            return error.TooManyDiagnostics;
        }
    }
};

var diagnostic_context: DiagnosticContext = .init;

fn emit(severity: Severity, comptime message_fmt: []const u8, args: anytype, source: ?SourceSpan, err: ?anyerror) Error!void {
    var diag: Diagnostic = undefined;

    diag.severity = severity;
    diag.message = std.fmt.bufPrint(&diag.message_buf, message_fmt, args) catch {};
    diag.source = source;
    diag.err = err;

    try diagnostic_context.emit(diag);

    if (err) |_| return error.DiagnosticError;
}

pub fn debug(comptime message_fmt: []const u8, args: anytype) void {
    emit(.debug, message_fmt, args, null) catch {};
}

pub fn warn(comptime message_fmt: []const u8, args: anytype, source: ?SourceSpan) void {
    emit(.warn, message_fmt, args, source, null) catch {};
}

pub fn fail(err: anyerror, comptime message_fmt: []const u8, args: anytype, source: ?SourceSpan) Error!void {
    try emit(.@"error", message_fmt, args, source, err);
}

pub const DiagnosticFormat = struct {
    diagnostic: Diagnostic,
    source: []const u8,

    fn initReadFile(allocator: std.mem.Allocator, io: std.Io, diagnostic: Diagnostic) !DiagnosticFormat {
        if (diagnostic.source) |source_location| {
            const filepath = source_location.filepath;

            std.debug.assert(std.fs.path.isAbsolute(filepath));

            const dirpath = std.fs.path.dirname(filepath).?; // fair because of the assertion
            const filename = std.fs.path.basename(filepath);

            const dir = try std.Io.Dir.openDirAbsolute(io, dirpath, .{});
            defer dir.close(io);
            const source = try dir.readFileAlloc(io, filename, allocator, .unlimited);

            return .{
                .diagnostic = diagnostic,
                .source = source,
            };
        } else {
            return .{
                .diagnostic = diagnostic,
                .source = "",
            };
        }
    }

    pub fn deinit(self: *const DiagnosticFormat, allocator: std.mem.Allocator) void {
        if (self.diagnostic.source) |_|
            allocator.free(self.source);
    }

    pub fn format(self: *const DiagnosticFormat, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        //ansi escape codes
        const esc = "\x1B";
        const csi = esc ++ "[";

        const ansi_reset = csi ++ "0m";
        const ansi_bold = csi ++ "1m";
        const highlight_red = csi ++ "4:3m" ++ csi ++ "58;2;240;143;104m";
        const highlight_end = csi ++ "59m" ++ csi ++ "4:0m";

        try writer.print("{s}\n", .{self.diagnostic.message});
        if (self.diagnostic.source) |source_location| {
            try writer.print("\n{s}# {s}{s}\n", .{ ansi_bold, source_location.filepath, ansi_reset });
            var iter = std.mem.splitSequence(u8, self.source, "\n");
            var i: usize = 0;
            while (iter.next()) |line| {
                i += 1;
                if (i != source_location.line) continue;
                const raw_index = if (source_location.column > 0) source_location.column - 1 else 0;
                const index = @min(raw_index, line.len);
                const beforeHighlight = line[0..index];
                const highlight = line[beforeHighlight.len..];
                try writer.print("\t{d}: {s}{s}{s}{s}\n", .{ source_location.line, beforeHighlight, highlight_red, highlight, highlight_end });
            }
        }
        try writer.writeAll("\n\n");
    }
};

/// This is usually used inside of a catch, so we forward the error that
/// was captured by the diagnostic
pub fn printDiagnostics(io: std.Io, allocator: std.mem.Allocator) anyerror!void {
    for (0..diagnostic_context.i) |i| {
        const diagnostic = diagnostic_context.diagnostics[i];
        const formatter: DiagnosticFormat = try .initReadFile(allocator, io, diagnostic);
        defer formatter.deinit(allocator);

        var buf: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &buf).interface;
        try formatter.format(&stderr_writer);
        try stderr_writer.flush();

        if (diagnostic.err) |err| return err;
    }
}
