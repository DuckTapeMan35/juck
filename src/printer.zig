//! Output formats for the reader's value tree.
const std = @import("std");
const reader = @import("reader");
const Value = reader.Value;
const Writer = std.Io.Writer;

/// Version of the --json interchange format. Bump when its shape changes.
pub const json_format_version = "0.1";

/// Writes the program as strict JSON: {"juck": VERSION, "program": ...}.
/// Comments and trailing commas are gone, so any JSON parser can read it.
pub fn write_json(w: *Writer, program: Value) Writer.Error!void {
    try w.print("{{\"juck\":\"{s}\",\"program\":", .{json_format_version});
    try write_json_value(w, program);
    try w.writeAll("}\n");
}

pub fn write_json_value(w: *Writer, v: Value) Writer.Error!void {
    switch (v.data) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        // The grammar only accepts JSON number syntax, so the source text is valid as-is.
        .int, .float => |text| try w.writeAll(text),
        .string => |raw| try write_json_string(w, raw),
        .array => |items| {
            try w.writeByte('[');
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try write_json_value(w, item);
            }
            try w.writeByte(']');
        },
        .object => |pairs| {
            try w.writeByte('{');
            for (pairs, 0..) |pair, i| {
                if (i > 0) try w.writeByte(',');
                try write_json_value(w, pair.key);
                try w.writeByte(':');
                try write_json_value(w, pair.value);
            }
            try w.writeByte('}');
        },
    }
}

/// raw is the string's source text between the quotes. Its escape sequences
/// are already valid JSON and are copied through; the grammar does allow raw
/// control characters (like a literal tab), which strict JSON forbids, so
/// those get escaped.
pub fn write_json_string(w: *Writer, raw: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (raw) |c| switch (c) {
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

pub fn write_json_text(w: *Writer, text: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (text) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0C => try w.writeAll("\\f"),
        0x00...0x07, 0x0B, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

pub fn write_json_float(w: *Writer, x: f64) Writer.Error!void {
    if (!std.math.isFinite(x)) return w.writeAll("null");
    var buf: [64]u8 = undefined;
    var fw: Writer = .fixed(&buf);
    const abs = @abs(x);
    if (x != 0 and (abs >= 1e21 or abs < 1e-6)) {
        fw.print("{e}", .{x}) catch unreachable;
    } else {
        fw.print("{d}", .{x}) catch unreachable;
    }
    const text = fw.buffered();
    try w.writeAll(text);
    if (std.mem.indexOfAny(u8, text, ".e") == null) try w.writeAll(".0");
}

/// Writes the tree one node per line, indented by depth, with byte offsets.
pub fn write_tree(w: *Writer, v: Value, depth: usize) Writer.Error!void {
    try w.splatByteAll(' ', depth * 2);
    switch (v.data) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.print("{}", .{b}),
        .int => |s| try w.print("int {s}", .{s}),
        .float => |s| try w.print("float {s}", .{s}),
        .string => |s| try w.print("string \"{s}\"", .{s}),
        .array => try w.writeAll("array"),
        .object => try w.writeAll("object"),
    }
    try w.print(" @{d}\n", .{v.pos});

    switch (v.data) {
        .array => |items| for (items) |item| try write_tree(w, item, depth + 1),
        .object => |pairs| for (pairs) |pair| {
            try write_tree(w, pair.key, depth + 1);
            try write_tree(w, pair.value, depth + 2);
        },
        else => {},
    }
}
