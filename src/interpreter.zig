const std = @import("std");
const reader = @import("reader");
const ast = @import("ast");
const analyzer = @import("analyzer");
const printer = @import("printer");
const Builtin = @import("builtins").Builtin;
const checker = @import("checker");

const Allocator = std.mem.Allocator;
const Diagnostic = reader.Diagnostic;
const Writer = std.Io.Writer;

pub const Error = error{RuntimeError} || Allocator.Error || Writer.Error;

/// A runtime value. Which variant an expression produces is fixed by its
/// type, so the interpreter never has to check it
pub const Value = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    null,
    str: []const u8,
    data: reader.Value,
    func: *const Closure,
};

/// A function value: the code, plus the local variables it captured
pub const Closure = struct {
    lambda: *const ast.Lambda,
    env: ?*const Env,
};

/// Local variables, as a linked list from innermost outwards. A closure
/// keeps a pointer to the list as it was when the closure was created.
/// Names never shadow, so the first match is the only one.
pub const Env = struct {
    name: []const u8,
    value: Value,
    parent: ?*const Env,
};

pub const Options = struct {
    /// Maximum depth of nested function calls before stopping with an
    /// error, instead of overflowing the stack
    max_call_depth: u32 = 10_000,
    /// The interpreter runs on its own thread with a stack this big, so
    /// max_call_depth nested calls fit even in Debug builds, where each
    /// call uses a lot of stack. Only the part actually used is touched
    stack_size: usize = 1024 * 1024 * 1024,
    /// Where generated names (gensym, tmp# in templates) are recorded,
    /// so the analyzer accepts them. Without it, generating names is an error.
    gensyms: ?*analyzer.Gensyms = null,
    /// Macros available to code run by eval.
    macros: ?analyzer.MacroHost = null,
};

/// Runs `program`, writing `print` output to `out`. On a runtime error,
/// fills `diag` if given, otherwise prints it.
pub fn run(
    src: []const u8,
    program: ast.Program,
    alloc: Allocator,
    out: *Writer,
    diag: ?*Diagnostic,
    options: Options,
) Error!void {
    var session: Session = .{ .src = src, .alloc = alloc, .out = out, .diag = diag, .options = options };
    try session.run_program(src, program, diag);
}

/// The interpreter's state: global values. `run` uses one for a single
/// program; the REPL keeps one alive and feeds it one form at a time.
pub const Session = struct {
    src: []const u8 = "",
    alloc: Allocator,
    out: *Writer,
    diag: ?*Diagnostic = null,
    options: Options = .{},

    globals: std.StringHashMapUnmanaged(Value) = .empty,
    depth: u32 = 0,

    /// Runs a whole program.
    pub fn run_program(self: *Session, src: []const u8, program: ast.Program, diag: ?*Diagnostic) Error!void {
        _ = try self.on_big_stack(src, diag, .{ .program = program });
    }

    /// Calls a function value with already-evaluated arguments (used to run
    /// macros). pos is where errors in the call itself are reported.
    pub fn apply(self: *Session, src: []const u8, f: *const Closure, args: []const Value, pos: u32, diag: ?*Diagnostic) Error!Value {
        return (try self.on_big_stack(src, diag, .{ .apply = .{ .f = f, .args = args, .pos = pos } })).?;
    }

    /// Runs one more top-level form (used by the REPL). A definition
    /// replaces any earlier one with the same name; functions look up
    /// globals when they are called, so they see the new definition.
    /// Returns the value of an expression form, or null for a definition.
    /// item must stay alive as long as the session: closures point into it.
    pub fn run_form(self: *Session, src: []const u8, item: *const ast.TopLevel, diag: ?*Diagnostic) Error!?Value {
        return self.on_big_stack(src, diag, .{ .form = item });
    }

    const Job = union(enum) {
        program: ast.Program,
        form: *const ast.TopLevel,
        apply: struct { f: *const Closure, args: []const Value, pos: u32 },
    };

    /// Runs job on a thread with a stack of options.stack_size.
    fn on_big_stack(self: *Session, src: []const u8, diag: ?*Diagnostic, job: Job) Error!?Value {
        const saved = .{ self.src, self.diag, self.depth };
        defer self.src, self.diag, self.depth = saved;
        self.src = src;
        self.diag = diag;
        self.depth = 0;
        var result: Error!?Value = null;
        const thread = std.Thread.spawn(.{ .stack_size = self.options.stack_size }, run_job, .{ self, job, &result }) catch
            return self.do_job(job); // no thread available: run here, with the normal stack
        thread.join();
        return result;
    }

    fn run_job(self: *Session, job: Job, result: *Error!?Value) void {
        result.* = self.do_job(job);
    }

    fn do_job(self: *Session, job: Job) Error!?Value {
        switch (job) {
            .program => |program| {
                try self.run_program_here(program);
                return null;
            },
            .form => |item| switch (item.*) {
                .def => |d| {
                    try self.globals.put(self.alloc, d.name, try self.eval(d.value, null));
                    return null;
                },
                .@"fn" => |*f| {
                    try self.globals.put(self.alloc, f.name, try self.closure(&f.lambda, null));
                    return null;
                },
                .macro => return null,
                .expr => |e| return try self.eval(e, null),
            },
            .apply => |a| return try self.apply_closure(a.pos, a.f, a.args),
        }
    }

    fn fail(self: *Session, pos: u32, comptime fmt: []const u8, args: anytype) Error {
        const message = try std.fmt.allocPrint(self.alloc, fmt, args);
        const d = analyzer.diagnostic_at(self.src, pos, message);
        if (self.diag) |out| {
            out.* = d;
        } else {
            std.debug.print("runtime error at {d}:{d}: {s}\n", .{ d.line, d.column, d.message });
        }
        return error.RuntimeError;
    }

    // program
    fn run_program_here(self: *Session, program: ast.Program) Error!void {
        // Functions are known to the whole program (the checker allows
        // bodies to call functions defined later), so they all exist before anything runs
        for (program.items) |*item| {
            switch (item.*) {
                .@"fn" => |*f| try self.globals.put(self.alloc, f.name, try self.closure(&f.lambda, null)),
                else => {},
            }
        }

        // Then the top-level forms, in order.
        for (program.items) |item| {
            switch (item) {
                .def => |d| try self.globals.put(self.alloc, d.name, try self.eval(d.value, null)),
                .@"fn", .macro => {},
                .expr => |e| _ = try self.eval(e, null),
            }
        }
    }

    fn closure(self: *Session, lambda: *const ast.Lambda, env: ?*const Env) Error!Value {
        const c = try self.alloc.create(Closure);
        c.* = .{ .lambda = lambda, .env = env };
        return .{ .func = c };
    }

    fn bind(self: *Session, env: ?*const Env, name: []const u8, value: Value) Error!*const Env {
        const e = try self.alloc.create(Env);
        e.* = .{ .name = name, .value = value, .parent = env };
        return e;
    }

    // expressions
    fn eval(self: *Session, e: ast.Expr, env: ?*const Env) Error!Value {
        return switch (e.kind) {
            .int => |i| .{ .int = i },
            .float => |f| .{ .float = f },
            .bool => |b| .{ .bool = b },
            .null => .null,
            .str => |s| .{ .str = s },
            .data => |d| .{ .data = d },
            .ref => |name| self.lookup(e.pos, name, env),
            .call => |c| self.call(e.pos, c, env),
            .@"if" => |i| {
                const cond = try self.eval(i.cond.*, env);
                return self.eval(if (cond.bool) i.then.* else i.@"else".*, env);
            },
            .let => |l| {
                var inner = env;
                for (l.bindings) |b| inner = try self.bind(inner, b.name, try self.eval(b.value, inner));
                return self.eval_body(l.body, inner);
            },
            .do => |body| self.eval_body(body, env),
            .lambda => |lambda| self.closure(lambda, env),
            .template => |t| blk: {
                var names: std.StringHashMapUnmanaged([]const u8) = .empty;
                break :blk .{ .data = try self.fill_template(t.*, env, &names) };
            },
        };
    }

    /// Builds the data a template describes, evaluating its holes.
    fn fill_template(self: *Session, t: ast.Template, env: ?*const Env, names: *std.StringHashMapUnmanaged([]const u8)) Error!reader.Value {
        switch (t) {
            .literal => |v| return v,
            .auto => |a| {
                const entry = try names.getOrPut(self.alloc, a.base);
                if (!entry.found_existing) entry.value_ptr.* = try self.generate(a.pos, a.base);
                return .{ .pos = a.pos, .data = .{ .string = entry.value_ptr.* } };
            },
            .insert => |e| return (try self.eval(e, env)).data,
            .array => |a| {
                var items: std.ArrayList(reader.Value) = .empty;
                for (a.parts) |part| switch (part) {
                    .one => |inner| try items.append(self.alloc, try self.fill_template(inner, env, names)),
                    .splice => |e| {
                        const d = (try self.eval(e, env)).data;
                        const spliced = switch (d.data) {
                            .array => |xs| xs,
                            else => return self.fail(e.pos, "splice needs an array, but this is {s}", .{kind_name(d)}),
                        };
                        try items.appendSlice(self.alloc, spliced);
                    },
                };
                return .{ .pos = a.pos, .data = .{ .array = try items.toOwnedSlice(self.alloc) } };
            },
            .object => |o| {
                const pairs = try self.alloc.alloc(reader.Pair, o.pairs.len);
                for (o.pairs, pairs) |p, *out| out.* = .{ .key = p.key, .value = try self.fill_template(p.value, env, names) };
                return .{ .pos = o.pos, .data = .{ .object = pairs } };
            },
        }
    }

    fn eval_body(self: *Session, body: []const ast.Expr, env: ?*const Env) Error!Value {
        var last: Value = .null;
        for (body) |e| last = try self.eval(e, env);
        return last;
    }

    fn lookup(self: *Session, pos: u32, name: []const u8, env: ?*const Env) Error!Value {
        var it = env;
        while (it) |e| : (it = e.parent) {
            if (std.mem.eql(u8, e.name, name)) return e.value;
        }
        if (self.globals.get(name)) |v| return v;
        // The checker only lets a `def` be used after it, but a function
        // called during an earlier `def` can still reach a later one.
        return self.fail(pos, "\"{s}\" is used before its value has been computed", .{name});
    }

    fn call(self: *Session, pos: u32, c: ast.Call, env: ?*const Env) Error!Value {
        // A built-in's name always means the built-in: nothing shadows it.
        if (c.callee.kind == .ref) {
            if (Builtin.lookup(c.callee.kind.ref)) |b| return self.call_builtin(pos, b, c.args, env);
        }

        const f = (try self.eval(c.callee.*, env)).func;
        const args = try self.alloc.alloc(Value, c.args.len);
        for (c.args, args) |arg, *v| v.* = try self.eval(arg, env); // left to right
        return self.apply_closure(pos, f, args);
    }

    /// Runs a function's body with its parameters bound to args, in the
    /// environment the function captured (not the caller's).
    fn apply_closure(self: *Session, pos: u32, f: *const Closure, args: []const Value) Error!Value {
        var inner = f.env;
        for (f.lambda.params, args) |param, arg| inner = try self.bind(inner, param.name, arg);

        if (self.depth >= self.options.max_call_depth)
            return self.fail(pos, "too many nested calls (more than {d}); is the recursion infinite?", .{self.options.max_call_depth});
        self.depth += 1;
        defer self.depth -= 1;
        return self.eval_body(f.lambda.body, inner);
    }

    // built-ins
    fn call_builtin(self: *Session, pos: u32, b: Builtin, args: []const ast.Expr, env: ?*const Env) Error!Value {
        if (b == .@"data-array") {
            const items = try self.alloc.alloc(reader.Value, args.len);
            for (args, items) |arg, *item| item.* = (try self.eval(arg, env)).data;
            return .{ .data = .{ .pos = pos, .data = .{ .array = items } } };
        }

        var vals: [3]Value = undefined;
        for (args, 0..) |arg, i| vals[i] = try self.eval(arg, env);

        return switch (b) {
            .@"+", .@"-", .@"*", .@"/", .@"%" => self.arithmetic(pos, b, vals[0], vals[1]),
            .@"<", .@"<=", .@">", .@">=" => .{ .bool = compare(b, vals[0], vals[1]) },
            .@"=" => .{ .bool = equal(vals[0], vals[1]) },
            .@"!=" => .{ .bool = !equal(vals[0], vals[1]) },
            .not => .{ .bool = !vals[0].bool },
            .print => {
                try self.print(vals[0]);
                try self.out.writeByte('\n');
                return .null;
            },

            .@"data-null?" => .{ .bool = vals[0].data.data == .null },
            .@"data-bool?" => .{ .bool = vals[0].data.data == .bool },
            .@"data-int?" => .{ .bool = vals[0].data.data == .int },
            .@"data-float?" => .{ .bool = vals[0].data.data == .float },
            .@"data-symbol?" => .{ .bool = vals[0].data.data == .string },
            .@"data-array?" => .{ .bool = vals[0].data.data == .array },
            .@"data-object?" => .{ .bool = vals[0].data.data == .object },
            .@"data-len" => switch (vals[0].data.data) {
                .array => |xs| .{ .int = @intCast(xs.len) },
                .object => |ps| .{ .int = @intCast(ps.len) },
                else => self.fail(pos, "data-len needs an array or object, but this is {s}", .{kind_name(vals[0].data)}),
            },
            .@"data-get" => {
                const xs = try self.expect_array(pos, vals[0].data);
                const i = vals[1].int;
                if (i < 0 or i >= xs.len)
                    return self.fail(pos, "index {d} is out of bounds for an array of length {d}", .{ i, xs.len });
                return .{ .data = xs[@intCast(i)] };
            },
            .@"data-slice" => {
                const xs = try self.expect_array(pos, vals[0].data);
                const start = vals[1].int;
                const end = vals[2].int;
                if (start < 0 or end < start or end > xs.len)
                    return self.fail(pos, "slice {d}..{d} is out of bounds for an array of length {d}", .{ start, end, xs.len });
                return .{ .data = .{ .pos = pos, .data = .{ .array = try self.alloc.dupe(reader.Value, xs[@intCast(start)..@intCast(end)]) } } };
            },
            .@"data-field" => {
                const pairs = try self.expect_object(pos, vals[0].data);
                if (try self.find_field(pairs, vals[1].str)) |v| return .{ .data = v };
                return self.fail(pos, "the object has no key \"{s}\"", .{vals[1].str});
            },
            .@"data-has?" => {
                const pairs = try self.expect_object(pos, vals[0].data);
                return .{ .bool = try self.find_field(pairs, vals[1].str) != null };
            },

            .@"data-to-i64" => switch (vals[0].data.data) {
                .int => |text| .{ .int = std.fmt.parseInt(i64, text, 10) catch
                    return self.fail(pos, "{s} does not fit in i64", .{text}) },
                else => self.fail(pos, "data-to-i64 needs an int, but this is {s}", .{kind_name(vals[0].data)}),
            },
            .@"data-to-f64" => switch (vals[0].data.data) {
                .float => |text| .{ .float = std.fmt.parseFloat(f64, text) catch unreachable },
                else => self.fail(pos, "data-to-f64 needs a float, but this is {s}", .{kind_name(vals[0].data)}),
            },
            .@"data-to-bool" => switch (vals[0].data.data) {
                .bool => |x| .{ .bool = x },
                else => self.fail(pos, "data-to-bool needs a bool, but this is {s}", .{kind_name(vals[0].data)}),
            },
            .@"data-to-str" => switch (vals[0].data.data) {
                .string => |raw| .{ .str = try self.decode(pos, raw) },
                else => self.fail(pos, "data-to-str needs a symbol, but this is {s}", .{kind_name(vals[0].data)}),
            },
            .@"to-data" => .{ .data = try self.to_data(pos, vals[0]) },
            .symbol => .{ .data = .{ .pos = pos, .data = .{ .string = try self.encode(vals[0].str) } } },
            .gensym => .{ .data = .{ .pos = pos, .data = .{ .string = try self.generate(pos, vals[0].str) } } },
            .@"data-array" => unreachable, // handled above
            .eval => try self.eval_data(pos, vals[0].data),
        };
    }

    /// A fresh generated name, base#N
    fn generate(self: *Session, pos: u32, base: []const u8) Error![]const u8 {
        const gensyms = self.options.gensyms orelse
            return self.fail(pos, "generated names aren't available here", .{});
        if (base.len == 0 or base[0] == '@' or std.mem.indexOfAny(u8, base, "#.\\\"") != null)
            return self.fail(pos, "\"{s}\" can't be the base of a generated name", .{base});
        return gensyms.fresh(self.alloc, base);
    }

    fn expect_array(self: *Session, pos: u32, d: reader.Value) Error![]const reader.Value {
        return switch (d.data) {
            .array => |xs| xs,
            else => self.fail(pos, "this needs an array, but it is {s}", .{kind_name(d)}),
        };
    }

    fn expect_object(self: *Session, pos: u32, d: reader.Value) Error![]const reader.Pair {
        return switch (d.data) {
            .object => |ps| ps,
            else => self.fail(pos, "this needs an object, but it is {s}", .{kind_name(d)}),
        };
    }

    /// Keys are stored as raw JSON text, so they are decoded to compare.
    fn find_field(self: *Session, pairs: []const reader.Pair, key: []const u8) Error!?reader.Value {
        for (pairs) |p| {
            const k = try self.decode(p.key.pos, p.key.data.string);
            if (std.mem.eql(u8, k, key)) return p.value;
        }
        return null;
    }

    /// Raw JSON string contents (as the reader keeps them) to text.
    fn decode(self: *Session, pos: u32, raw: []const u8) Error![]const u8 {
        return analyzer.decode_string(self.alloc, raw) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidEscape => self.fail(pos, "invalid \\u escape in string", .{}),
        };
    }

    /// Text to raw JSON string contents, the form data values store.
    fn encode(self: *Session, text: []const u8) Error![]const u8 {
        var w: Writer.Allocating = .init(self.alloc);
        try printer.write_json_text(&w.writer, text);
        const quoted = w.written();
        return quoted[1 .. quoted.len - 1];
    }

    /// The code that evaluates to v: running the result gives v back.
    fn to_data(self: *Session, pos: u32, v: Value) Error!reader.Value {
        const data: @FieldType(reader.Value, "data") = switch (v) {
            .int => |i| .{ .int = try std.fmt.allocPrint(self.alloc, "{d}", .{i}) },
            .float => |f| blk: {
                if (!std.math.isFinite(f)) return self.fail(pos, "{d} has no data form", .{f});
                var w: Writer.Allocating = .init(self.alloc);
                try printer.write_json_float(&w.writer, f);
                break :blk .{ .float = w.written() };
            },
            .bool => |b| .{ .bool = b },
            .null => .null,
            // A string is written {"str": "..."} in code.
            .str => |text| blk: {
                const pair = try self.alloc.alloc(reader.Pair, 1);
                pair[0] = .{
                    .key = .{ .pos = pos, .data = .{ .string = "str" } },
                    .value = .{ .pos = pos, .data = .{ .string = try self.encode(text) } },
                };
                break :blk .{ .object = pair };
            },
            // Data is written ["data", ...] in code.
            .data => |d| blk: {
                const items = try self.alloc.alloc(reader.Value, 2);
                items[0] = .{ .pos = pos, .data = .{ .string = "data" } };
                items[1] = d;
                break :blk .{ .array = items };
            },
            .func => return self.fail(pos, "a function has no data form", .{}),
        };
        return .{ .pos = pos, .data = data };
    }

    /// ["eval", d]: analyzes, checks and runs d as an expression that
    /// can see the globals (but not the caller's locals), and returns its
    /// value as data: a data result as it is, anything else converted with
    /// to-data. Errors in the evaluated code are runtime errors here.
    fn eval_data(self: *Session, pos: u32, d: reader.Value) Error!Value {
        var diag: Diagnostic = undefined;
        const item = analyzer.analyze_form(self.src, d, self.alloc, &diag, .{
            .macros = self.options.macros,
            .gensyms = self.options.gensyms,
        }) catch |err| switch (err) {
            error.AnalysisFailed => return self.fail(pos, "eval: {s}", .{diag.message}),
            else => |e| return e,
        };
        if (item != .expr) return self.fail(pos, "eval can only evaluate expressions, not def, fn or macro", .{});

        // The checker only needs the globals' types, and every runtime
        // value's type can be read off the value itself.
        var types: checker.Session = .{ .src = self.src, .alloc = self.alloc, .diag = null };
        var it = self.globals.iterator();
        while (it.next()) |g| {
            try types.globals.put(self.alloc, g.key_ptr.*, .{ .type = try type_of_value(self.alloc, g.value_ptr.*), .index = 0, .kind = .def });
        }
        types.next_index = 1;
        const t = (types.check_form(self.src, item, &diag) catch |err| switch (err) {
            error.TypeError => return self.fail(pos, "eval: {s}", .{diag.message}),
            else => |e| return e,
        }).?;
        if (t == .@"fn") return self.fail(pos, "eval: the result is a function, which has no data form", .{});

        const result = try self.eval(item.expr, null);
        if (result == .data) return result;
        return .{ .data = try self.to_data(pos, result) };
    }

    fn arithmetic(self: *Session, pos: u32, b: Builtin, x: Value, y: Value) Error!Value {
        switch (x) {
            // f64 follows IEEE 754: overflow gives infinity, 0/0 gives NaN
            .float => |a| return .{
                .float = switch (b) {
                    .@"+" => a + y.float,
                    .@"-" => a - y.float,
                    .@"*" => a * y.float,
                    .@"/" => a / y.float,
                    else => unreachable, // % is i64 only
                },
            },
            .int => |a| {
                const c = y.int;
                const result = switch (b) {
                    .@"+" => @addWithOverflow(a, c),
                    .@"-" => @subWithOverflow(a, c),
                    .@"*" => @mulWithOverflow(a, c),
                    .@"/", .@"%" => {
                        if (c == 0) return self.fail(pos, "division by zero", .{});
                        // The one i64 division that overflows: -2^63 / -1
                        if (a == std.math.minInt(i64) and c == -1) {
                            if (b == .@"%") return .{ .int = 0 };
                            return self.fail(pos, "integer overflow in {d} / {d}", .{ a, c });
                        }
                        // Truncating, like C and Zig's @divTrunc/@rem: the
                        // remainder has the sign of the dividend
                        return .{ .int = if (b == .@"/") @divTrunc(a, c) else @rem(a, c) };
                    },
                    else => unreachable,
                };
                if (result[1] != 0)
                    return self.fail(pos, "integer overflow in {d} {s} {d}", .{ a, b.name(), c });
                return .{ .int = result[0] };
            },
            else => unreachable,
        }
    }

    fn print(self: *Session, v: Value) Error!void {
        try write_value(self.out, v);
    }
};

/// Writes a value as JSON, the way print does. Functions have no JSON
/// form; print can't receive one (the checker rejects it)
pub fn write_value(out: *Writer, v: Value) Writer.Error!void {
    switch (v) {
        .int => |i| try out.print("{d}", .{i}),
        .float => |f| try printer.write_json_float(out, f),
        .bool => |b| try out.writeAll(if (b) "true" else "false"),
        .null => try out.writeAll("null"),
        .str => |s| try printer.write_json_text(out, s),
        .data => |d| try printer.write_json_value(out, d),
        .func => unreachable,
    }
}

/// The type of a runtime value.
fn type_of_value(alloc: Allocator, v: Value) Allocator.Error!ast.Type {
    return switch (v) {
        .int => .i64,
        .float => .f64,
        .bool => .bool,
        .null => .null,
        .str => .str,
        .data => .data,
        .func => |c| blk: {
            const t = try alloc.create(ast.FnType);
            t.* = try c.lambda.fn_type(alloc);
            break :blk .{ .@"fn" = t };
        },
    };
}

/// How a data value's kind is described in error messages.
fn kind_name(d: reader.Value) []const u8 {
    return switch (d.data) {
        .null => "null",
        .bool => "a bool",
        .int => "an int",
        .float => "a float",
        .string => "a symbol",
        .array => "an array",
        .object => "an object",
    };
}

fn compare(b: Builtin, x: Value, y: Value) bool {
    const order: std.math.Order = switch (x) {
        .int => |a| std.math.order(a, y.int),
        // NaN compares false with everything, as IEEE 754 requires.
        .float => |a| if (std.math.isNan(a) or std.math.isNan(y.float))
            return false
        else
            std.math.order(a, y.float),
        else => unreachable,
    };
    return switch (b) {
        .@"<" => order == .lt,
        .@"<=" => order != .gt,
        .@">" => order == .gt,
        .@">=" => order != .lt,
        else => unreachable,
    };
}

fn equal(x: Value, y: Value) bool {
    return switch (x) {
        .int => |a| a == y.int,
        .float => |a| a == y.float, // IEEE: NaN != NaN
        .bool => |a| a == y.bool,
        .null => true,
        .str => |a| std.mem.eql(u8, a, y.str),
        .data => |a| data_equal(a, y.data),
        .func => unreachable, // rejected by the checker
    };
}

/// Structural equality of two code values. Positions don't matter, and
/// two objects are equal if they have the same keys with equal values, in any order.
fn data_equal(a: reader.Value, b: reader.Value) bool {
    if (std.meta.activeTag(a.data) != std.meta.activeTag(b.data)) return false;
    return switch (a.data) {
        .null => true,
        .bool => |x| x == b.data.bool,
        // Numbers compare by their source text, so 1.0 and 1.00 differ;
        // that's the code as written.
        .int => |x| std.mem.eql(u8, x, b.data.int),
        .float => |x| std.mem.eql(u8, x, b.data.float),
        .string => |x| std.mem.eql(u8, x, b.data.string),
        .array => |xs| {
            const ys = b.data.array;
            if (xs.len != ys.len) return false;
            for (xs, ys) |x, y| if (!data_equal(x, y)) return false;
            return true;
        },
        .object => |xs| {
            const ys = b.data.object;
            if (xs.len != ys.len) return false;
            outer: for (xs) |x| {
                for (ys) |y| {
                    if (std.mem.eql(u8, x.key.data.string, y.key.data.string)) {
                        if (!data_equal(x.value, y.value)) return false;
                        continue :outer;
                    }
                }
                return false;
            }
            return true;
        },
    };
}
