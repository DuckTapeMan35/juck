//! Output formats for the reader's value tree.
const std = @import("std");
const reader = @import("reader");
const Value = reader.Value;
const Writer = std.Io.Writer;

/// Version of the --json interchange format. Bump when its shape changes.
pub const json_format_version = "0.1";

/// Writes the program as strict JSON: {"juck": VERSION, "program": ...}.
/// Comments and trailing commas are gone, so any JSON parser can read it.
pub fn writeJson(w: *Writer, program: Value) Writer.Error!void {
    try w.print("{{\"juck\":\"{s}\",\"program\":", .{json_format_version});
    try writeJsonValue(w, program);
    try w.writeAll("}\n");
}

fn writeJsonValue(w: *Writer, v: Value) Writer.Error!void {
    switch (v.data) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        // The grammar only accepts JSON number syntax, so the source text is valid as-is.
        .int, .float => |text| try w.writeAll(text),
        .string => |raw| try writeJsonString(w, raw),
        .array => |items| {
            try w.writeByte('[');
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeJsonValue(w, item);
            }
            try w.writeByte(']');
        },
        .object => |pairs| {
            try w.writeByte('{');
            for (pairs, 0..) |pair, i| {
                if (i > 0) try w.writeByte(',');
                try writeJsonValue(w, pair.key);
                try w.writeByte(':');
                try writeJsonValue(w, pair.value);
            }
            try w.writeByte('}');
        },
    }
}

/// raw is the string's source text between the quotes. Its escape sequences
/// are already valid JSON and are copied through; the grammar does allow raw
/// control characters (like a literal tab), which strict JSON forbids, so
/// those get escaped.
fn writeJsonString(w: *Writer, raw: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (raw) |c| switch (c) {
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Writes the tree one node per line, indented by depth, with byte offsets.
pub fn writeTree(w: *Writer, v: Value, depth: usize) Writer.Error!void {
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
        .array => |items| for (items) |item| try writeTree(w, item, depth + 1),
        .object => |pairs| for (pairs) |pair| {
            try writeTree(w, pair.key, depth + 1);
            try writeTree(w, pair.value, depth + 2);
        },
        else => {},
    }
}
