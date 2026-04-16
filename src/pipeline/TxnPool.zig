//! TransactionPool - Manages pending transactions for execution
//!
//! Implements a priority queue for transactions based on gas price and sequence number.

const std = @import("std");
const core = @import("../core.zig");
const Ingress = @import("Ingress.zig");

/// Transaction with metadata for scheduling
pub const PoolTransaction = struct {
    tx: *Ingress.Transaction,
    gas_price: u64,
    received_at: i64,
};

/// Transaction pool configuration
pub const TxnPoolConfig = struct {
    /// Maximum transactions in pool
    max_size: usize = 50000,
    /// Minimum gas price acceptance
    min_gas_price: u64 = 1000,
    /// Transaction timeout in seconds
    timeout_seconds: i64 = 300,
};

/// Priority queue ordering function (higher gas_price = higher priority)
/// Note: Using void context to avoid circular dependency with TxnPool
fn txnPoolOrder(_: void, a: PoolTransaction, b: PoolTransaction) std.math.Order {
    return std.math.order(b.gas_price, a.gas_price);
}

/// Transaction pool - manages pending transactions with priority queue
pub const TxnPool = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: TxnPoolConfig,

    /// Priority queue for transactions ordered by gas price
    priority_queue: std.PriorityQueue(PoolTransaction, void, txnPoolOrder),

    /// Pending transactions by sender (sequence-based ordering)
    by_sender: std.AutoArrayHashMapUnmanaged([32]u8, std.ArrayList(PoolTransaction)),

    /// Received count for metrics
    received_count: u64,
    /// Executed count for metrics
    executed_count: u64,

    pub fn init(allocator: std.mem.Allocator, config: TxnPoolConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .priority_queue = std.PriorityQueue(PoolTransaction, void, txnPoolOrder).initContext({}),
            .by_sender = std.AutoArrayHashMapUnmanaged([32]u8, std.ArrayList(PoolTransaction)).empty,
            .received_count = 0,
            .executed_count = 0,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        // Clean up priority queue
        while (self.priority_queue.pop()) |ptx| {
            ptx.tx.deinit(self.allocator);
            self.allocator.destroy(ptx.tx);
        }
        self.priority_queue.deinit(self.allocator);

        // Clean up by_sender map
        var it = self.by_sender.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |ptx| {
                ptx.tx.deinit(self.allocator);
                self.allocator.destroy(ptx.tx);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.by_sender.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    /// Add a transaction to the pool
    pub fn add(self: *Self, tx: Ingress.Transaction, gas_price: u64) !void {
        // Check pool size
        if (self.priority_queue.count() >= self.config.max_size) {
            return error.PoolFull;
        }

        // Check minimum gas price
        if (gas_price < self.config.min_gas_price) {
            return error.GasPriceTooLow;
        }

        // Check for duplicate (same sender + sequence)
        if (self.by_sender.getPtr(tx.sender)) |existing| {
            for (existing.items) |ptx| {
                if (ptx.tx.sequence == tx.sequence) {
                    return error.DuplicateTransaction;
                }
            }
        }

        // Allocate and copy the transaction
        const tx_ptr = try self.allocator.create(Ingress.Transaction);
        tx_ptr.* = tx;

        const pool_tx = PoolTransaction{
            .tx = tx_ptr,
            .gas_price = gas_price,
            .received_at = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); },
        };

        // Add to sender's list
        const sender_list = try self.by_sender.getOrPut(self.allocator, tx.sender);
        if (!sender_list.found_existing) {
            sender_list.value_ptr.* = std.ArrayList(PoolTransaction).empty;
        }
        try sender_list.value_ptr.append(self.allocator, pool_tx);

        // Add to priority queue
        try self.priority_queue.push(self.allocator, pool_tx);

        self.received_count += 1;
    }

    /// Get next transaction for execution (highest gas price first)
    pub fn next(self: *Self) ?Ingress.Transaction {
        // Lazy expiry check at front of queue
        self.skipExpired();

        const ptx = self.priority_queue.pop() orelse return null;
        self.executed_count += 1;

        // Remove from sender's tracking
        if (self.by_sender.getPtr(ptx.tx.sender)) |list| {
            for (list.items, 0..) |item, idx| {
                if (item.tx.sequence == ptx.tx.sequence) {
                    _ = list.swapRemove(idx);
                    break;
                }
            }
        }

        // Return the transaction and ownership to caller
        const result = ptx.tx.*;
        self.allocator.destroy(ptx.tx);
        return result;
    }

    /// Peek at the next transaction without removing it
    pub fn peek(self: *Self) ?*const PoolTransaction {
        return self.priority_queue.peek();
    }

    /// Remove expired transactions - optimized lazy expiry approach
    pub fn removeExpired(self: *Self) usize {
        const now = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); };
        var removed: usize = 0;

        // Use a temporary queue to rebuild without expired items
        var valid_txs = std.ArrayList(PoolTransaction).init(self.allocator);
        defer valid_txs.deinit();

        // Note: This is O(n) but bounded by max_size (50k) and only called periodically
        // For better scalability, consider a min-heap by timestamp in production
        while (self.priority_queue.removeOrNull()) |ptx| {
            if (now - ptx.received_at > self.config.timeout_seconds) {
                ptx.tx.deinit(self.allocator);
                self.allocator.destroy(ptx.tx);
                removed += 1;
            } else {
                valid_txs.append(ptx) catch {
                    ptx.tx.deinit(self.allocator);
                    self.allocator.destroy(ptx.tx);
                    continue;
                };
            }
        }

        // Re-add valid transactions - O(n log n)
        for (valid_txs.items) |ptx| {
            self.priority_queue.push(self.allocator, ptx) catch {
                ptx.tx.deinit(self.allocator);
                self.allocator.destroy(ptx.tx);
            };
        }

        return removed;
    }

    /// Check and skip expired transactions at front of queue (lazy expiry)
    pub fn skipExpired(self: *Self) void {
        const now = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); };
        while (self.priority_queue.peek()) |ptx| {
            if (now - ptx.received_at > self.config.timeout_seconds) {
                _ = self.priority_queue.pop();
                ptx.tx.deinit(self.allocator);
                self.allocator.destroy(ptx.tx);
            } else {
                break;
            }
        }
    }

    /// Get pool statistics
    pub fn stats(self: Self) PoolStats {
        return .{
            .pool_size = self.priority_queue.count(),
            .received_total = self.received_count,
            .executed_total = self.executed_count,
            .sender_count = self.by_sender.count(),
        };
    }

    /// Check if pool has transactions for specific sender
    pub fn hasPendingForSender(self: Self, sender: [32]u8) bool {
        if (self.by_sender.get(sender)) |list| {
            return list.items.len > 0;
        }
        return false;
    }

    /// Get pending count for sender
    pub fn pendingForSender(self: Self, sender: [32]u8) usize {
        if (self.by_sender.get(sender)) |list| {
            return list.items.len;
        }
        return 0;
    }

    /// Get the current highest gas price in the pool
    pub fn highestGasPrice(self: *Self) ?u64 {
        if (self.priority_queue.peek()) |ptx| {
            return ptx.gas_price;
        }
        return null;
    }
};

/// Pool statistics
pub const PoolStats = struct {
    pool_size: usize,
    received_total: u64,
    executed_total: u64,
    sender_count: usize,
};

test "TxnPool basic operations" {
    const allocator = std.testing.allocator;
    var pool = try TxnPool.init(allocator, .{});
    defer pool.deinit();

    const tx = Ingress.Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = try allocator.dupe(u8, "test"),
        .gas_budget = 1000,
        .sequence = 1,
    };

    try pool.add(tx, 1000);

    try std.testing.expect(pool.stats().pool_size == 1);
    try std.testing.expect(pool.stats().received_total == 1);

    const next = pool.next();
    try std.testing.expect(next != null);
    try std.testing.expect(next.?.sequence == 1);

    try std.testing.expect(pool.stats().pool_size == 0);
}

test "TxnPool rejects duplicate" {
    const allocator = std.testing.allocator;
    var pool = try TxnPool.init(allocator, .{});
    defer pool.deinit();

    const tx = Ingress.Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = "test",
        .gas_budget = 1000,
        .sequence = 1,
    };

    try pool.add(tx, 1000);
    try std.testing.expectError(error.DuplicateTransaction, pool.add(tx, 1000));
}

test "TxnPool rejects low gas price" {
    const allocator = std.testing.allocator;
    var pool = try TxnPool.init(allocator, .{ .min_gas_price = 1000 });
    defer pool.deinit();

    const tx = Ingress.Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = "test",
        .gas_budget = 1000,
        .sequence = 1,
    };

    try std.testing.expectError(error.GasPriceTooLow, pool.add(tx, 500));
}

test "TxnPool priority ordering" {
    const allocator = std.testing.allocator;
    var pool = try TxnPool.init(allocator, .{});
    defer pool.deinit();

    // Add transactions with different gas prices
    const tx1 = Ingress.Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = "tx1",
        .gas_budget = 1000,
        .sequence = 1,
    };
    try pool.add(tx1, 100); // Low gas price

    const tx2 = Ingress.Transaction{
        .sender = [_]u8{2} ** 32,
        .inputs = &.{},
        .program = "tx2",
        .gas_budget = 1000,
        .sequence = 1,
    };
    try pool.add(tx2, 500); // Medium gas price

    const tx3 = Ingress.Transaction{
        .sender = [_]u8{3} ** 32,
        .inputs = &.{},
        .program = "tx3",
        .gas_budget = 1000,
        .sequence = 1,
    };
    try pool.add(tx3, 1000); // High gas price

    // Should get highest gas price first
    const first = pool.next();
    try std.testing.expect(first != null);
    try std.testing.expect(first.?.sender[0] == 3); // sender 3 had highest gas price

    const second = pool.next();
    try std.testing.expect(second != null);
    try std.testing.expect(second.?.sender[0] == 2);

    const third = pool.next();
    try std.testing.expect(third != null);
    try std.testing.expect(third.?.sender[0] == 1);
}

test "TxnPool tracks multiple senders" {
    const allocator = std.testing.allocator;
    var pool = try TxnPool.init(allocator, .{});
    defer pool.deinit();

    const tx1 = Ingress.Transaction{
        .sender = [_]u8{1} ** 32,
        .inputs = &.{},
        .program = "test1",
        .gas_budget = 1000,
        .sequence = 1,
    };

    const tx2 = Ingress.Transaction{
        .sender = [_]u8{2} ** 32,
        .inputs = &.{},
        .program = "test2",
        .gas_budget = 1000,
        .sequence = 1,
    };

    try pool.add(tx1, 1000);
    try pool.add(tx2, 1000);

    try std.testing.expect(pool.stats().sender_count == 2);
    try std.testing.expect(pool.hasPendingForSender([_]u8{1} ** 32));
    try std.testing.expect(pool.hasPendingForSender([_]u8{2} ** 32));
}
