//! Fuzz Tests for ObjectID Operations
//!
//! Uses the fuzzing framework to test edge cases and invariants.

const std = @import("std");
const FuzzInput = @import("fuzz_framework.zig").FuzzInput;
const ObjectID = @import("../../src/core.zig").ObjectID;

// Fuzz test: ObjectID group operation associativity
test "Fuzz: ObjectID add associativity" {
    const seed = @as(u64, @intCast(blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); }));
    var rng = std.Random.DefaultPrng.init(seed);
    
    // Run many iterations with random data
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        // Generate 3 random 32-byte sequences
        var a_data: [32]u8 = undefined;
        var b_data: [32]u8 = undefined;
        var c_data: [32]u8 = undefined;
        
        rng.random().bytes(&a_data);
        rng.random().bytes(&b_data);
        rng.random().bytes(&c_data);
        
        const a = ObjectID.hash(&a_data);
        const b = ObjectID.hash(&b_data);
        const c = ObjectID.hash(&c_data);
        
        // (a + b) + c = a + (b + c)
        const abc1 = a.add(b).add(c);
        const abc2 = a.add(b.add(c));
        
        if (!abc1.eql(abc2)) {
            std.debug.panic("ObjectID associativity failed", .{});
        }
    }
}

// Fuzz test: ObjectID zero identity
test "Fuzz: ObjectID zero identity" {
    const seed = @as(u64, @intCast(blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); }));
    var rng = std.Random.DefaultPrng.init(seed);
    
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        var data: [32]u8 = undefined;
        rng.random().bytes(&data);
        
        const a = ObjectID.hash(&data);
        const az = a.add(ObjectID.zero);
        const za = ObjectID.zero.add(a);
        
        if (!az.eql(a)) {
            std.debug.panic("ObjectID zero identity failed (a + 0 != a)", .{});
        }
        if (!za.eql(a)) {
            std.debug.panic("ObjectID zero identity failed (0 + a != a)", .{});
        }
    }
}

// Fuzz test: ObjectID self-inverse
test "Fuzz: ObjectID self-inverse" {
    const seed = @as(u64, @intCast(blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); }));
    var rng = std.Random.DefaultPrng.init(seed);
    
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        var data: [32]u8 = undefined;
        rng.random().bytes(&data);
        
        const a = ObjectID.hash(&data);
        const aa = a.add(a);
        
        if (!aa.eql(ObjectID.zero)) {
            std.debug.panic("ObjectID self-inverse failed (a + a != 0)", .{});
        }
    }
}

// Fuzz test: ObjectID negation involution
test "Fuzz: ObjectID negation involution" {
    const seed = @as(u64, @intCast(blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); }));
    var rng = std.Random.DefaultPrng.init(seed);
    
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        var data: [32]u8 = undefined;
        rng.random().bytes(&data);
        
        const a = ObjectID.hash(&data);
        const neg_neg_a = a.negate().negate();
        
        if (!neg_neg_a.eql(a)) {
            std.debug.panic("ObjectID negation involution failed", .{});
        }
    }
}

// Fuzz test: ObjectID commutativity
test "Fuzz: ObjectID commutativity" {
    const seed = @as(u64, @intCast(blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); }));
    var rng = std.Random.DefaultPrng.init(seed);
    
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        var a_data: [32]u8 = undefined;
        var b_data: [32]u8 = undefined;
        rng.random().bytes(&a_data);
        rng.random().bytes(&b_data);
        
        const a = ObjectID.hash(&a_data);
        const b = ObjectID.hash(&b_data);
        
        const ab = a.add(b);
        const ba = b.add(a);
        
        if (!ab.eql(ba)) {
            std.debug.panic("ObjectID commutativity failed", .{});
        }
    }
}

// Fuzz test: ObjectID fromBytes validation
test "Fuzz: ObjectID fromBytes validation" {
    const seed = @as(u64, @intCast(blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); }));
    var rng = std.Random.DefaultPrng.init(seed);
    
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        // Generate exactly 32 bytes - should always succeed
        var data: [32]u8 = undefined;
        rng.random().bytes(&data);
        
        const id = ObjectID.hash(&data);
        const roundtrip = try ObjectID.fromBytes(&data);
        
        if (!id.eql(roundtrip)) {
            std.debug.panic("ObjectID fromBytes roundtrip failed", .{});
        }
    }
    
    // Test rejection of wrong-length inputs
    const short = "too short";
    const short_result = ObjectID.fromBytes(short);
    if (short_result != error.InvalidLength) {
        std.debug.panic("ObjectID.fromBytes should reject short input", .{});
    }
}

// Fuzz test: ObjectID hash determinism
test "Fuzz: ObjectID hash determinism" {
    const seed = @as(u64, @intCast(blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts); break :blk (ts.sec); }));
    var rng = std.Random.DefaultPrng.init(seed);
    
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        const size = rng.random().uintAtMost(usize, 256);
        var data: [256]u8 = undefined;
        rng.random().bytes(&data);
        
        const hash1 = ObjectID.hash(data[0..size]);
        const hash2 = ObjectID.hash(data[0..size]);
        
        if (!hash1.eql(hash2)) {
            std.debug.panic("ObjectID hash not deterministic", .{});
        }
        
        // Hash should not be zero for non-empty input
        if (size > 0 and hash1.isZero()) {
            std.debug.panic("ObjectID hash produced zero for non-empty input", .{});
        }
    }
}
