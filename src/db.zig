const std = @import("std");
const Allocator = std.mem.Allocator;
const StructField = std.builtin.Type.StructField;

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

fn crud_for_table(comptime table: anytype, TableId: anytype) type {
    return struct {
        const Self = @This();
        map: std.AutoArrayHashMapUnmanaged(TableId, table) = .empty,

        pub fn get(self: *Self, id: TableId) ?table {
            return self.map.get(id);
        }

        pub fn create(self: *Self, gpa: Allocator, object: table) !TableId {
            try self.map.put(gpa, TableId.unassigned, object);
            return .unassigned;
        }
    };
}
