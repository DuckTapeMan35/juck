const std = @import("std");
const reader = @import("reader");
const ast = @import("ast");
const analyzer = @import("analyzer");
const printer = @import("printer");
const Builtin = @import("builtins").Builtin;

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
    };

    /// Runs job on a thread with a stack of options.stack_size.
    fn on_big_stack(self: *Session, src: []const u8, diag: ?*Diagnostic, job: Job) Error!?Value {
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
                .expr => |e| return try self.eval(e, null),
            },
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
                .@"fn" => {},
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
        };
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

        // Arguments are evaluated left to right, then bound in the
        // closure's environment (not the caller's).
        var inner = f.env;
        for (c.args, f.lambda.params) |arg, param| {
            inner = try self.bind(inner, param.name, try self.eval(arg, env));
        }

        if (self.depth >= self.options.max_call_depth)
            return self.fail(pos, "too many nested calls (more than {d}); is the recursion infinite?", .{self.options.max_call_depth});
        self.depth += 1;
        defer self.depth -= 1;
        return self.eval_body(f.lambda.body, inner);
    }

    // built-ins
    fn call_builtin(self: *Session, pos: u32, b: Builtin, args: []const ast.Expr, env: ?*const Env) Error!Value {
        var vals: [2]Value = undefined;
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
        };
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
