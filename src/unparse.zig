const std = @import("std");
const reader = @import("reader");
const ast = @import("ast");
const printer = @import("printer");

const Allocator = std.mem.Allocator;
const Value = reader.Value;
const Entry = struct { []const u8, Value };

/// How a module refers to a module it imports: names starting with
/// prefix (std/logic.) are written alias.name (logic.name).
pub const Alias = struct {
    prefix: []const u8,
    alias: []const u8,
};

pub fn program(alloc: Allocator, p: ast.Program, aliases: []const Alias) Allocator.Error!Value {
    const v = try program_as_is(alloc, p);
    return rename_generated(alloc, if (aliases.len == 0) v else try apply_aliases(alloc, v, aliases));
}

fn program_as_is(alloc: Allocator, p: ast.Program) Allocator.Error!Value {
    var forms: std.ArrayList(Value) = .empty;
    for (p.items) |item| switch (item) {
        .def => |d| {
            var keys: std.ArrayList(Entry) = .empty;
            try keys.append(alloc, .{ "name", sym(d.name) });
            try keys.append(alloc, .{ "type", try type_value(alloc, d.type) });
            if (d.is_pub) try keys.append(alloc, .{ "pub", .{ .pos = 0, .data = .{ .bool = true } } });
            try forms.append(alloc, try form(
                alloc,
                &.{
                    sym("def"),
                    try object(alloc, keys.items),
                    try expr(alloc, d.value),
                },
            ));
        },
        .@"fn" => |f| try forms.append(
            alloc,
            try function(
                alloc,
                "fn",
                f.name,
                f.doc,
                f.is_comptime,
                f.is_pub,
                f.lambda,
            ),
        ),
        .macro => {},
        .import => |i| try forms.append(alloc, try form(alloc, &.{ sym("import"), sym(i.name), sym(i.path) })),
        .expr => |e| try forms.append(alloc, try expr(alloc, e)),
    };
    return array(try forms.toOwnedSlice(alloc));
}

pub fn top_level(alloc: Allocator, item: ast.TopLevel, aliases: []const Alias) Allocator.Error!Value {
    const v = try top_level_as_is(alloc, item);
    return if (aliases.len == 0) v else apply_aliases(alloc, v, aliases);
}

fn top_level_as_is(alloc: Allocator, item: ast.TopLevel) Allocator.Error!Value {
    return switch (item) {
        .def, .@"fn", .import => (try program_as_is(alloc, .{ .items = &.{item} })).data.array[0],
        .macro => |m| sym(m.name),
        .expr => |e| expr(alloc, e),
    };
}

pub fn expr(alloc: Allocator, e: ast.Expr) Allocator.Error!Value {
    return switch (e.kind) {
        .int => |i| .{ .pos = 0, .data = .{ .int = try std.fmt.allocPrint(alloc, "{d}", .{i}) } },
        .float => |f| blk: {
            var w: std.Io.Writer.Allocating = .init(alloc);
            printer.write_json_float(&w.writer, f) catch return error.OutOfMemory;
            break :blk .{ .pos = 0, .data = .{ .float = w.written() } };
        },
        .bool => |b| .{ .pos = 0, .data = .{ .bool = b } },
        .null => .{ .pos = 0, .data = .null },
        .str => |text| object(alloc, &.{.{ "str", .{ .pos = 0, .data = .{ .string = try encode(alloc, text) } } }}),
        .data => |d| form(alloc, &.{ sym("data"), d }),
        .ref => |name| sym(name),
        .call => |c| blk: {
            const items = try alloc.alloc(Value, c.args.len + 1);
            items[0] = try expr(alloc, c.callee.*);
            for (c.args, items[1..]) |arg, *item| item.* = try expr(alloc, arg);
            break :blk array(items);
        },
        .@"if" => |i| form(alloc, &.{ sym("if"), try expr(alloc, i.cond.*), try expr(alloc, i.then.*), try expr(alloc, i.@"else".*) }),
        .let => |l| blk: {
            const bindings = try alloc.alloc(Value, l.bindings.len);
            for (l.bindings, bindings) |b, *out| {
                out.* = try form(alloc, &.{ sym(b.name), try type_value(alloc, b.type), try expr(alloc, b.value) });
            }
            break :blk with_body(alloc, &.{ sym("let"), array(bindings) }, l.body);
        },
        .do => |body| with_body(alloc, &.{sym("do")}, body),
        .lambda => |l| function(
            alloc,
            "lambda",
            null,
            null,
            false,
            false,
            l.*,
        ),
        .template => |t| form(alloc, &.{ sym("template"), try template(alloc, t.*) }),
    };
}

fn template(alloc: Allocator, t: ast.Template) Allocator.Error!Value {
    return switch (t) {
        .literal => |v| v,
        .auto => |a| sym(try std.fmt.allocPrint(alloc, "{s}#", .{a.base})),
        .insert => |e| form(alloc, &.{ sym("insert"), try expr(alloc, e) }),
        .array => |a| blk: {
            const items = try alloc.alloc(Value, a.parts.len);
            for (a.parts, items) |part, *item| item.* = switch (part) {
                .one => |inner| try template(alloc, inner),
                .splice => |e| try form(alloc, &.{ sym("splice"), try expr(alloc, e) }),
            };
            break :blk array(items);
        },
        .object => |o| blk: {
            const pairs = try alloc.alloc(reader.Pair, o.pairs.len);
            for (o.pairs, pairs) |p, *out| out.* = .{ .key = p.key, .value = try template(alloc, p.value) };
            break :blk .{ .pos = 0, .data = .{ .object = pairs } };
        },
    };
}

fn function(
    alloc: Allocator,
    head: []const u8,
    name: ?[]const u8,
    doc: ?[]const u8,
    is_comptime: bool,
    is_pub: bool,
    l: ast.Lambda,
) Allocator.Error!Value {
    const params = try alloc.alloc(Value, l.params.len);
    for (l.params, params) |p, *out| out.* = try form(alloc, &.{ sym(p.name), try type_value(alloc, p.type) });

    var keys: std.ArrayList(Entry) = .empty;
    if (name) |n| try keys.append(alloc, .{ "name", sym(n) });
    try keys.append(alloc, .{ "params", array(params) });
    try keys.append(alloc, .{ "returns", try type_value(alloc, l.returns) });
    if (doc) |d| try keys.append(alloc, .{ "doc", .{ .pos = 0, .data = .{ .string = try encode(alloc, d) } } });
    if (is_comptime) try keys.append(alloc, .{ "comptime", .{ .pos = 0, .data = .{ .bool = true } } });
    if (is_pub) try keys.append(alloc, .{ "pub", .{ .pos = 0, .data = .{ .bool = true } } });

    return with_body(alloc, &.{ sym(head), try object(alloc, keys.items) }, l.body);
}

fn type_value(alloc: Allocator, t: ast.Type) Allocator.Error!Value {
    return switch (t) {
        .@"fn" => |f| blk: {
            const params = try alloc.alloc(Value, f.params.len);
            for (f.params, params) |p, *out| out.* = try type_value(alloc, p);
            break :blk object(alloc, &.{.{ "fn", try object(alloc, &.{
                .{ "params", array(params) },
                .{ "returns", try type_value(alloc, f.returns) },
            }) }});
        },
        else => sym(@tagName(t)),
    };
}

/// std/logic.when back to logic.when, for every symbol in v
fn apply_aliases(alloc: Allocator, v: Value, aliases: []const Alias) Allocator.Error!Value {
    return switch (v.data) {
        .string => |name| for (aliases) |a| {
            if (std.mem.startsWith(u8, name, a.prefix))
                break sym(try std.fmt.allocPrint(alloc, "{s}.{s}", .{ a.alias, name[a.prefix.len..] }));
        } else v,
        .array => |items| blk: {
            const out = try alloc.alloc(Value, items.len);
            for (items, out) |item, *o| o.* = try apply_aliases(alloc, item, aliases);
            break :blk array(out);
        },
        .object => |pairs| blk: {
            const out = try alloc.alloc(reader.Pair, pairs.len);
            for (pairs, out) |pair, *o| o.* = .{ .key = pair.key, .value = try apply_aliases(alloc, pair.value, aliases) };
            break :blk .{ .pos = v.pos, .data = .{ .object = out } };
        },
        else => v,
    };
}

// renaming generated names
/// A generated name: base#digits
fn is_generated(name: []const u8) bool {
    const hash = std.mem.lastIndexOfScalar(u8, name, '#') orelse return false;
    if (hash == 0 or hash == name.len - 1) return false;
    for (name[hash + 1 ..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn rename_generated(alloc: Allocator, v: Value) Allocator.Error!Value {
    var used: std.StringHashMapUnmanaged(void) = .empty;
    try collect_symbols(alloc, v, &used);

    var renames: std.StringHashMapUnmanaged([]const u8) = .empty;
    var it = used.keyIterator();
    while (it.next()) |name| {
        if (!is_generated(name.*)) continue;
        var candidate = try std.mem.replaceOwned(u8, alloc, name.*, "#", "_");
        while (used.contains(candidate)) candidate = try std.fmt.allocPrint(alloc, "{s}_", .{candidate});
        try used.put(alloc, candidate, {});
        try renames.put(alloc, name.*, candidate);
    }
    if (renames.count() == 0) return v;
    return apply_renames(alloc, v, &renames);
}

fn collect_symbols(alloc: Allocator, v: Value, used: *std.StringHashMapUnmanaged(void)) Allocator.Error!void {
    switch (v.data) {
        .string => |name| try used.put(alloc, name, {}),
        .array => |items| for (items) |item| try collect_symbols(alloc, item, used),
        .object => |pairs| for (pairs) |pair| try collect_symbols(alloc, pair.value, used),
        else => {},
    }
}

fn apply_renames(alloc: Allocator, v: Value, renames: *const std.StringHashMapUnmanaged([]const u8)) Allocator.Error!Value {
    return switch (v.data) {
        .string => |name| if (renames.get(name)) |new| sym(new) else v,
        .array => |items| blk: {
            const out = try alloc.alloc(Value, items.len);
            for (items, out) |item, *o| o.* = try apply_renames(alloc, item, renames);
            break :blk array(out);
        },
        .object => |pairs| blk: {
            const out = try alloc.alloc(reader.Pair, pairs.len);
            for (pairs, out) |pair, *o| o.* = .{ .key = pair.key, .value = try apply_renames(alloc, pair.value, renames) };
            break :blk .{ .pos = v.pos, .data = .{ .object = out } };
        },
        else => v,
    };
}

// building values
fn sym(name: []const u8) Value {
    return .{ .pos = 0, .data = .{ .string = name } };
}

fn array(items: []Value) Value {
    return .{ .pos = 0, .data = .{ .array = items } };
}

fn form(alloc: Allocator, items: []const Value) Allocator.Error!Value {
    return array(try alloc.dupe(Value, items));
}

fn with_body(alloc: Allocator, head: []const Value, body: []const ast.Expr) Allocator.Error!Value {
    const items = try alloc.alloc(Value, head.len + body.len);
    @memcpy(items[0..head.len], head);
    for (body, items[head.len..]) |e, *item| item.* = try expr(alloc, e);
    return array(items);
}

fn object(alloc: Allocator, entries: []const Entry) Allocator.Error!Value {
    const pairs = try alloc.alloc(reader.Pair, entries.len);
    for (entries, pairs) |entry, *p| p.* = .{ .key = sym(entry[0]), .value = entry[1] };
    return .{ .pos = 0, .data = .{ .object = pairs } };
}

/// Text to raw JSON string contents, the form data values store.
fn encode(alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    printer.write_json_text(&w.writer, text) catch return error.OutOfMemory;
    const quoted = w.written();
    return quoted[1 .. quoted.len - 1];
}
