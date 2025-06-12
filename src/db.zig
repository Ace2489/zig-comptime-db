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

            //todo: Make it more explicit that this will replace a value if it already exists
            const result = try self.store.getOrPut(gpa, .{ .key = obj.id, .value = obj });
            assert(result.kv_index == 0xFFFFFFFF);
            result.update_value();

            inline for (@typeInfo(Indexes).@"struct".fields) |f| {
                assert(@hasField(Table, f.name));
                var index_tree = &@field(self.indexes, f.name);
                const res = try index_tree.getOrPut(gpa, .{ .key = .{ .field_value = @field(obj, f.name), .record_id = obj.id }, .value = {} });
                res.update_value();
            }

            return obj.id;
        }
        pub fn compare_fn(a: TableId, b: TableId) std.math.Order {
            return std.math.order(@intFromEnum(a), @intFromEnum(b));
        }

        pub fn filter(self: *Self, query: anytype, buf: []Table, comptime buf_len: usize) []Table {
            const Query = @TypeOf(query);

            const query_fields = @typeInfo(Query).@"struct".fields;

            comptime var indexed_field: ?[]const u8 = null;

            comptime {
                for (query_fields) |f| {
                    if (!@hasField(Table, f.name)) @compileError("Table does not have field '" ++ f.name ++ "'");
                    if (@hasField(Indexes, f.name) and indexed_field == null) {
                        indexed_field = f.name;
                    }
                }
            }

            if (indexed_field) |index_field| {
                const index = &@field(self.indexes, index_field);
                const field_value = @field(query, index_field);
                const Index = @FieldType(Indexes, index_field);
                const IndexKey = @FieldType(Index.KV, "key");

                const Id = @typeInfo(@FieldType(IndexKey, "record_id")).@"enum".tag_type;

                const max_id: Id = std.math.maxInt(Id);

                var buf_ids: [buf_len]IndexKey = undefined;

                const initial = index.filter(.{ .field_value = field_value, .record_id = @enumFromInt(0) }, .{ .field_value = field_value, .record_id = @enumFromInt(max_id) }, &buf_ids);

                var count: usize = 0;

                for (0..initial) |i| {
                    const record = self.store.search(buf_ids[i].record_id) orelse @panic("This shouldn't happen");

                    const matches = blk: {
                        inline for (query_fields) |f| {
                            comptime if (std.mem.eql(u8, f.name, index_field)) continue;
                            const field_filter = @field(query, f.name);
                            if (compare_values(@field(record, f.name), field_filter) != .eq) break :blk false;
                        }
                        break :blk true;
                    };

                    if (matches and i < buf_len) {
                        buf[i] = record;
                        count += 1;
                    }
                }
                return buf[0..count];
            }
            //No index field to filter with
            const records = self.store.kv_list.items(.value);

            var count: usize = 0;
            for (records) |record| {
                const matches = blk: {
                    inline for (query_fields) |f| {
                        const field_value = @field(query, f.name);
                        if (compare_values(@field(record, f.name), field_value) != .eq) break :blk false;
                    }
                    break :blk true;
                };
                if (matches and count < buf.len) {
                    buf[count] = record;
                    count += 1;
                }
            }
            return buf[0..count];
        }
        pub fn update(self: *Self, fields: anytype) void {
            if (!@hasField(@TypeOf(fields), "id")) {
                std.debug.print("No id to update\n", .{});
                return;
            }

            _ = self.store.search(fields.id) orelse {
                std.debug.print("No entity with the id:{} found in the table", .{fields.id});
                return;
            };

            _ = self.store.update(.{ .key = fields.id, .value = fields }) orelse {
                std.debug.print("Update failed", .{});
                return;
            }; //the update failed. no need to modify the index

            // const UpdatedFields = @typeInfo(@TypeOf(fields)).@"struct".fields;
            // // //field: id
            // // //field:

            // inline for (1..UpdatedFields.len) |i| {
            //     // if (std.mem.eql(u8, f.name, "id")) continue;
            //     const f = UpdatedFields[i];
            //     if (!@hasField(Indexes, f.name)) continue;
            //     const field_index_tree = @field(self.indexes, f.name);
            //     const old_index_entry = .{ @field(old, f.name), fields.id };
            //     field_index_tree.delete(old_index_entry);

            //     std.debug.print("Old index entry: {}\n", .{old_index_entry});
            //     const new_index_entry = .{ .key = .{ @field(fields, f.name), fields.id }, .value = void };

            //     std.debug.print("New index entry: {}\n\n", .{new_index_entry});
            //     field_index_tree.getOrPut(new_index_entry);
            // }

            return;
        }
        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.store.deinit(gpa);
        }
    };
}

fn generate_indexes(comptime Table: type, comptime IndexBlock: anytype) type {
    const index_info = @typeInfo(@TypeOf(IndexBlock)).@"struct";
    var fields: [index_info.fields.len]std.builtin.Type.StructField = undefined;

    for (index_info.fields, 0..) |_, i| {
        const field_name = @tagName(IndexBlock[i]);
        if (!@hasField(Table, field_name)) {
            @compileError("Table " ++ @typeName(Table) ++
                " has no field '" ++ field_name ++ "'");
        }

        const FieldType = @FieldType(Table, field_name);

        const KeyType = struct {
            field_value: FieldType,
            record_id: Table.ID,
        };
        const compare = struct {
            fn cmp(a: KeyType, b: KeyType) std.math.Order {
                const val_cmp = compare_values(a.field_value, b.field_value);
                if (val_cmp != .eq) return val_cmp;
                return std.math.order(@intFromEnum(a.record_id), @intFromEnum(b.record_id));
            }
        }.cmp;

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
