# ZigDb

An in-memory, non-relational database for Zig, where schemas are defined at compile time.

**Quick Note**: The base API design is inspired by Matklad’s [article](https://matklad.github.io/2025/03/19/comptime-zig-orm.html), but the storage engine and much of the implementation are original.

## What Is This?

ZigDb is a library you can import into Zig applications.

* Schemas are defined at **compile time**.
* Supports CRUD (**C**reate, **R**ead, **U**pdate, **D**elete).
* Provides query operators like `filter`, `range`, and `order` (currently, only `filter` is implemented).
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
const Bundle = @import("zigdb");
```

## Initialisation

### Defining a Schema

Each table is defined as a `struct` with an `ID` field serving as the primary key.

```zig
const Bundle = @import("zigdb");
const DBType = Bundle.DBType;

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

### Instantiating the Database

Once you’ve defined your schema and generated a `DBType`, you can create an instance of the database. For example:

```zig
var gpa = std.heap.DebugAllocator(.{}).init;
defer _ = gpa.deinit();
const allocator = gpa.allocator();

var db = DB{};
defer Bundle.deinit(&db, allocator);
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

* `create(allocator, record) allocates capacity (if necessary) and inserts the record. Returns the new record’s ID.
* `createAssumeCapacity(record) inserts the record assuming capacity has already been reserved with `reserve`. 

#### Reserving capacity

To avoid reallocations when bulk-inserting:

```zig
try db.account.reserve(allocator, 10);
```

This reserves enough space for 10 more records in both the table and its indexes.

### Read

Fetch records directly by primary key:

```zig
const maybe_account = db.account.get(account_id);
if (maybe_account) |acct| {
    std.debug.print("Account balance = {}\n", .{acct.balance});
}
```

You can also get a direct, **unsorted** slice of the entire table:

```zig
for (db.account.slice()) |acct| {
    std.debug.print("id={}, balance={}\n", .{acct.id, acct.balance});
}
```

**NOTE**: Mutating items from this slice will directly modify the table.

### Update

Update an existing record in-place.

```zig
var acct = db.account.get(account_id).?;
acct.balance += 500;
try db.account.update(acct);
```

* Returns an error if the record does not exist.
* All relevant indexes are updated automatically.

---

### Delete

You can delete a record by ID:
```zig
const deleted = db.account.delete(acct_id);

if (deleted) |record| {
    std.debug.print("Deleted account with balance: {}\n", .{record.balance});
}
```

All index entries are also removed.

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

### Accessing Indexes

Each table (e.g. `account`) exposes its indexes under the `indexes` field:

```zig
var debit_account_index = &db.account.indexes.debit_account;
```

Both the indexes and the primary storage are currently implemented with a red-black tree ([source](https://github.com/Ace2489/red-black-tree.zig)).

## Architecture

The database consists of two main components: the **Engine** and the **Database Constructor**.

### 1. The Engine

The engine is responsible for the **storage, organization, and retrieval of data** in tables and indexes. It guarantees data integrity and provides the low-level operations upon which the rest of the system is built.

The current implementation uses a [Red-Black Tree](https://github.com/Ace2489/red-black-tree.zig/) as its underlying data structure. More info can be found at the repository. 

### 2. The Database Constructor (`DBType`)

The database constructor is the higher-level component, implemented primarily in `db.zig`.
Its role is to **take a schema definition and generate a fully-typed database at compile time** using Zig’s reflection capabilities.

At a high level, the `DBType` function does the following:

* **Schema Processing:**
  Scans the provided schema to discover tables and indexes.
* **CRUD Generation:**
  For each table, it generates CRUD operations that wrap the engine’s raw methods with a more user-friendly API.
  This logic lives in the `crud_for_table` function.
* **Index Management:**
  For each declared index, it generates index structures and integrates them into the CRUD operations so indexes remain consistent with table data.
  This is handled in the `generate_indexes` function.

The result is a statically-typed database tailored to the schema, with compile-time guarantees around structure and indexing.
