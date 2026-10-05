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
pub const Diagnostic = struct {
    line: u32,
    column: u32,
    message: []const u8,
};

pub fn read(src: []const u8, alloc: std.mem.Allocator, diag: ?*Diagnostic) !Value {
    return read_at(src, 0, alloc, diag);
}

/// Parses src into its top-level forms.
pub fn read_at(src: []const u8, offset: u32, alloc: std.mem.Allocator, diag: ?*Diagnostic) !Value {
    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(tree_sitter_juck());

    const tree = parser.parseString(src, null) orelse return error.ParseFailed;
    defer tree.destroy();
    const root = tree.rootNode();

    if (root.hasError()) return fail(diag, first_error(root).?.startPoint(), "syntax error");

    // The grammar accepts any number of top-level values, so the error for
    // an extra one can point at exactly where it starts.
    var value: ?Value = null;
    var i: u32 = 0;
    while (root.namedChild(i)) |child| : (i += 1) {
        if (is_comment(child)) continue;
        if (value != null) return fail(diag, child.startPoint(), "expected a single top-level value");
        value = try convert(child, src, offset, alloc, diag);
    }
    return value orelse return fail(diag, root.endPoint(), "expected a value, but the file is empty");
}

fn fail(diag: ?*Diagnostic, point: ts.Point, message: []const u8) error{InvalidInput} {
    const d: Diagnostic = .{ .line = point.row + 1, .column = point.column + 1, .message = message };
    if (diag) |out| {
        out.* = d;
    } else {
        std.debug.print("error at {d}:{d}: {s}\n", .{ d.line, d.column, d.message });
    }
    return error.InvalidInput;
}

fn convert(node: ts.Node, src: []const u8, offset: u32, alloc: std.mem.Allocator, diag: ?*Diagnostic) !Value {
    const kind = node.kind();
    const text = src[node.startByte()..node.endByte()];
    const pos = offset + node.startByte();

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
            if (is_comment(child)) continue;
            try items.append(alloc, try convert(child, src, offset, alloc, diag));
        }
        return .{ .pos = pos, .data = .{ .array = try items.toOwnedSlice(alloc) } };
    }
    if (eql(kind, "object")) {
        var pairs: std.ArrayList(Pair) = .empty;
        var i: u32 = 0;
        while (node.namedChild(i)) |pair| : (i += 1) {
            if (is_comment(pair)) continue;
            const key_node = pair.childByFieldName("key").?;
            const key = try convert(key_node, src, offset, alloc, diag);
            for (pairs.items) |earlier| {
                if (std.mem.eql(u8, earlier.key.data.string, key.data.string)) {
                    return fail(diag, key_node.startPoint(), "duplicate key in object");
                }
            }
            try pairs.append(alloc, .{
                .key = key,
                .value = try convert(pair.childByFieldName("value").?, src, offset, alloc, diag),
            });
        }
        return .{ .pos = pos, .data = .{ .object = try pairs.toOwnedSlice(alloc) } };
    }
    std.debug.panic("unexpected node kind '{s}'", .{kind});
}

/// Depth-first search for the first ERROR or MISSING node.
fn first_error(node: ts.Node) ?ts.Node {
    if (node.isError() or node.isMissing()) return node;
    var i: u32 = 0;
    while (node.child(i)) |child| : (i += 1) {
        if (child.hasError() or child.isMissing()) {
            if (first_error(child)) |e| return e;
        }
    }
    return null;
}

fn is_comment(node: ts.Node) bool {
    return eql(node.kind(), "comment");
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
