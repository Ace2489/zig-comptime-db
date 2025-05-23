const std = @import("std");
const Allocator = std.mem.Allocator;
const StructField = std.builtin.Type.StructField;
const Tree = @import("llrb").Tree;

pub fn DBType(comptime config: anytype) type {
    const Tables = @typeInfo(@TypeOf(config.tables)).@"struct";

    var struct_fields: [Tables.fields.len]StructField = undefined;
    for (Tables.fields, 0..) |field, i| {
        const table_name = field.name;
        const TableSchema = @field(config.tables, table_name);
        const TableId = @FieldType(TableSchema, "id");

        const CrudOps = crud_for_table(TableSchema, TableId);
        const crud: CrudOps = .{};

        struct_fields[i] = .{ .name = table_name, .type = CrudOps, .default_value_ptr = &crud, .is_comptime = false, .alignment = @alignOf(CrudOps) };
    }

    // const decl = [1]std.builtin.Type.Declaration{.{ .name = "deinit" }};
    const Schema = @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &struct_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
    return Schema;
}

fn crud_for_table(comptime Table: anytype, TableId: anytype) type {
    return struct {
        const Self = @This();
        store: Tree(TableId, Table, compare_fn) = .empty,
        last_id: u64 = 0,

        pub fn get(self: *Self, id: TableId) ?Table {
            return self.store.search(id);
        }

        pub fn create(self: *Self, gpa: Allocator, object: Table) !TableId {
            self.last_id += 1;
            const id = self.last_id;
            var obj = object;
            obj.id = @enumFromInt(id);
            const result = try self.store.getOrPut(gpa, .{ .key = obj.id, .value = obj });
            result.update_value();
            return obj.id;
        }
        pub fn compare_fn(a: TableId, b: TableId) std.math.Order {
            return std.math.order(@intFromEnum(a), @intFromEnum(b));
        }

        pub fn update(self: *Self, fields: anytype) void {
            // const names = @typeInfo(@TypeOf(fields)).@"struct".fields;
            if (!@hasField(@TypeOf(fields), "id")) {
                std.debug.print("No id\n", .{});
                return;
            }
            _ = self.store.update(.{ .key = fields.id, .value = fields });
            return;
        }
        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.deinit(gpa);
        }
    };
}
