const std = @import("std");
const reader = @import("reader");

// types
pub const Type = union(enum) {
    i64,
    f64,
    bool,
    str,
    null,
    /// Any juck code as a value (what data forms produce).
    data,
    @"fn": *const FnType,

    pub fn eql(a: Type, b: Type) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .@"fn" => |fa| fa.eql(b.@"fn".*),
            else => true,
        };
    }

    /// Prints the type the way it is written in juck, for error messages.
    pub fn format(self: Type, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .@"fn" => |f| {
                try w.writeAll("{\"fn\": {\"params\": [");
                for (f.params, 0..) |p, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.print("{f}", .{p});
                }
                try w.print("], \"returns\": {f}}}}}", .{f.returns});
            },
            else => try w.print("\"{s}\"", .{@tagName(self)}),
        }
    }
};

/// {"fn": {"params": [...], "returns": ...}}. Parameter names are not
/// part of the type, so two function types are equal if their parameter
/// and return types are.
pub const FnType = struct {
    params: []const Type,
    returns: Type,

    pub fn eql(a: FnType, b: FnType) bool {
        if (a.params.len != b.params.len) return false;
        for (a.params, b.params) |pa, pb| if (!pa.eql(pb)) return false;
        return a.returns.eql(b.returns);
    }
};

// expressions
pub const Expr = struct {
    pos: u32,
    kind: Kind,

    pub const Kind = union(enum) {
        int: i64,
        float: f64,
        bool: bool,
        null,
        /// A {"str": ...} literal, with escape sequences decoded.
        str: []const u8,
        /// ["data", x]: x exactly as the reader produced it, unevaluated.
        data: reader.Value,
        /// A symbol used as a value: a variable, parameter or function name.
        ref: []const u8,
        call: Call,
        @"if": If,
        let: Let,
        do: []const Expr,
        lambda: *const Lambda,
    };
};

/// [callee, args...]. The callee is any expression.
pub const Call = struct {
    callee: *const Expr,
    args: []const Expr,
};

/// ["if", cond, then, else]
pub const If = struct {
    cond: *const Expr,
    then: *const Expr,
    @"else": *const Expr,
};

/// ["let", [[name, type, value], ...], body...]
pub const Let = struct {
    bindings: []const Binding,
    body: []const Expr,
};

pub const Binding = struct {
    name: []const u8,
    pos: u32,
    type: Type,
    value: Expr,
};

/// A lambda, and the function part of a named fn.
pub const Lambda = struct {
    params: []const Param,
    returns: Type,
    body: []const Expr,

    /// The function's type, for the checker. Allocates the parameter list.
    pub fn fn_type(self: Lambda, alloc: std.mem.Allocator) !FnType {
        const params = try alloc.alloc(Type, self.params.len);
        for (self.params, params) |p, *t| t.* = p.type;
        return .{ .params = params, .returns = self.returns };
    }
};

pub const Param = struct {
    name: []const u8,
    pos: u32,
    type: Type,
};

// top level

/// A whole file: its top-level forms, in order.
pub const Program = struct {
    items: []const TopLevel,
};

/// def and fn only appear at the top level; everything else is an
/// expression evaluated for its effects (like ["print", ...]).
pub const TopLevel = union(enum) {
    def: Def,
    @"fn": Fn,
    expr: Expr,
};

/// ["def", {"name": ..., "type": ...}, value]
pub const Def = struct {
    pos: u32,
    name: []const u8,
    type: Type,
    value: Expr,
};

/// ["fn", {"name": ..., "params": ..., "returns": ..., "doc": ...}, body...]
pub const Fn = struct {
    pos: u32,
    name: []const u8,
    doc: ?[]const u8,
    lambda: Lambda,
};

test "type equality" {
    const a: FnType = .{ .params = &.{ .i64, .i64 }, .returns = .i64 };
    const b: FnType = .{ .params = &.{ .i64, .i64 }, .returns = .i64 };
    const c: FnType = .{ .params = &.{ .i64, .f64 }, .returns = .i64 };
    try std.testing.expect((Type{ .@"fn" = &a }).eql(.{ .@"fn" = &b }));
    try std.testing.expect(!(Type{ .@"fn" = &a }).eql(.{ .@"fn" = &c }));
    try std.testing.expect(!(@as(Type, .i64)).eql(.f64));

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f}", .{Type{ .@"fn" = &c }});
    try std.testing.expectEqualStrings(
        \\{"fn": {"params": ["i64", "f64"], "returns": "i64"}}
    , w.buffered());
}
