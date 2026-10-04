const std = @import("std");
const ts = @import("tree-sitter");

extern fn tree_sitter_juck() callconv(.c) *const ts.Language;

pub const Value = struct {
    pos: u32,
    data: Data,

    pub const Data = union(enum) {
        null,
        bool: bool,
        int: []const u8,
        float: []const u8,
        string: []const u8, // raw contents between the quotes; escapes not decoded yet
        array: []Value,
        object: []Pair,
    };
};

pub const Pair = struct { key: Value, value: Value };

/// Where a syntax error was found, 1-based.
pub const Diagnostic = struct { line: u32, column: u32 };

/// Parses src into its top-level forms.
pub fn read(src: []const u8, alloc: std.mem.Allocator, diag: ?*Diagnostic) ![]Value {
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(tree_sitter_juck());

    const tree = parser.parseString(src, null) orelse return error.ParseFailed;
    defer tree.destroy();
    const root = tree.rootNode();

    if (root.hasError()) {
        const bad = firstError(root).?;
        const p = bad.startPoint();
        const d: Diagnostic = .{ .line = p.row + 1, .column = p.column + 1 };
        if (diag) |out| {
            out.* = d;
        } else {
            std.debug.print("syntax error at {d}:{d}\n", .{ d.line, d.column });
        }
        return error.InvalidInput;
    }

    var forms: std.ArrayList(Value) = .empty;
    errdefer forms.deinit(alloc);
    var i: u32 = 0;
    while (root.namedChild(i)) |child| : (i += 1) {
        if (isComment(child)) continue;
        try forms.append(alloc, try convert(child, src, alloc));
    }
    return forms.toOwnedSlice(alloc);
}

fn convert(node: ts.Node, src: []const u8, alloc: std.mem.Allocator) !Value {
    const kind = node.kind();
    const text = src[node.startByte()..node.endByte()];
    const pos = node.startByte();

    if (eql(kind, "null")) return .{ .pos = pos, .data = .null };
    if (eql(kind, "true")) return .{ .pos = pos, .data = .{ .bool = true } };
    if (eql(kind, "false")) return .{ .pos = pos, .data = .{ .bool = false } };
    if (eql(kind, "string")) return .{ .pos = pos, .data = .{ .string = text[1 .. text.len - 1] } };
    if (eql(kind, "number")) {
        const is_float = std.mem.indexOfAny(u8, text, ".eE") != null;
        return .{ .pos = pos, .data = if (is_float) .{ .float = text } else .{ .int = text } };
    }
    if (eql(kind, "array")) {
        var items: std.ArrayList(Value) = .empty;
        var i: u32 = 0;
        while (node.namedChild(i)) |child| : (i += 1) {
            if (isComment(child)) continue;
            try items.append(alloc, try convert(child, src, alloc));
        }
        return .{ .pos = pos, .data = .{ .array = try items.toOwnedSlice(alloc) } };
    }
    if (eql(kind, "object")) {
        var pairs: std.ArrayList(Pair) = .empty;
        var i: u32 = 0;
        while (node.namedChild(i)) |pair| : (i += 1) {
            if (isComment(pair)) continue;
            try pairs.append(alloc, .{
                .key = try convert(pair.childByFieldName("key").?, src, alloc),
                .value = try convert(pair.childByFieldName("value").?, src, alloc),
            });
        }
        return .{ .pos = pos, .data = .{ .object = try pairs.toOwnedSlice(alloc) } };
    }
    std.debug.panic("unexpected node kind '{s}'", .{kind});
}

/// Depth-first search for the first ERROR or MISSING node.
fn firstError(node: ts.Node) ?ts.Node {
    if (node.isError() or node.isMissing()) return node;
    var i: u32 = 0;
    while (node.child(i)) |child| : (i += 1) {
        if (child.hasError() or child.isMissing()) {
            if (firstError(child)) |e| return e;
        }
    }
    return null;
}

fn isComment(node: ts.Node) bool {
    return eql(node.kind(), "comment");
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
