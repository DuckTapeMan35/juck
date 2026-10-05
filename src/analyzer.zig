const std = @import("std");
const reader = @import("reader");
const ast = @import("ast");

const Value = reader.Value;
const Diagnostic = reader.Diagnostic;
const Allocator = std.mem.Allocator;

pub const Error = error{AnalysisFailed} || Allocator.Error;

/// Names of special forms. They are reserved: they can't be used as names or as values
pub const special_forms = [_][]const u8{ "def", "fn", "lambda", "type", "if", "let", "do", "data", "template", "insert", "splice" };

/// Analyzes a whole program. On an error, fills diag if given,
/// otherwise prints it. All memory comes from alloc (meant to be an arena)
pub fn analyze(src: []const u8, program: Value, alloc: Allocator, diag: ?*Diagnostic) Error!ast.Program {
    var a: Analyzer = .{ .src = src, .alloc = alloc, .diag = diag };
    return a.analyze_program(program);
}

/// Analyzes a single top-level form (used by the REPL, which reads one form at a time)
pub fn analyze_form(src: []const u8, form: Value, alloc: Allocator, diag: ?*Diagnostic) Error!ast.TopLevel {
    var a: Analyzer = .{ .src = src, .alloc = alloc, .diag = diag };
    return a.top_level(form);
}

const Analyzer = struct {
    src: []const u8,
    alloc: Allocator,
    diag: ?*Diagnostic,

    // errors
    fn fail(self: *Analyzer, pos: u32, comptime fmt: []const u8, args: anytype) Error {
        const message = try std.fmt.allocPrint(self.alloc, fmt, args);
        const d = diagnostic_at(self.src, pos, message);
        if (self.diag) |out| {
            out.* = d;
        } else {
            std.debug.print("error at {d}:{d}: {s}\n", .{ d.line, d.column, d.message });
        }
        return error.AnalysisFailed;
    }

    // program and top level
    fn analyze_program(self: *Analyzer, v: Value) Error!ast.Program {
        const forms = switch (v.data) {
            .array => |items| items,
            else => return self.fail(v.pos, "a program must be an array of forms", .{}),
        };
        const items = try self.alloc.alloc(ast.TopLevel, forms.len);
        for (forms, items) |f, *item| item.* = try self.top_level(f);
        return .{ .items = items };
    }

    fn top_level(self: *Analyzer, v: Value) Error!ast.TopLevel {
        if (form_head(v)) |head| {
            if (eql(head, "def")) return .{ .def = try self.def(v) };
            if (eql(head, "fn")) return .{ .@"fn" = try self.named_fn(v) };
        }
        return .{ .expr = try self.expr(v) };
    }

    /// ["def", {"name": ..., "type": ...}, value]
    fn def(self: *Analyzer, v: Value) Error!ast.Def {
        const items = v.data.array;
        if (items.len != 3) return self.fail(v.pos, "def takes a definition object and a value", .{});
        const obj = try self.definition_object(items[1], "def", &.{ "name", "type" }, &.{ "name", "type" });
        return .{
            .pos = v.pos,
            .name = try self.name(obj.get("name").?),
            .type = try self.type_expr(obj.get("type").?),
            .value = try self.expr(items[2]),
        };
    }

    /// ["fn", {"name": ..., "params": ..., "returns": ..., "doc": ...}, body...]
    fn named_fn(self: *Analyzer, v: Value) Error!ast.Fn {
        const items = v.data.array;
        if (items.len < 3) return self.fail(v.pos, "fn takes a definition object and a body", .{});
        const obj = try self.definition_object(items[1], "fn", &.{ "name", "params", "returns", "doc" }, &.{ "name", "params", "returns" });
        const doc: ?[]const u8 = if (obj.get("doc")) |d| try self.string_literal(d) else null;
        return .{
            .pos = v.pos,
            .name = try self.name(obj.get("name").?),
            .doc = doc,
            .lambda = try self.lambda_parts(obj, items[2..]),
        };
    }

    // expressions
    fn expr(self: *Analyzer, v: Value) Error!ast.Expr {
        const kind: ast.Expr.Kind = switch (v.data) {
            .null => .null,
            .bool => |b| .{ .bool = b },
            .int => |text| .{ .int = std.fmt.parseInt(i64, text, 10) catch
                return self.fail(v.pos, "integer {s} does not fit in i64", .{text}) },
            .float => |text| .{ .float = std.fmt.parseFloat(f64, text) catch unreachable },
            .string => .{ .ref = try self.name(v) },
            .object => try self.literal_object(v),
            .array => |items| try self.form(v, items),
        };
        return .{ .pos = v.pos, .kind = kind };
    }

    /// {"str": "..."}: the only literal object so far
    fn literal_object(self: *Analyzer, v: Value) Error!ast.Expr.Kind {
        const pairs = v.data.object;
        if (pairs.len != 1) return self.fail(v.pos, "a literal object must have exactly one key, like {{\"str\": ...}}", .{});
        const key = pairs[0].key.data.string;
        if (eql(key, "str")) return .{ .str = try self.string_literal(pairs[0].value) };
        return self.fail(pairs[0].key.pos, "unknown literal object \"{s}\"", .{key});
    }

    fn form(self: *Analyzer, v: Value, items: []const Value) Error!ast.Expr.Kind {
        if (items.len == 0) return self.fail(v.pos, "empty form: a form needs at least a head", .{});

        if (form_head(v)) |head| {
            if (eql(head, "if")) return .{ .@"if" = try self.if_form(v, items) };
            if (eql(head, "let")) return .{ .let = try self.let_form(v, items) };
            if (eql(head, "do")) {
                if (items.len < 2) return self.fail(v.pos, "do needs at least one expression", .{});
                return .{ .do = try self.exprs(items[1..]) };
            }
            if (eql(head, "lambda")) return .{ .lambda = try self.lambda_form(v, items) };
            if (eql(head, "data")) {
                if (items.len != 2) return self.fail(v.pos, "data takes exactly one argument", .{});
                return .{ .data = items[1] };
            }
            if (eql(head, "template")) {
                if (items.len != 2) return self.fail(v.pos, "template takes exactly one argument", .{});
                const t = try self.alloc.create(ast.Template);
                t.* = try self.template(items[1]);
                return .{ .template = t };
            }
            if (eql(head, "insert") or eql(head, "splice"))
                return self.fail(v.pos, "{s} can only be used inside a template", .{head});
            if (eql(head, "def") or eql(head, "fn"))
                return self.fail(v.pos, "{s} is only allowed at the top level", .{head});
            if (eql(head, "type"))
                return self.fail(v.pos, "type is not supported yet", .{});
        }

        // Anything else is a call
        const callee = try self.alloc.create(ast.Expr);
        callee.* = try self.expr(items[0]);
        return .{ .call = .{ .callee = callee, .args = try self.exprs(items[1..]) } };
    }

    /// ["if", cond, then, else]
    fn if_form(self: *Analyzer, v: Value, items: []const Value) Error!ast.If {
        if (items.len != 4) return self.fail(v.pos, "if takes a condition, a then branch and an else branch", .{});
        const parts = try self.alloc.alloc(ast.Expr, 3);
        for (items[1..], parts) |item, *part| part.* = try self.expr(item);
        return .{ .cond = &parts[0], .then = &parts[1], .@"else" = &parts[2] };
    }

    /// ["let", [[name, type, value], ...], body...]
    fn let_form(self: *Analyzer, v: Value, items: []const Value) Error!ast.Let {
        if (items.len < 3) return self.fail(v.pos, "let takes a list of bindings and a body", .{});
        const list = switch (items[1].data) {
            .array => |l| l,
            else => return self.fail(items[1].pos, "let bindings must be an array of [name, type, value] triples", .{}),
        };
        const bindings = try self.alloc.alloc(ast.Binding, list.len);
        for (list, bindings) |b, *out| {
            const triple = switch (b.data) {
                .array => |t| t,
                else => return self.fail(b.pos, "a let binding must be a [name, type, value] triple", .{}),
            };
            if (triple.len != 3) return self.fail(b.pos, "a let binding must be a [name, type, value] triple", .{});
            out.* = .{
                .name = try self.name(triple[0]),
                .pos = triple[0].pos,
                .type = try self.type_expr(triple[1]),
                .value = try self.expr(triple[2]),
            };
        }
        return .{ .bindings = bindings, .body = try self.exprs(items[2..]) };
    }

    /// ["lambda", {"params": ..., "returns": ...}, body...]
    fn lambda_form(self: *Analyzer, v: Value, items: []const Value) Error!*const ast.Lambda {
        if (items.len < 3) return self.fail(v.pos, "lambda takes a definition object and a body", .{});
        const obj = try self.definition_object(items[1], "lambda", &.{ "params", "returns" }, &.{ "params", "returns" });
        const lambda = try self.alloc.create(ast.Lambda);
        lambda.* = try self.lambda_parts(obj, items[2..]);
        return lambda;
    }

    /// The parts fn and lambda share: parameters, return type, body.
    fn lambda_parts(self: *Analyzer, obj: DefObject, body: []const Value) Error!ast.Lambda {
        const params_value = obj.get("params").?;
        const list = switch (params_value.data) {
            .array => |l| l,
            else => return self.fail(params_value.pos, "params must be an array of [name, type] pairs", .{}),
        };
        const params = try self.alloc.alloc(ast.Param, list.len);
        for (list, params, 0..) |p, *out, i| {
            const pair = switch (p.data) {
                .array => |pr| pr,
                else => return self.fail(p.pos, "a parameter must be a [name, type] pair", .{}),
            };
            if (pair.len != 2) return self.fail(p.pos, "a parameter must be a [name, type] pair", .{});
            const param_name = try self.name(pair[0]);
            for (params[0..i]) |earlier| {
                if (eql(earlier.name, param_name))
                    return self.fail(pair[0].pos, "duplicate parameter \"{s}\"", .{param_name});
            }
            out.* = .{ .name = param_name, .pos = pair[0].pos, .type = try self.type_expr(pair[1]) };
        }
        return .{
            .params = params,
            .returns = try self.type_expr(obj.get("returns").?),
            .body = try self.exprs(body),
        };
    }

    /// The body of a template: finds the insert and splice holes and
    /// analyzes the expressions in them. Everything else stays data
    fn template(self: *Analyzer, v: Value) Error!ast.Template {
        if (form_head(v)) |head| {
            if (eql(head, "insert")) {
                if (v.data.array.len != 2) return self.fail(v.pos, "insert takes exactly one argument", .{});
                return .{ .insert = try self.expr(v.data.array[1]) };
            }
            if (eql(head, "splice"))
                return self.fail(v.pos, "splice can only be used as an element of an array", .{});
        }
        switch (v.data) {
            .array => |items| {
                const parts = try self.alloc.alloc(ast.TemplatePart, items.len);
                var has_holes = false;
                for (items, parts) |item, *part| {
                    if (form_head(item)) |head| {
                        if (eql(head, "splice")) {
                            if (item.data.array.len != 2) return self.fail(item.pos, "splice takes exactly one argument", .{});
                            part.* = .{ .splice = try self.expr(item.data.array[1]) };
                            has_holes = true;
                            continue;
                        }
                    }
                    part.* = .{ .one = try self.template(item) };
                    if (part.one != .literal) has_holes = true;
                }
                if (!has_holes) return .{ .literal = v };
                return .{ .array = .{ .pos = v.pos, .parts = parts } };
            },
            .object => |pairs| {
                const out = try self.alloc.alloc(ast.TemplatePair, pairs.len);
                var has_holes = false;
                for (pairs, out) |pair, *o| {
                    o.* = .{ .key = pair.key, .value = try self.template(pair.value) };
                    if (o.value != .literal) has_holes = true;
                }
                if (!has_holes) return .{ .literal = v };
                return .{ .object = .{ .pos = v.pos, .pairs = out } };
            },
            else => return .{ .literal = v },
        }
    }

    fn exprs(self: *Analyzer, values: []const Value) Error![]const ast.Expr {
        const out = try self.alloc.alloc(ast.Expr, values.len);
        for (values, out) |val, *e| e.* = try self.expr(val);
        return out;
    }

    // types
    fn type_expr(self: *Analyzer, v: Value) Error!ast.Type {
        switch (v.data) {
            .string => |s| {
                inline for (.{ "i64", "f64", "bool", "str", "null", "data" }) |prim| {
                    if (eql(s, prim)) return @field(ast.Type, prim);
                }
                return self.fail(v.pos, "unknown type \"{s}\"", .{s});
            },
            .object => |pairs| {
                if (pairs.len != 1) return self.fail(v.pos, "a type object must have exactly one key, like {{\"fn\": ...}}", .{});
                const key = pairs[0].key.data.string;
                if (eql(key, "fn")) return .{ .@"fn" = try self.fn_type(pairs[0].value) };
                if (eql(key, "struct") or eql(key, "union"))
                    return self.fail(pairs[0].key.pos, "{s} types are not supported yet", .{key});
                return self.fail(pairs[0].key.pos, "unknown type kind \"{s}\"", .{key});
            },
            else => return self.fail(v.pos, "expected a type: a name like \"i64\" or an object like {{\"fn\": ...}}", .{}),
        }
    }

    /// {"params": [type, ...], "returns": type}
    fn fn_type(self: *Analyzer, v: Value) Error!*const ast.FnType {
        const obj = try self.definition_object(v, "fn type", &.{ "params", "returns" }, &.{ "params", "returns" });
        const params_value = obj.get("params").?;
        const list = switch (params_value.data) {
            .array => |l| l,
            else => return self.fail(params_value.pos, "params of a fn type must be an array of types", .{}),
        };
        const params = try self.alloc.alloc(ast.Type, list.len);
        for (list, params) |p, *t| t.* = try self.type_expr(p);
        const result = try self.alloc.create(ast.FnType);
        result.* = .{ .params = params, .returns = try self.type_expr(obj.get("returns").?) };
        return result;
    }

    // definition objects
    const DefObject = struct {
        pairs: []const reader.Pair,

        fn get(self: DefObject, key: []const u8) ?Value {
            for (self.pairs) |p| if (eql(p.key.data.string, key)) return p.value;
            return null;
        }
    };

    /// Checks that v is an object whose keys are all in allowed and that
    /// every key in required is present.
    fn definition_object(
        self: *Analyzer,
        v: Value,
        what: []const u8,
        allowed: []const []const u8,
        required: []const []const u8,
    ) Error!DefObject {
        const pairs = switch (v.data) {
            .object => |p| p,
            else => return self.fail(v.pos, "{s} needs a definition object here", .{what}),
        };
        for (pairs) |p| {
            const key = p.key.data.string;
            for (allowed) |a| {
                if (eql(a, key)) break;
            } else return self.fail(p.key.pos, "unknown key \"{s}\" in {s}", .{ key, what });
        }
        const obj: DefObject = .{ .pairs = pairs };
        for (required) |r| {
            if (obj.get(r) == null) return self.fail(v.pos, "{s} is missing the \"{s}\" key", .{ what, r });
        }
        return obj;
    }

    // names and strings
    /// A symbol used as a name. Rejects reserved and malformed names
    fn name(self: *Analyzer, v: Value) Error![]const u8 {
        const s = switch (v.data) {
            .string => |s| s,
            else => return self.fail(v.pos, "expected a name", .{}),
        };
        if (s.len == 0) return self.fail(v.pos, "a name can't be empty", .{});
        if (std.mem.indexOfScalar(u8, s, '\\') != null)
            return self.fail(v.pos, "a name can't contain escape sequences", .{});
        if (std.mem.indexOfScalar(u8, s, '.') != null)
            return self.fail(v.pos, "field access (\"{s}\") is not supported yet", .{s});
        if (s[0] == '@') return self.fail(v.pos, "intrinsics (\"{s}\") are not supported yet", .{s});
        for (special_forms) |sf| {
            if (eql(s, sf)) return self.fail(v.pos, "\"{s}\" is a special form and can't be used as a name or value", .{s});
        }
        return s;
    }

    /// The value of a string literal: a JSON string with escapes decoded
    fn string_literal(self: *Analyzer, v: Value) Error![]const u8 {
        const raw = switch (v.data) {
            .string => |s| s,
            else => return self.fail(v.pos, "expected a string", .{}),
        };
        return decode_string(self.alloc, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidEscape => return self.fail(v.pos, "invalid \\u escape in string", .{}),
        };
    }
};

// ── helpers ──────────────────────────────────────────────────────────────

/// If v is a form whose head is a symbol, returns that symbol
fn form_head(v: Value) ?[]const u8 {
    const items = switch (v.data) {
        .array => |items| items,
        else => return null,
    };
    if (items.len == 0) return null;
    return switch (items[0].data) {
        .string => |s| s,
        else => null,
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Converts a byte offset into a 1-based line and column (in bytes, like the reader's diagnostics)
pub fn diagnostic_at(src: []const u8, pos: u32, message: []const u8) Diagnostic {
    var line: u32 = 1;
    var line_start: u32 = 0;
    for (src[0..pos], 0..) |c, i| {
        if (c == '\n') {
            line += 1;
            line_start = @intCast(i + 1);
        }
    }
    return .{ .line = line, .column = pos - line_start + 1, .message = message };
}

/// Decodes the escape sequences of a JSON string's contents. The grammar
/// already guarantees every escape is well-formed; this only has to reject
/// unpaired UTF-16 surrogates in \u escapes.
pub fn decode_string(alloc: Allocator, raw: []const u8) error{ OutOfMemory, InvalidEscape }![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\') {
            try out.append(alloc, raw[i]);
            i += 1;
            continue;
        }
        const c = raw[i + 1];
        i += 2;
        switch (c) {
            'b' => try out.append(alloc, 0x08),
            'f' => try out.append(alloc, 0x0C),
            'n' => try out.append(alloc, '\n'),
            'r' => try out.append(alloc, '\r'),
            't' => try out.append(alloc, '\t'),
            'u' => {
                var cp: u21 = try hex4(raw[i..][0..4]);
                i += 4;
                if (cp >= 0xD800 and cp <= 0xDBFF) {
                    // high surrogate: must be followed by \u + low surrogate
                    if (i + 6 > raw.len or raw[i] != '\\' or raw[i + 1] != 'u') return error.InvalidEscape;
                    const low = try hex4(raw[i + 2 ..][0..4]);
                    if (low < 0xDC00 or low > 0xDFFF) return error.InvalidEscape;
                    i += 6;
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                } else if (cp >= 0xDC00 and cp <= 0xDFFF) {
                    return error.InvalidEscape;
                }
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidEscape;
                try out.appendSlice(alloc, buf[0..n]);
            },
            else => try out.append(alloc, c), // \" \\ \/
        }
    }
    return out.toOwnedSlice(alloc);
}

fn hex4(s: *const [4]u8) error{InvalidEscape}!u21 {
    return std.fmt.parseInt(u21, s, 16) catch error.InvalidEscape;
}

test decode_string {
    const alloc = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "plain", "plain" },
        .{ "a\\nb\\t\\\"q\\\" \\\\ \\/", "a\nb\t\"q\" \\ /" },
        .{ "\\u00e9", "é" },
        .{ "\\ud83d\\ude00", "😀" },
    };
    for (cases) |c| {
        const got = try decode_string(alloc, c[0]);
        defer if (got.ptr != c[0].ptr) alloc.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
    try std.testing.expectError(error.InvalidEscape, decode_string(alloc, "\\ud83d"));
    try std.testing.expectError(error.InvalidEscape, decode_string(alloc, "\\ude00"));
}
