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

        pub fn create(self: *Self, gpa: Allocator, object: *Table) !TableId {
            self.last_id += 1;
            const id = self.last_id;
            object.*.id = @enumFromInt(id);
            const result = try self.store.getOrPut(gpa, .{ .key = object.*.id, .value = object.* });
            result.update_value();
            return object.*.id;
        }
        fn compare_fn(a: TableId, b: TableId) std.math.Order {
            return std.math.order(@intFromEnum(a), @intFromEnum(b));
        }
    };
}
