const std = @import("std");
const Io = std.Io;
const reader = @import("reader");
const ast = @import("ast");
const analyzer = @import("analyzer");
const checker = @import("checker");
const interpreter = @import("interpreter");

const Allocator = std.mem.Allocator;
const Writer = Io.Writer;

const help =
    \\Enter one form at a time; it can span several lines.
    \\  ["def", {"name": "x", "type": "i64"}, 1]
    \\  ["+", "x", 1]
    \\A definition can be entered again with the same type to replace it.
    \\Commands:
    \\  :help   show this message
    \\  :quit   leave (or Ctrl-D)
    \\
;

/// A file to load before the first prompt.
pub const File = struct { src: []const u8, program: ast.Program };

pub fn run(io: Io, alloc: Allocator, out: *Writer, file: ?File) !void {
    var repl: Repl = .{
        .alloc = alloc,
        .out = out,
        .checker = .{ .src = "", .alloc = alloc, .diag = null },
        .interpreter = .{ .alloc = alloc, .out = out },
    };

    if (file) |f| {
        if (!try repl.load(f)) return error.InvalidInput;
    }

    try out.writeAll("juck REPL; :help for help, :quit to leave\n");

    var in_buf: [64 * 1024]u8 = undefined;
    var in_reader = Io.File.stdin().reader(io, &in_buf);
    const in = &in_reader.interface;

    var pending: std.ArrayList(u8) = .empty;
    while (true) {
        if (pending.items.len == 0) {
            try out.print("juck[{d}]> ", .{repl.entries.items.len});
        } else {
            try out.writeAll("   ...> ");
        }
        try out.flush();

        const line = (try in.takeDelimiter('\n')) orelse break; // Ctrl-D
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (pending.items.len == 0) {
            if (trimmed.len == 0) continue;
            if (trimmed[0] == ':') {
                if (eql(trimmed, ":quit") or eql(trimmed, ":q")) break;
                if (eql(trimmed, ":help") or eql(trimmed, ":h")) {
                    try out.writeAll(help);
                } else {
                    try out.print("unknown command {s}; try :help\n", .{trimmed});
                }
                continue;
            }
        }

        try pending.appendSlice(alloc, line);
        try pending.append(alloc, '\n');
        if (!is_complete(pending.items)) continue;

        const entry = try alloc.dupe(u8, pending.items);
        pending.clearRetainingCapacity();
        try repl.eval(entry);
        try out.flush();
    }
    try out.writeAll("\n");
}

const Repl = struct {
    alloc: Allocator,
    out: *Writer,
    checker: checker.Session,
    interpreter: interpreter.Session,

    /// Everything entered so far, one entry after another. Positions in
    /// the AST are offsets into this text, so errors can be traced back to
    /// the entry they came from, even when they happen later (an error in
    /// a function defined three inputs ago)
    text: std.ArrayList(u8) = .empty,
    /// The line of text each entry starts on
    entries: std.ArrayList(u32) = .empty,

    /// Loads a file's program. Returns false if it failed.
    fn load(self: *Repl, f: File) !bool {
        _ = try self.add_entry(f.src);
        var diag: reader.Diagnostic = undefined;
        self.checker.check_program(self.text.items, f.program, &diag) catch |err| {
            if (err != error.TypeError) return err;
            try self.report(diag);
            return false;
        };
        self.interpreter.run_program(self.text.items, f.program, &diag) catch |err| {
            if (err != error.RuntimeError) return err;
            try self.report(diag);
            return false;
        };
        return true;
    }

    /// Appends src to the session text, returning its offset.
    fn add_entry(self: *Repl, src: []const u8) !u32 {
        const offset: u32 = @intCast(self.text.items.len);
        try self.entries.append(self.alloc, @intCast(std.mem.count(u8, self.text.items, "\n") + 1));
        try self.text.appendSlice(self.alloc, src);
        if (src.len == 0 or src[src.len - 1] != '\n') try self.text.append(self.alloc, '\n');
        return offset;
    }

    fn eval(self: *Repl, entry: []const u8) !void {
        const offset = try self.add_entry(entry);
        var diag: reader.Diagnostic = undefined;

        const value = reader.read_at(entry, offset, self.alloc, &diag) catch |err| {
            if (err != error.InvalidInput) return err;
            // The reader reports positions relative to the entry itself
            return self.out.print("error at {d}:{d}: {s}\n", .{ diag.line, diag.column, diag.message });
        };

        const item = try self.alloc.create(ast.TopLevel);
        item.* = analyzer.analyze_form(self.text.items, value, self.alloc, &diag) catch |err| {
            if (err != error.AnalysisFailed) return err;
            return self.report(diag);
        };

        // What the name meant before, in case running the new definition
        // fails and it has to be undone.
        const name: ?[]const u8 = switch (item.*) {
            .def => |d| d.name,
            .@"fn" => |f| f.name,
            .expr => null,
        };
        const previous = if (name) |n| self.checker.globals.get(n) else null;

        const t = self.checker.check_form(self.text.items, item.*, &diag) catch |err| {
            if (err != error.TypeError) return err;
            return self.report(diag);
        };

        const result = self.interpreter.run_form(self.text.items, item, &diag) catch |err| {
            if (err != error.RuntimeError) return err;
            if (name) |n| self.checker.restore(n, previous);
            return self.report(diag);
        };

        // Show the value of an expression, unless it's null (like the result of print)
        const v = result orelse return;
        const ty = t.?;
        if (ty == .null) return;
        if (ty == .@"fn") return self.out.print("<function {f}>\n", .{ty});
        try interpreter.write_value(self.out, v);
        try self.out.writeByte('\n');
    }

    /// Reports an error whose line counts from the start of the session
    /// text, as a line within the entry it belongs to
    fn report(self: *Repl, d: reader.Diagnostic) !void {
        var i = self.entries.items.len - 1;
        while (i > 0 and self.entries.items[i] > d.line) i -= 1;
        const line = d.line - self.entries.items[i] + 1;
        if (i == self.entries.items.len - 1) {
            try self.out.print("error at {d}:{d}: {s}\n", .{ line, d.column, d.message });
        } else {
            try self.out.print("error in [{d}] at {d}:{d}: {s}\n", .{ i, line, d.column, d.message });
        }
    }
};

/// Whether text holds a complete value: every bracket is closed, and
/// no string or block comment is left open. Unbalanced closing brackets
/// count as complete, so the reader can report them.
fn is_complete(text: []const u8) bool {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '"' => {
                i += 1;
                while (i < text.len and text[i] != '"') : (i += 1) {
                    if (text[i] == '\\') i += 1;
                }
                if (i >= text.len) return false; // string still open
            },
            '/' => if (i + 1 < text.len and text[i + 1] == '/') {
                while (i < text.len and text[i] != '\n') i += 1;
            } else if (i + 1 < text.len and text[i + 1] == '*') {
                const end = std.mem.indexOfPos(u8, text, i + 2, "*/") orelse return false;
                i = end + 1;
            },
            '[', '{' => depth += 1,
            ']', '}' => depth -= 1,
            else => {},
        }
    }
    return depth <= 0;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test is_complete {
    try std.testing.expect(is_complete("[1, 2]\n"));
    try std.testing.expect(is_complete("42\n"));
    try std.testing.expect(!is_complete("[1,\n"));
    try std.testing.expect(!is_complete("[\"]\n"));
    try std.testing.expect(is_complete("[\"]\"]\n"));
    try std.testing.expect(!is_complete("[1 /* ] \n"));
    try std.testing.expect(is_complete("[1 // ]\n]\n"));
    try std.testing.expect(is_complete("]\n"));
}
