const std = @import("std");
const zls = @import("zls");
const builtin = @import("builtin");

const Ast = std.zig.Ast;

const ComptimeInterpreter = zls.ComptimeInterpreter;
const InternPool = zls.analyser.InternPool;
const Index = InternPool.Index;
const Key = InternPool.Key;
const ast = zls.ast;
const offsets = zls.offsets;

const allocator: std.mem.Allocator = std.testing.allocator;

test "ComptimeInterpreter - primitive types" {
    try testExpr("true", .{ .simple_type = .bool }, .{ .simple_value = .bool_true });
    try testExpr("false", .{ .simple_type = .bool }, .{ .simple_value = .bool_false });
    try testExpr("5", .{ .simple_type = .comptime_int }, .{ .int_u64_value = 5 });
    // TODO try testExpr("-2", .{ .simple_type = .comptime_int }, .{ .int_i64_value = -2 });
    try testExpr("3.0", .{ .simple_type = .comptime_float }, null);

    try testExpr("null", .{ .simple_type = .null_type }, .{ .simple_value = .null_value });
    try testExpr("void", .{ .simple_type = .type }, .{ .simple_type = .void });
    try testExpr("undefined", .{ .simple_type = .undefined_type }, .{ .simple_value = .undefined_value });
    try testExpr("noreturn", .{ .simple_type = .type }, .{ .simple_type = .noreturn });
}

test "ComptimeInterpreter - expressions" {
    if (true) return error.SkipZigTest; // TODO
    try testExpr("5 + 3", .{ .simple_type = .comptime_int }, .{ .int_u64_value = 8 });
    try testExpr("5.2 + 4.2", .{ .simple_type = .comptime_float }, null);

    try testExpr("3 == 3", .{ .simple_type = .bool }, .{ .simple_valueclear = .bool_true });
    try testExpr("5.2 == 2.1", .{ .simple_type = .bool }, .{ .simple_value = .bool_false });

    try testExpr("@as(?bool, null) orelse true", .{ .simple_type = .bool }, .{ .simple_value = .bool_true });
}

test "ComptimeInterpreter - builtins" {
    if (true) return error.SkipZigTest; // TODO
    try testExpr("@as(bool, true)", .{ .simple_type = .bool }, .{ .simple_value = .bool_true });
    try testExpr("@as(u32, 3)", .{ .int_type = .{
        .signedness = .unsigned,
        .bits = 32,
    } }, .{ .int_u64_value = 3 });
}

test "ComptimeInterpreter - string literal" {
    var context = try Context.init(
        \\const foobarbaz = "hello world!";
        \\
    );
    defer context.deinit();
    const result = try context.interpret(context.findVar("foobarbaz"));

    try std.testing.expect(result.ty == .pointer_type);

    try std.testing.expectEqualStrings("hello world!", result.val.?.bytes);
}

test "ComptimeInterpreter - labeled block" {
    try testExpr(
        \\blk: {
        \\    break :blk true;
        \\}
    , .{ .simple_type = .bool }, .{ .simple_value = .bool_true });
    try testExpr(
        \\blk: {
        \\    break :blk 3;
        \\}
    , .{ .simple_type = .comptime_int }, .{ .int_u64_value = 3 });
}

test "ComptimeInterpreter - if" {
    try testExpr(
        \\blk: {
        \\    break :blk if (true) true else false;
        \\}
    , .{ .simple_type = .bool }, .{ .simple_value = .bool_true });
    try testExpr(
        \\blk: {
        \\    break :blk if (false) true else false;
        \\}
    , .{ .simple_type = .bool }, .{ .simple_value = .bool_false });
    try testExpr(
        \\blk: {
        \\    if (false) break :blk true;
        \\    break :blk false;
        \\}
    , .{ .simple_type = .bool }, .{ .simple_value = .bool_false });
    // TODO
    // try testExpr(
    //     \\outer: {
    //     \\    if (:inner {
    //     \\        break :inner true;
    //     \\    }) break :outer true;
    //     \\    break :outer false;
    //     \\}
    // , .{ .simple_type = .bool }, .{ .simple_value = .bool_true });
}

test "ComptimeInterpreter - variable lookup" {
    try testExpr(
        \\blk: {
        \\    var foo = 42;
        \\    break :blk foo;
        \\}
    , .{ .simple_type = .comptime_int }, .{ .int_u64_value = 42 });
    try testExpr(
        \\blk: {
        \\    var foo = 1;
        \\    var bar = 2;
        \\    var baz = 3;
        \\    break :blk bar;
        \\}
    , .{ .simple_type = .comptime_int }, .{ .int_u64_value = 2 });

    var context = try Context.init(
        \\const bar = foo;
        \\const foo = 3;
    );
    defer context.deinit();

    const result = try context.interpret(context.findVar("bar"));
    try expectEqualKey(context.interpreter.ip, .{ .simple_type = .comptime_int }, result.ty);
    try expectEqualKey(context.interpreter.ip, .{ .int_u64_value = 3 }, result.val);
}

test "ComptimeInterpreter - field access" {
    try testExpr(
        \\blk: {
        \\    const foo: struct {alpha: u64, beta: bool} = undefined;
        \\    break :blk foo.beta;
        \\}
    , .{ .simple_type = .bool }, null);
    try testExpr(
        \\blk: {
        \\    const foo: struct {alpha: u64, beta: bool} = undefined;
        \\    break :blk foo.alpha;
        \\}
    , .{ .int_type = .{
        .signedness = .unsigned,
        .bits = 64,
    } }, null);
}

test "ComptimeInterpreter - optional operations" {
    if (true) return error.SkipZigTest; // TODO
    try testExpr(
        \\blk: {
        \\    const foo: ?bool = true;
        \\    break :blk foo.?;
        \\}
    , .{ .simple_type = .bool }, .{ .simple_value = .bool_true });
    try testExpr(
        \\blk: {
        \\    const foo: ?bool = true;
        \\    break :blk foo == null;
        \\}
    , .{ .simple_type = .bool }, .{ .simple_value = .bool_false });
}

test "ComptimeInterpreter - pointer operations" {
    if (true) return error.SkipZigTest; // TODO
    try testExpr(
        \\blk: {
        \\    const foo: []const u8 = "";
        \\    break :blk foo.len;
        \\}
    , .{ .simple_type = .usize }, .{ .bytes = "" });
    try testExpr(
        \\blk: {
        \\    const foo = true;
        \\    break :blk &foo;
        \\}
    , @panic("TODO"), .{ .simple_value = .bool_true });
    try testExpr(
        \\blk: {
        \\    const foo = true;
        \\    const bar = &foo;
        \\    break :blk bar.*;
        \\}
    , @panic("TODO"), .{ .simple_value = .bool_true });
}

test "ComptimeInterpreter - call return primitive type" {
    try testCall(
        \\pub fn Foo() type {
        \\    return bool;
        \\}
    , &.{}, .{ .simple_type = .bool });

    try testCall(
        \\pub fn Foo() type {
        \\    return u32;
        \\}
    , &.{}, .{ .int_type = .{ .signedness = .unsigned, .bits = 32 } });

    try testCall(
        \\pub fn Foo() type {
        \\    return i128;
        \\}
    , &.{}, .{ .int_type = .{ .signedness = .signed, .bits = 128 } });

    try testCall(
        \\pub fn Foo() type {
        \\    const alpha = i128;
        \\    return alpha;
        \\}
    , &.{}, .{ .int_type = .{ .signedness = .signed, .bits = 128 } });
}

test "ComptimeInterpreter - call return struct" {
    var context = try Context.init(
        \\pub fn Foo() type {
        \\    return struct {
        \\        slay: bool,
        \\        var abc = 123;
        \\    };
        \\}
    );
    defer context.deinit();
    const result = try context.call(context.findFn("Foo"), &.{});

    try std.testing.expect(result.ty == .simple_type);
    try std.testing.expect(result.ty.simple_type == .type);
    const struct_info = context.interpreter.ip.getStruct(result.val.?.struct_type);
    try std.testing.expectEqual(Index.none, struct_info.backing_int_ty);
    try std.testing.expectEqual(std.builtin.Type.ContainerLayout.Auto, struct_info.layout);

    try std.testing.expectEqual(@as(usize, 1), struct_info.fields.count());
    try std.testing.expectEqualStrings("slay", struct_info.fields.keys()[0]);
    try std.testing.expect(struct_info.fields.values()[0].ty == Index.bool_type);
}

test "ComptimeInterpreter - call comptime argument" {
    var context = try Context.init(
        \\pub fn Foo(comptime my_arg: bool) type {
        \\    var abc = z: {break :z if (!my_arg) 123 else 0;};
        \\    if (abc == 123) return u69;
        \\    return u8;
        \\}
    );
    defer context.deinit();

    const result1 = try context.call(context.findFn("Foo"), &.{KV{
        .ty = .{ .simple_type = .bool },
        .val = .{ .simple_value = .bool_true },
    }});
    try std.testing.expect(result1.ty == .simple_type);
    try std.testing.expect(result1.ty.simple_type == .type);
    try std.testing.expectEqual(Key{ .int_type = .{ .signedness = .unsigned, .bits = 8 } }, result1.val.?);

    var result2 = try context.call(context.findFn("Foo"), &.{KV{
        .ty = .{ .simple_type = .bool },
        .val = .{ .simple_value = .bool_false },
    }});
    try std.testing.expect(result2.ty == .simple_type);
    try std.testing.expect(result2.ty.simple_type == .type);
    try std.testing.expectEqual(Key{ .int_type = .{ .signedness = .unsigned, .bits = 69 } }, result2.val.?);
}

//
// Helper functions
//

const KV = struct {
    ty: Key,
    val: ?Key,
};

const Context = struct {
    config: *zls.Config,
    document_store: *zls.DocumentStore,
    interpreter: *ComptimeInterpreter,

    pub fn init(source: []const u8) !Context {
        var config = try allocator.create(zls.Config);
        errdefer allocator.destroy(config);

        var document_store = try allocator.create(zls.DocumentStore);
        errdefer allocator.destroy(document_store);

        var interpreter = try allocator.create(ComptimeInterpreter);
        errdefer allocator.destroy(interpreter);

        config.* = .{};
        document_store.* = .{
            .allocator = allocator,
            .config = config,
        };
        errdefer document_store.deinit();

        const test_uri: []const u8 = switch (builtin.os.tag) {
            .windows => "file:///C:\\test.zig",
            else => "file:///test.zig",
        };

        const handle = try document_store.openDocument(test_uri, source);

        interpreter.* = .{
            .allocator = allocator,
            .ip = try InternPool.init(allocator),
            .document_store = document_store,
            .uri = handle.uri,
        };
        errdefer interpreter.deinit();

        _ = try interpretReportErrors(interpreter, 0, .none);

        return .{
            .config = config,
            .document_store = document_store,
            .interpreter = interpreter,
        };
    }

    pub fn deinit(self: *Context) void {
        self.interpreter.deinit();
        self.document_store.deinit();

        allocator.destroy(self.config);
        allocator.destroy(self.document_store);
        allocator.destroy(self.interpreter);
    }

    pub fn call(self: *Context, func_node: Ast.Node.Index, arguments: []const KV) !KV {
        var args = try allocator.alloc(ComptimeInterpreter.Value, arguments.len);
        defer allocator.free(args);

        for (arguments) |argument, i| {
            args[i] = .{
                .interpreter = self.interpreter,
                .node_idx = 0,
                .ty = try self.interpreter.ip.get(self.interpreter.allocator, argument.ty),
                .val = if (argument.val) |val| try self.interpreter.ip.get(self.interpreter.allocator, val) else .none,
            };
        }

        const namespace = @intToEnum(ComptimeInterpreter.Namespace.Index, 0); // root namespace
        const result = (try self.interpreter.call(namespace, func_node, args, .{})).result;

        try std.testing.expect(result == .value);
        try std.testing.expect(result.value.ty != .none);

        return KV{
            .ty = self.interpreter.ip.indexToKey(result.value.ty),
            .val = if (result.value.val == .none) null else self.interpreter.ip.indexToKey(result.value.val),
        };
    }

    pub fn interpret(self: *Context, node: Ast.Node.Index) !KV {
        const namespace = @intToEnum(ComptimeInterpreter.Namespace.Index, 0); // root namespace
        const result = try (try self.interpreter.interpret(node, namespace, .{})).getValue();

        try std.testing.expect(result.ty != .none);

        return KV{
            .ty = self.interpreter.ip.indexToKey(result.ty),
            .val = if (result.val == .none) null else self.interpreter.ip.indexToKey(result.val),
        };
    }

    pub fn findFn(self: Context, name: []const u8) Ast.Node.Index {
        const handle = self.interpreter.getHandle();
        for (handle.tree.nodes.items(.tag)) |tag, i| {
            if (tag != .fn_decl) continue;
            const node = @intCast(Ast.Node.Index, i);
            var buffer: [1]Ast.Node.Index = undefined;
            const fn_decl = handle.tree.fullFnProto(&buffer, node).?;
            const fn_name = offsets.tokenToSlice(handle.tree, fn_decl.name_token.?);
            if (std.mem.eql(u8, fn_name, name)) return node;
        }
        std.debug.panic("failed to find function with name '{s}'", .{name});
    }

    pub fn findVar(self: Context, name: []const u8) Ast.Node.Index {
        const handle = self.interpreter.getHandle();
        var node: Ast.Node.Index = 0;
        while (node < handle.tree.nodes.len) : (node += 1) {
            const var_decl = handle.tree.fullVarDecl(node) orelse continue;
            const name_token = var_decl.ast.mut_token + 1;
            const var_name = offsets.tokenToSlice(handle.tree, name_token);
            if (std.mem.eql(u8, var_name, name)) return var_decl.ast.init_node;
        }
        std.debug.panic("failed to find var declaration with name '{s}'", .{name});
    }
};

fn testCall(
    source: []const u8,
    arguments: []const KV,
    expected_ty: Key,
) !void {
    var context = try Context.init(source);
    defer context.deinit();

    const result = try context.call(context.findFn("Foo"), arguments);

    try expectEqualKey(context.interpreter.ip, Key{ .simple_type = .type }, result.ty);
    try expectEqualKey(context.interpreter.ip, expected_ty, result.val);
}

fn testExpr(
    expr: []const u8,
    expected_ty: Key,
    expected_val: ?Key,
) !void {
    const source = try std.fmt.allocPrint(allocator,
        \\const foobarbaz = {s};
    , .{expr});
    defer allocator.free(source);

    var context = try Context.init(source);
    defer context.deinit();

    const result = try context.interpret(context.findVar("foobarbaz"));

    try expectEqualKey(context.interpreter.ip, expected_ty, result.ty);
    if (expected_val) |expected| {
        try expectEqualKey(context.interpreter.ip, expected, result.val);
    }
}

/// TODO refactor this code
fn expectEqualKey(ip: InternPool, expected: Key, actual: ?Key) !void {
    if (actual) |actual_key| {
        if (expected.eql(actual_key)) return;

        if (expected.isType() and actual_key.isType()) {
            std.debug.print("expected type `{}`, found type `{}`\n", .{ expected.fmtType(ip), actual_key.fmtType(ip) });
        } else if (expected.isType()) {
            std.debug.print("expected type `{}`, found value ({})\n", .{ expected.fmtType(ip), actual_key });
        } else if (actual_key.isType()) {
            std.debug.print("expected value ({}), found type `{}`\n", .{ expected, actual_key.fmtType(ip) });
        } else {
            std.debug.print("expected value ({}), found value ({})\n", .{ expected, actual_key }); // TODO print value
        }
    } else {
        if (expected.isType()) {
            std.debug.print("expected type `{}`, found null\n", .{expected.fmtType(ip)});
        } else {
            std.debug.print("expected value ({}), found null\n", .{expected});
        }
    }
    return error.TestExpectedEqual;
}

fn interpretReportErrors(
    interpreter: *ComptimeInterpreter,
    node_idx: Ast.Node.Index,
    namespace: InternPool.NamespaceIndex,
) !ComptimeInterpreter.InterpretResult {
    const result = interpreter.interpret(node_idx, namespace, .{});

    // TODO use ErrorBuilder
    var err_it = interpreter.errors.iterator();
    if (interpreter.errors.count() != 0) {
        const handle = interpreter.getHandle();
        std.debug.print("\n{s}\n", .{handle.text});
        while (err_it.next()) |entry| {
            const token = handle.tree.firstToken(entry.key_ptr.*);
            const position = offsets.tokenToPosition(handle.tree, token, .@"utf-8");
            std.debug.print("{d}:{d}: {s}\n", .{ position.line, position.character, entry.value_ptr.message });
        }
    }
    return result;
}
