const std = @import("std");
const reader = @import("reader");
const ast = @import("ast");
const analyzer = @import("analyzer");
const Builtin = @import("builtins").Builtin;

const Type = ast.Type;
const Allocator = std.mem.Allocator;
const Diagnostic = reader.Diagnostic;

pub const Error = error{TypeError} || Allocator.Error;

/// Checks a whole program. On an error, fills diag if given, otherwise prints it
pub fn check(src: []const u8, program: ast.Program, alloc: Allocator, diag: ?*Diagnostic) Error!void {
    var s: Session = .{ .src = src, .alloc = alloc, .diag = diag };
    try s.check_program(src, program, diag);
}

pub const Global = struct {
    type: Type,
    /// Index of the top-level form that defines it
    index: usize,
    kind: enum { def, @"fn" },
};

const Local = struct { name: []const u8, type: Type };

pub const Session = struct {
    src: []const u8,
    alloc: Allocator,
    diag: ?*Diagnostic,

    globals: std.StringHashMapUnmanaged(Global) = .empty,
    /// Locals in scope, innermost last. Scopes are restored by truncating
    locals: std.ArrayList(Local) = .empty,
    /// Index of the top-level form being checked
    current: usize = 0,
    /// True inside the body of a top-level fn. Function bodies only run
    /// when called, so they may call functions defined later in the file
    in_fn_body: bool = false,
    /// Index the next top-level form gets.
    next_index: usize = 0,

    fn fail(self: *Session, pos: u32, comptime fmt: []const u8, args: anytype) Error {
        const message = try std.fmt.allocPrint(self.alloc, fmt, args);
        const d = analyzer.diagnostic_at(self.src, pos, message);
        if (self.diag) |out| {
            out.* = d;
        } else {
            std.debug.print("error at {d}:{d}: {s}\n", .{ d.line, d.column, d.message });
        }
        return error.TypeError;
    }

    // program
    pub fn check_program(self: *Session, src: []const u8, program: ast.Program, diag: ?*Diagnostic) Error!void {
        self.src = src;
        self.diag = diag;
        // First, declare every global with its type, so function bodies can
        // call functions defined later (including each other), and so using
        // a name too early gets a precise error.
        for (program.items, 0..) |item, i| {
            switch (item) {
                .def => |d| try self.declare(d.pos, d.name, .{ .type = d.type, .index = i, .kind = .def }),
                .@"fn" => |f| try self.declare(f.pos, f.name, .{
                    .type = .{ .@"fn" = try self.fn_type_of(f.lambda) },
                    .index = i,
                    .kind = .@"fn",
                }),
                .expr => {},
            }
        }

        self.next_index = program.items.len;
        // Then check each form in order. lookup decides what is visible
        // from the current form.
        for (program.items, 0..) |item, i| {
            self.current = i;
            switch (item) {
                .def => |d| try self.expect(d.value, d.type, "the value of def \"{s}\"", .{d.name}),
                .@"fn" => |f| {
                    self.in_fn_body = true;
                    defer self.in_fn_body = false;
                    try self.check_lambda(f.lambda);
                },
                .expr => |e| _ = try self.type_of(e),
            }
        }
    }

    /// Checks one more top-level form, after everything checked before it
    /// (used by the REPL). Unlike in a file, a name that already exists can
    /// be defined again, but only with the same type, so everything checked
    /// against the old definition stays valid. Returns the type of an
    /// expression form, or null for a definition.
    pub fn check_form(self: *Session, src: []const u8, item: ast.TopLevel, diag: ?*Diagnostic) Error!?Type {
        self.src = src;
        self.diag = diag;
        self.current = self.next_index;
        self.next_index += 1;
        switch (item) {
            .def => |d| {
                // The value is checked first, so it can use the old
                // definition: ["def", {"name": "x", ...}, ["+", "x", 1]]
                try self.expect(d.value, d.type, "the value of def \"{s}\"", .{d.name});
                try self.redeclare(d.pos, d.name, .{ .type = d.type, .index = self.current, .kind = .def });
                return null;
            },
            .@"fn" => |f| {
                // Declared before its body is checked, so it can recurse.
                const previous = self.globals.get(f.name);
                try self.redeclare(f.pos, f.name, .{
                    .type = .{ .@"fn" = try self.fn_type_of(f.lambda) },
                    .index = self.current,
                    .kind = .@"fn",
                });
                self.in_fn_body = true;
                defer self.in_fn_body = false;
                self.check_lambda(f.lambda) catch |err| {
                    self.restore(f.name, previous);
                    return err;
                };
                return null;
            },
            .expr => |e| return try self.type_of(e),
        }
    }

    /// Puts back what a name meant before (or removes it if it was new).
    /// The REPL uses this to undo a definition whose value failed to run.
    pub fn restore(self: *Session, name: []const u8, previous: ?Global) void {
        if (previous) |p| {
            self.globals.putAssumeCapacity(name, p);
        } else {
            _ = self.globals.remove(name);
        }
    }

    fn redeclare(self: *Session, pos: u32, name: []const u8, global: Global) Error!void {
        if (self.globals.get(name)) |old| {
            if (!old.type.eql(global.type))
                return self.fail(pos, "\"{s}\" is already defined as {f}; it can only be redefined with the same type", .{ name, old.type });
            self.globals.putAssumeCapacity(name, global);
            return;
        }
        try self.declare(pos, name, global);
    }

    fn declare(self: *Session, pos: u32, name: []const u8, global: Global) Error!void {
        if (Builtin.lookup(name) != null)
            return self.fail(pos, "\"{s}\" is a built-in and can't be redefined", .{name});
        const entry = try self.globals.getOrPut(self.alloc, name);
        if (entry.found_existing)
            return self.fail(pos, "\"{s}\" is already defined", .{name});
        entry.value_ptr.* = global;
    }

    // expressions
    /// Checks that e has type want; what describes e for the error
    fn expect(self: *Session, e: ast.Expr, want: Type, comptime what: []const u8, args: anytype) Error!void {
        const got = try self.type_of(e);
        if (!got.eql(want)) {
            const desc = try std.fmt.allocPrint(self.alloc, what, args);
            return self.fail(e.pos, "{s} should be {f}, but is {f}", .{ desc, want, got });
        }
    }

    fn type_of(self: *Session, e: ast.Expr) Error!Type {
        return switch (e.kind) {
            .int => .i64,
            .float => .f64,
            .bool => .bool,
            .null => .null,
            .str => .str,
            .data => .data,
            .ref => |name| self.lookup(e.pos, name),
            .call => |call| self.check_call(e.pos, call),
            .@"if" => |i| {
                try self.expect(i.cond.*, .bool, "the condition of if", .{});
                const then = try self.type_of(i.then.*);
                try self.expect(i.@"else".*, then, "the else branch (to match the then branch)", .{});
                return then;
            },
            .let => |l| {
                const scope = self.locals.items.len;
                defer self.locals.shrinkRetainingCapacity(scope);
                for (l.bindings) |b| {
                    try self.expect(b.value, b.type, "the value of \"{s}\"", .{b.name});
                    try self.bind_local(b.pos, b.name, b.type);
                }
                return self.type_of_body(l.body);
            },
            .do => |body| self.type_of_body(body),
            .lambda => |lambda| {
                try self.check_lambda(lambda.*);
                return .{ .@"fn" = try self.fn_type_of(lambda.*) };
            },
        };
    }

    fn type_of_body(self: *Session, body: []const ast.Expr) Error!Type {
        var last: Type = .null;
        for (body) |e| last = try self.type_of(e);
        return last;
    }

    fn check_lambda(self: *Session, lambda: ast.Lambda) Error!void {
        const scope = self.locals.items.len;
        defer self.locals.shrinkRetainingCapacity(scope);
        for (lambda.params) |p| try self.bind_local(p.pos, p.name, p.type);

        for (lambda.body[0 .. lambda.body.len - 1]) |e| _ = try self.type_of(e);
        try self.expect(lambda.body[lambda.body.len - 1], lambda.returns, "the function's result", .{});
    }

    fn fn_type_of(self: *Session, lambda: ast.Lambda) Error!*const ast.FnType {
        const t = try self.alloc.create(ast.FnType);
        t.* = try lambda.fn_type(self.alloc);
        return t;
    }

    // names
    /// Adds a local to the current scope. juck has no shadowing
    fn bind_local(self: *Session, pos: u32, name: []const u8, t: Type) Error!void {
        if (Builtin.lookup(name) != null)
            return self.fail(pos, "\"{s}\" is a built-in; choose another name", .{name});
        if (self.globals.contains(name))
            return self.fail(pos, "\"{s}\" is already a global name; choose another name", .{name});
        for (self.locals.items) |l| {
            if (std.mem.eql(u8, l.name, name))
                return self.fail(pos, "\"{s}\" is already a local name in this scope; choose another name", .{name});
        }
        try self.locals.append(self.alloc, .{ .name = name, .type = t });
    }

    fn lookup(self: *Session, pos: u32, name: []const u8) Error!Type {
        var i = self.locals.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals.items[i].name, name)) return self.locals.items[i].type;
        }
        if (self.globals.get(name)) |g| {
            const visible = switch (g.kind) {
                .def => g.index < self.current,
                .@"fn" => self.in_fn_body or g.index < self.current,
            };
            if (!visible) return self.fail(pos, "\"{s}\" is used before it is defined", .{name});
            return g.type;
        }
        if (Builtin.lookup(name)) |b|
            return self.fail(pos, "the built-in \"{s}\" can only be called, not used as a value", .{b.name()});
        return self.fail(pos, "unknown name \"{s}\"", .{name});
    }

    /// The builtin a callee refers to
    fn callee_builtin(callee: ast.Expr) ?Builtin {
        return switch (callee.kind) {
            .ref => |name| Builtin.lookup(name),
            else => null,
        };
    }

    // calls
    fn check_call(self: *Session, pos: u32, call: ast.Call) Error!Type {
        if (callee_builtin(call.callee.*)) |b| return self.check_builtin(pos, b, call.args);

        const callee_type = try self.type_of(call.callee.*);
        const f = switch (callee_type) {
            .@"fn" => |f| f,
            else => return self.fail(call.callee.pos, "this is {f}, not a function, so it can't be called", .{callee_type}),
        };
        if (call.args.len != f.params.len)
            return self.fail(pos, "the function takes {d} argument(s), but {d} were given", .{ f.params.len, call.args.len });
        for (call.args, f.params, 1..) |arg, param, n| {
            try self.expect(arg, param, "argument {d}", .{n});
        }
        return f.returns;
    }

    fn check_builtin(self: *Session, pos: u32, b: Builtin, args: []const ast.Expr) Error!Type {
        const arity: usize = switch (b) {
            .not, .print => 1,
            else => 2,
        };
        if (args.len != arity)
            return self.fail(pos, "\"{s}\" takes {d} argument(s), but {d} were given", .{ b.name(), arity, args.len });

        switch (b) {
            .@"+", .@"-", .@"*", .@"/", .@"<", .@"<=", .@">", .@">=" => {
                const t = try self.type_of(args[0]);
                if (t != .i64 and t != .f64)
                    return self.fail(args[0].pos, "\"{s}\" needs numbers (\"i64\" or \"f64\"), but this is {f}", .{ b.name(), t });
                try self.expect(args[1], t, "the second argument of \"{s}\" (to match the first)", .{b.name()});
                return switch (b) {
                    .@"<", .@"<=", .@">", .@">=" => .bool,
                    else => t,
                };
            },
            .@"%" => {
                try self.expect(args[0], .i64, "the first argument of \"%\"", .{});
                try self.expect(args[1], .i64, "the second argument of \"%\"", .{});
                return .i64;
            },
            .@"=", .@"!=" => {
                const t = try self.type_of(args[0]);
                if (t == .@"fn") return self.fail(args[0].pos, "functions can't be compared", .{});
                try self.expect(args[1], t, "the second argument of \"{s}\" (to match the first)", .{b.name()});
                return .bool;
            },
            .not => {
                try self.expect(args[0], .bool, "the argument of \"not\"", .{});
                return .bool;
            },
            .print => {
                const t = try self.type_of(args[0]);
                if (t == .@"fn")
                    return self.fail(args[0].pos, "\"print\" can only print i64, f64, bool, str, null and data values, but this is {f}", .{t});
                return .null;
            },
        }
    }
};
