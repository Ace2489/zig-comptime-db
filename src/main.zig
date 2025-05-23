const std = @import("std");
const assert = std.debug.assert;
const DBType = @import("./db.zig").DBType;
const Account = struct {
    id: ID = .unassigned,
    balance: u128,
    pub const ID = enum(u64) {
        unassigned,
        _,
    };
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
    .indexes = .{
        .transfer = .{
            .debit_account, .credit_account,
        },
    },
});
fn create_transfer(
    db: *DB,
    gpa: std.mem.Allocator,
    debit_account: Account.ID,
    credit_account: Account.ID,
    amount: u128,
) !?Transfer.ID {
    if (debit_account == credit_account)
        return null;

    const dr = db.account.get(debit_account) orelse return null;
    const cr = db.account.get(credit_account) orelse return null;

    if (dr.balance < amount) return null;
    if (cr.balance > std.math.maxInt(u128) - amount) return null;

    db.account.update(.{
        .id = debit_account,
        .balance = dr.balance - amount,
    });

    db.account.update(.{
        .id = credit_account,
        .balance = cr.balance + amount,
    });

    return try db.transfer.create(gpa, .{
        .debit_account = debit_account,
        .credit_account = credit_account,
        .amount = amount,
    });
}
pub fn main() !void {
    var gpa_instance: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_instance.deinit();
    const debug = gpa_instance.allocator();
    var arena = std.heap.ArenaAllocator.init(debug);
    defer arena.deinit();
    const gpa = arena.allocator();
    var random_instance = std.Random.DefaultPrng.init(92);
    const random = random_instance.random();
    var db: DB = .{};
    // defer db.deinit(gpa);

    // var account: Account = .{ .balance = 1234 };
    // var account2: Account = .{ .balance = 5678 };
    // const id = try db.account.create(gpa, &account);
    // const id2 = try db.account.create(gpa, &account2);
    // std.debug.print("{}\n", .{id});
    // std.debug.print("{any}\n", .{db.account.get(id)});
    // std.debug.print("{any}\n", .{db.account.get(id2)});

    const alice: Account.ID =
        try db.account.create(gpa, .{ .balance = 100 });

    // // inline for (0..3) |_| {
    // //     _ = try db.account.create(gpa, .{ .balance = 100 });
    // // }
    // // const fetched = db.account.get(alice);

    const bob: Account.ID =
        try db.account.create(gpa, .{ .balance = 200 });
    const transfer =
        try create_transfer(&db, gpa, alice, bob, 100);
    assert(transfer != null);
    var accounts: std.ArrayListUnmanaged(Account.ID) = .empty;
    defer accounts.deinit(gpa);
    const account_count = 100;
    try accounts.ensureTotalCapacity(gpa, account_count);
    accounts.appendAssumeCapacity(alice);
    accounts.appendAssumeCapacity(bob);
    while (accounts.items.len < account_count) {
        const account =
            try db.account.create(gpa, .{ .balance = 1000 });
        accounts.appendAssumeCapacity(account);
    }
    const transfer_count = 100;
    for (0..transfer_count) |_| {
        const debit = pareto_index(random, account_count);
        const credit = pareto_index(random, account_count);
        const amount = random.uintLessThan(u128, 10);
        _ = try create_transfer(
            &db,
            gpa,
            accounts.items[debit],
            accounts.items[credit],
            amount,
        );
    }

    for (0..db.account.store.nodes.items.len / 10) |i| {
        std.debug.print("Account Details:{any}\n", .{db.account.get(@enumFromInt(i))});
        std.debug.print("Transfer Details:{any}\n\n", .{db.transfer.get(@enumFromInt(i))});
    }

    // var transfers_buffer: [10]Transfer = undefined;
    // const alice_transfers = db.transfer.filter(.{ .debit_account = alice }, &transfers_buffer);
    // for (alice_transfers) |t| {
    //     std.debug.print("alice: from={} to={} amount={}\n", .{
    //         t.debit_account,
    //         t.credit_account,
    //         t.amount,
    //     });
    // }
    // std.debug.print("\n\n", .{});
    // const alice_to_bob_transfers = db.transfer.filter(
    //     .{ .debit_account = alice, .credit_account = bob },
    //     &transfers_buffer,
    // );
    // for (alice_to_bob_transfers) |t| {
    //     std.debug.print("alice to bob: from={} to={} amount={}\n", .{
    //         t.debit_account,
    //         t.credit_account,
    //         t.amount,
    //     });
    // }
}
fn pareto_index(random: std.Random, count: usize) usize {
    assert(count > 0);
    const hot = @divFloor(count * 2, 10);
    if (hot == 0) return random.uintLessThan(usize, count);
    if (random.uintLessThan(u32, 10) < 8) return pareto_index(random, hot);
    return hot + random.uintLessThan(usize, count - hot);
}
