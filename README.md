# ZigDb

An in-memory, non-relational database for Zig, where schemas are defined at compile time.

**Quick Note**: The base API design is inspired by Matklad’s [article](https://matklad.github.io/2025/03/19/comptime-zig-orm.html), but the storage engine and much of the implementation are original.

## What Is This?

ZigDb is a library you can import into Zig applications.

* Schemas are defined at **compile time**.
* Supports CRUD (**C**reate, **R**ead, **U**pdate, **D**elete).
* Provides query operators like `filter`, `range`, and `order` (currently only `filter` is implemented).
* Allows field-level indexing for performance.

## Installation

```bash
zig fetch --save git+https://github.com/Ace2489/zig-comptime-db
```

```zig
// build.zig
const db = b.dependency("zigdb");
exe_mod.addImport("zigdb", db.module("zigdb"));
```

```zig
// In your Zig source file
const db = @import("zigdb");
```

## Initialisation

### Defining a Schema

Each table is defined as a `struct` with an `ID` field serving as the primary key.

```zig
const db = @import("zigdb");
const DBType = db.DBType;

const Account = struct {
    id: ID = .unassigned,
    balance: u128,
    pub const ID = enum(u64) { unassigned, _ };
};

const Transfer = struct {
    id: ID = .unassigned,
    amount: u128,
    debit_account: Account.ID,
    credit_account: Account.ID,
    pub const ID = enum(u64) { unassigned, _ };
};

const DB = DBType(.{
    .tables = .{ .account = Account, .transfer = Transfer },
    .indexes = .{ .transfer = .{ .debit_account, .credit_account } },
});
```

* Every table must define an `ID` enum.
* The `unassigned` variant marks rows before the database assigns an ID.
* Foreign keys are represented by using another table’s ID type as a field.
* Indexes are optional: pass `.{}` to `indexes` if you don’t need any.
Here’s the continuation of the README, documenting the completed methods based on your implementation. I’ll keep the style consistent with the earlier sections.

### Instantiating the Database

Once you’ve defined your schema and generated a `DBType`, you can create an instance of the database. For example:

```zig
var gpa = std.heap.DebugAllocator(.{}).init;
defer _ = gpa.deinit();
const allocator = gpa.allocator();

var db = DB{ .account = .{}, .transfer = .{} };
defer db.deinit(allocator);
```

The database instance contains one field per table in your schema (in our example, `.account` and `.transfer`), each of which provides CRUD operations and indexing.

## CRUD Operations

### Create

You can insert new records into a table using `create` or `createAssumeCapacity`.

```zig
const account_id = try db.account.create(allocator, .{
    .id = .unassigned,
    .balance = 1000,
});
```

* `create(allocator, record)`
  Allocates capacity (if necessary) and inserts the record. Returns the new record’s ID.
* `createAssumeCapacity(record)`
  Inserts the record assuming capacity has already been reserved with `reserve`. Faster, but unsafe if space isn’t available.

#### Reserving capacity

To avoid reallocations when bulk-inserting:

```zig
try db.account.reserve(allocator, 10);
```

This reserves enough space for 10 more records in both the table and its indexes.

---

### Read

Fetch records directly by primary key:

```zig
const maybe_account = db.account.get(account_id);
if (maybe_account) |acct| {
    std.debug.print("Account balance = {}\n", .{acct.balance});
}
```

You can also get a direct slice over the entire table:

```zig
for (db.account.slice()) |acct| {
    std.debug.print("id={}, balance={}\n", .{acct.id, acct.balance});
}
```

**NOTE**: Mutating items from this slice will directly modify the table. Use with caution.

---

### Update

Update an existing record in-place, with automatic index maintenance:

```zig
var acct = db.account.get(account_id).?;
acct.balance += 500;
db.account.update(acct);
```

* If the record does not exist, nothing happens.
* All relevant indexes are updated atomically.

---

### Delete

//Under construction 

## Indexing

When defining the schema, you can specify which fields to index:

```zig
const DB = DBType(.{
    .tables = .{ .account = Account, .transfer = Transfer },
    .indexes = .{
        .transfer = .{ .debit_account, .credit_account },
    },
});
```

For the `transfer` table, two secondary indexes are generated (`debit_account` and `credit_account`). These enable faster lookups and filters when those fields are part of a query.

Indexes are used internally for faster updates and filtering. You normally won’t interact with them directly unless you're hacking on the internals of the database. 

Be careful not to corrupt data when accessing them directly.

For example, each table (e.g. `account`) exposes its indexes under the `indexes` field:

```zig
var debit_account_index = &db.account.indexes.debit_account;
```

Both the indexes and the primary storage are currently implemented with a red-black tree ([source](https://github.com/Ace2489/red-black-tree.zig)).


### Error Handling

* `error{fullDatabase}` — Raised when trying to insert past the maximum number of allowed records (`MAX_IDX`).
* Assertions will panic if internal invariants are violated (e.g., an index drifts out of sync, or an unknown field is accessed).

