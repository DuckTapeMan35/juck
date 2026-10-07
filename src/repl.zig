const std = @import("std");
const Io = std.Io;
const reader = @import("reader");
const ast = @import("ast");
const analyzer = @import("analyzer");
const interpreter = @import("interpreter");
const printer = @import("printer");
const unparse = @import("unparse");
const modules = @import("modules");

const Allocator = std.mem.Allocator;
const Writer = Io.Writer;

const help =
    \\Enter one form at a time; it can span several lines.
    \\  ["def", {"name": "x", "type": "i64"}, 1]
    \\  ["+", "x", 1]
    \\A definition can be entered again with the same type to replace it.
    \\Commands:
    \\  :help   show this message
    \\  :expand FORM   show what FORM expands to, without running it
    \\  :quit   leave (or Ctrl-D)
    \\
;

/// A file to load before the first prompt.
pub const File = struct { name: []const u8, src: []const u8 };

pub fn run(io: Io, alloc: Allocator, out: *Writer, file: ?File) !void {
    const program = try modules.Program.create(alloc, io, out);
    if (file) |f| {
        _ = program.load_root(f.name, f.src) catch |err| return fail(program, err);
        program.check() catch |err| return fail(program, err);
        program.run() catch |err| return fail(program, err);
    } else {
        _ = try program.empty_root();
    }
    var repl: Repl = .{ .alloc = alloc, .out = out, .program = program };

    try out.writeAll("juck REPL; :help for help, :quit to leave\n");

    var in_buf: [64 * 1024]u8 = undefined;
    var in_reader = Io.File.stdin().reader(io, &in_buf);
    const in = &in_reader.interface;

    var pending: std.ArrayList(u8) = .empty;
    while (true) {
        if (pending.items.len == 0) {
            try out.print("juck[{d}]> ", .{repl.count});
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
                } else if (std.mem.startsWith(u8, trimmed, ":expand ")) {
                    try repl.eval(try alloc.dupe(u8, trimmed[":expand ".len..]), .expand);
                } else {
                    try out.print("unknown command {s}; try :help\n", .{trimmed});
                }
                try out.flush();
                continue;
            }
        }

        try pending.appendSlice(alloc, line);
        try pending.append(alloc, '\n');
        if (!is_complete(pending.items)) continue;

        const entry = try alloc.dupe(u8, pending.items);
        pending.clearRetainingCapacity();
        try repl.eval(entry, .run);
        try out.flush();
    }
    try out.writeAll("\n");
}

fn fail(program: *modules.Program, err: anyerror) anyerror {
    switch (err) {
        error.SyntaxError, error.ImportFailed, error.AnalysisFailed, error.TypeError, error.RuntimeError => {
            std.debug.print("{f}\n", .{program.diag});
            return error.Reported;
        },
        else => return err,
    }
}

const Repl = struct {
    alloc: Allocator,
    out: *Writer,
    program: *modules.Program,
    /// How many inputs there have been; input N is named [N] in errors.
    count: u32 = 0,

    fn eval(self: *Repl, entry: []const u8, mode: enum { run, expand }) !void {
        const p = self.program;
        const name = try std.fmt.allocPrint(self.alloc, "[{d}]", .{self.count});
        self.count += 1;
        const offset = try p.add_input(name, entry);

        const value = reader.read_at(entry, offset, self.alloc, &p.diag) catch |err| {
            if (err != error.InvalidInput) return err;
            p.diag.file = name;
            return self.report(name);
        };

        p.import_into_root(value) catch |err| switch (err) {
            error.ImportFailed, error.SyntaxError, error.AnalysisFailed => return self.report(name),
            else => return err,
        };

        const item = try self.alloc.create(ast.TopLevel);
        item.* = analyzer.analyze_form(&p.sources, value, self.alloc, &p.diag, p.options()) catch |err| {
            if (err != error.AnalysisFailed) return err;
            return self.report(name);
        };

        if (mode == .expand) {
            try printer.write_json_value(self.out, try unparse.top_level(self.alloc, item.*, try p.root_aliases()));
            return self.out.writeByte('\n');
        }

        // What the name meant before, in case running the new definition
        // fails and it has to be undone.
        const defined: ?[]const u8 = switch (item.*) {
            .def => |d| d.name,
            .@"fn" => |f| f.name,
            .macro => |m| m.name,
            .import, .expr => null,
        };
        const previous = if (defined) |n| p.checker.globals.get(n) else null;

        const t = p.checker.check_form(&p.sources, item.*, &p.diag) catch |err| {
            if (err != error.TypeError) return err;
            return self.report(name);
        };

        const result = p.interpreter.run_form(&p.sources, item, &p.diag) catch |err| {
            if (err != error.RuntimeError) return err;
            if (defined) |n| p.checker.restore(n, previous);
            return self.report(name);
        };

        // Show the value of an expression, unless it's null (like the
        // result of print).
        const v = result orelse return;
        const ty = t.?;
        if (ty == .null) return;
        if (ty == .@"fn") return self.out.print("<function {f}>\n", .{ty});
        try interpreter.write_value(self.out, v);
        try self.out.writeByte('\n');
    }

    /// Reports the program's last error. Errors in the current input are
    /// shown without its name; errors elsewhere (an earlier input, or an
    /// imported module) say where they are.
    fn report(self: *Repl, current: []const u8) !void {
        const d = self.program.diag;
        if (eql(d.file, current)) {
            try self.out.print("error at {d}:{d}: {s}\n", .{ d.line, d.column, d.message });
        } else {
            try self.out.print("error in {f}\n", .{d});
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
