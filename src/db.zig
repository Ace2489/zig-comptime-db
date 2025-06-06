const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const StructField = std.builtin.Type.StructField;
const Tree = @import("llrb").Tree;

pub fn DBType(comptime config: anytype) type {
    assert(@hasField(@TypeOf(config), "tables"));
    assert(@hasField(@TypeOf(config), "indexes"));

    const Tables = @typeInfo(@TypeOf(config.tables)).@"struct";

    const Indexes = config.indexes;

    var struct_fields: [Tables.fields.len]StructField = undefined;
    for (Tables.fields, 0..) |field, i| {
        const table_name = field.name;
        const TableSchema = @field(config.tables, table_name);
        const TableId = @FieldType(TableSchema, "id");

        const IndexedFields = if (@hasField(@TypeOf(Indexes), table_name)) @field(Indexes, table_name) else .{};

        // const IndexFieldsInfo = @typeInfo(@TypeOf(IndexedFields)).@"struct";

        // const indexed_fields = comptime blk: {
        //     var names: [IndexFieldsInfo.fields.len][:0]const u8 = undefined;
        //     for (IndexFieldsInfo.fields, 0..) |_, j| {
        //         names[j] = @tagName(IndexedFields[j]);
        //     }
        //     break :blk names;
        // };

        const CrudOps = crud_for_table(TableSchema, TableId, IndexedFields);
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

fn crud_for_table(comptime Table: anytype, TableId: anytype, comptime IndexBlock: anytype) type {
    return struct {
        const Self = @This();
        const Indexes = generate_indexes(Table, IndexBlock);
        store: Tree(TableId, Table, compare_fn) = .empty,
        last_id: u64 = 0,
        indexes: Indexes = .{},

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

            _ = self.store.search(fields.id) orelse return;
            _ = self.store.update(.{ .key = fields.id, .value = fields }) orelse return; //the update failed. no need to modify the index

            // const field_type = @typeInfo(@TypeOf(fields)).@"struct".fields;
            // //field: id
            // //field: balance

            // inline for (field_type) |f| {
            //     const field_name = f.name;
            //     if (std.mem.eql(u8, field_name, "id")) continue;
            //     if (self.indexes.get(field_name)) |index| {
            //         //This field has been modified. delete the entry in the index and re-insert it
            //         const index_entry = .{ @field(fields, field_name), @field(fields, "id") };
            //         index.delete(.{ @field(old, field_name), @field(fields, "id") });
            //         index.put(index_entry);
            //     }
            // }
            return;
        }
        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.deinit(gpa);
        }
    };
}

fn generate_indexes(comptime Table: type, comptime IndexBlock: anytype) type {
    const index_info = @typeInfo(@TypeOf(IndexBlock)).@"struct";
    var fields: [index_info.fields.len]std.builtin.Type.StructField = undefined;
    // var buffer: [100]u8 = undefined;
    // @memset(&buffer, 0);
    // _ = try std.fmt.bufPrint(&buffer, "Noooo: {}", .{fields.len});
    // if (true) @compileError("Noooo " ++ buffer);

    for (index_info.fields, 0..) |_, i| {
        const field_name = @tagName(IndexBlock[i]);
        // Validate field exists
        if (!@hasField(Table, field_name)) {
            @compileError("Table " ++ @typeName(Table) ++
                " has no field '" ++ field_name ++ "'");
        }

        // Get field type
        const FieldType = @FieldType(Table, field_name);

        // Define composite key
        const KeyType = struct {
            field_value: FieldType,
            record_id: Table.ID,
        };

        // Create comparison function
        const compare = struct {
            fn cmp(a: KeyType, b: KeyType) std.math.Order {
                const val_cmp = compare_values(a.field_value, b.field_value);
                if (val_cmp != .eq) return val_cmp;
                return std.math.order(@intFromEnum(a.record_id), @intFromEnum(b.record_id));
            }
        }.cmp;

        // Create tree type
        const IndexTree = Tree(KeyType, void, compare);

        fields[i] = .{
            .name = field_name,
            .type = IndexTree,
            .default_value_ptr = &IndexTree.empty,
            .is_comptime = false,
            .alignment = @alignOf(IndexTree),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

fn compare_values(a: anytype, b: @TypeOf(a)) std.math.Order {
    const T = @TypeOf(a);
    return switch (@typeInfo(T)) {
        .int, .float, .comptime_int, .comptime_float => std.math.order(a, b),
        .@"enum" => std.math.order(@intFromEnum(a), @intFromEnum(b)),
        .bool => std.math.order(@intFromBool(a), @intFromBool(b)),
        .pointer => |pointerInfo| {
            if (pointerInfo.child == u8 and pointerInfo.size == .slice) return std.mem.order(u8, a, b);
            @compileError("Unsupported type for index: " ++ @typeName(T));
        },
        else => @compileError("Unsupported type for index: " ++ @typeName(T)),
    };
}
