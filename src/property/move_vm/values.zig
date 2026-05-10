//! Move VM Value System
//! Based on knot3bot/move-vm reference implementation.
//!
//! Core types:
//! - Container: heap-allocated, ref-counted collection (struct or vector)
//! - ValueImpl: tagged union of all Move value types
//! - Value: public wrapper with safe accessors
//! - IntegerValue: type-safe checked arithmetic wrapper

const std = @import("std");

/// Abilities for Move types
pub const AbilitySet = struct {
    can_copy: bool = true,
    can_drop: bool = true,
    can_store: bool = true,
    is_key: bool = false,

    pub fn default() AbilitySet {
        return .{};
    }

    pub fn resource() AbilitySet {
        return .{ .can_copy = false, .can_drop = true, .can_store = true, .is_key = true };
    }
};

/// A heap-allocated container (struct or vector fields).
/// Ref-counted for borrow semantics.
pub const Container = struct {
    kind: Kind,
    data: std.ArrayList(ValueImpl),
    abilities: AbilitySet,
    ref_count: u32,

    pub const Kind = enum { Vec, Struct };

    pub fn new(allocator: std.mem.Allocator, kind: Kind, abilities: AbilitySet) !*Container {
        const ptr = try allocator.create(Container);
        ptr.* = .{
            .kind = kind,
            .data = std.ArrayList(ValueImpl).empty,
            .abilities = abilities,
            .ref_count = 0,
        };
        return ptr;
    }

    pub fn copyValue(self: *Container, allocator: std.mem.Allocator) !*Container {
        const ptr = try allocator.create(Container);
        errdefer allocator.destroy(ptr);
        ptr.* = .{
            .kind = self.kind,
            .data = std.ArrayList(ValueImpl).empty,
            .abilities = self.abilities,
            .ref_count = 0,
        };
        errdefer {
            for (ptr.data.items) |*item| item.deinit(allocator);
            ptr.data.deinit(allocator);
        }
        for (self.data.items) |item| {
            try ptr.data.append(allocator, try item.copyValue(allocator));
        }
        return ptr;
    }

    pub fn deinit(self: *Container, allocator: std.mem.Allocator) void {
        self.checkedDeinit(allocator) catch |err| {
            std.log.warn("Container.deinit: {} ({}) — forcing deinit with {} active borrows", .{ @errorName(err), self.ref_count });
            // Force deinit even with active borrows
            for (self.data.items) |*item| item.deinit(allocator);
            self.data.deinit(allocator);
            allocator.destroy(self);
        };
    }

    /// Checked deinit — returns error if active borrows exist.
    pub fn checkedDeinit(self: *Container, allocator: std.mem.Allocator) !void {
        if (self.ref_count > 0) return error.BorrowedResource;
        for (self.data.items) |*item| item.deinit(allocator);
        self.data.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn equals(self: *Container, other: *Container) !bool {
        if (self.kind != other.kind) return false;
        if (self.data.items.len != other.data.items.len) return false;
        for (self.data.items, other.data.items) |a, b| {
            if (!try a.equals(b)) return false;
        }
        return true;
    }
};

/// A reference to a container (for borrow semantics).
pub const ContainerRef = struct {
    container: *Container,
    is_mutable: bool = true,
};

/// A reference to an element inside a container.
pub const IndexedRef = struct {
    container_ref: ContainerRef,
    idx: usize,
};

/// Internal representation of a Move value.
pub const ValueImpl = union(enum) {
    Invalid,
    U8: u8,
    U16: u16,
    U32: u32,
    U64: u64,
    U128: u128,
    U256: u256,
    Bool: bool,
    Address: [32]u8,
    Container: *Container,
    ContainerRef: ContainerRef,
    IndexedRef: IndexedRef,

    pub fn copyValue(self: ValueImpl, allocator: std.mem.Allocator) !ValueImpl {
        return switch (self) {
            .Invalid => .Invalid,
            .U8 => |x| .{ .U8 = x },
            .U16 => |x| .{ .U16 = x },
            .U32 => |x| .{ .U32 = x },
            .U64 => |x| .{ .U64 = x },
            .U128 => |x| .{ .U128 = x },
            .U256 => |x| .{ .U256 = x },
            .Bool => |x| .{ .Bool = x },
            .Address => |x| .{ .Address = x },
            .Container => |c| .{ .Container = try c.copyValue(allocator) },
            .ContainerRef => |r| {
                r.container.ref_count += 1;
                return .{ .ContainerRef = .{ .container = r.container, .is_mutable = r.is_mutable } };
            },
            .IndexedRef => |r| {
                r.container_ref.container.ref_count += 1;
                return .{ .IndexedRef = .{ .container_ref = .{ .container = r.container_ref.container, .is_mutable = r.container_ref.is_mutable }, .idx = r.idx } };
            },
        };
    }

    pub fn equals(self: ValueImpl, other: ValueImpl) !bool {
        const tag_a = std.meta.activeTag(self);
        const tag_b = std.meta.activeTag(other);
        if (tag_a != tag_b) return false;
        return switch (self) {
            .Invalid => true,
            .U8 => |a| a == other.U8,
            .U16 => |a| a == other.U16,
            .U32 => |a| a == other.U32,
            .U64 => |a| a == other.U64,
            .U128 => |a| a == other.U128,
            .U256 => |a| a == other.U256,
            .Bool => |a| a == other.Bool,
            .Address => |a| std.mem.eql(u8, &a, &other.Address),
            .Container => |a| try a.equals(other.Container),
            .ContainerRef => |a| a.container == other.ContainerRef.container,
            .IndexedRef => |a| a.container_ref.container == other.IndexedRef.container_ref.container and a.idx == other.IndexedRef.idx,
        };
    }

    pub fn deinit(self: *ValueImpl, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .Container => |c| c.deinit(allocator),
            .ContainerRef => |r| r.container.ref_count -= 1,
            .IndexedRef => |r| r.container_ref.container.ref_count -= 1,
            else => {},
        }
    }

    pub fn readRef(self: ValueImpl, allocator: std.mem.Allocator) !ValueImpl {
        return switch (self) {
            .ContainerRef => |r| .{ .Container = try r.container.copyValue(allocator) },
            .IndexedRef => |r| {
                if (r.idx >= r.container_ref.container.data.items.len) return error.IndexOutOfBounds;
                return try r.container_ref.container.data.items[r.idx].copyValue(allocator);
            },
            else => error.TypeMismatch,
        };
    }

    pub fn writeRef(self: *ValueImpl, allocator: std.mem.Allocator, value: ValueImpl) !void {
        switch (self.*) {
            .ContainerRef => |*r| {
                if (!r.is_mutable) return error.InvalidReference;
                switch (value) {
                    .Container => |src| {
                        for (r.container.data.items) |*item| item.deinit(allocator);
                        r.container.data.clearRetainingCapacity();
                        for (src.data.items) |item| {
                            try r.container.data.append(try item.copyValue(allocator));
                        }
                    },
                    else => return error.TypeMismatch,
                }
            },
            .IndexedRef => |*r| {
                if (!r.container_ref.is_mutable) return error.InvalidReference;
                if (r.idx >= r.container_ref.container.data.items.len) return error.IndexOutOfBounds;
                r.container_ref.container.data.items[r.idx].deinit(allocator);
                r.container_ref.container.data.items[r.idx] = try value.copyValue(allocator);
            },
            else => return error.TypeMismatch,
        }
    }

    pub fn borrowElem(self: ValueImpl, idx: usize) !ValueImpl {
        return switch (self) {
            .ContainerRef => |r| {
                if (r.container.kind != .Vec) return error.TypeMismatch;
                if (idx >= r.container.data.items.len) return error.IndexOutOfBounds;
                r.container.ref_count += 1;
                return .{ .IndexedRef = .{ .container_ref = r, .idx = idx } };
            },
            else => error.TypeMismatch,
        };
    }

    pub fn borrowField(self: ValueImpl, idx: usize) !ValueImpl {
        return switch (self) {
            .ContainerRef => |r| {
                if (r.container.kind != .Struct) return error.TypeMismatch;
                if (idx >= r.container.data.items.len) return error.IndexOutOfBounds;
                r.container.ref_count += 1;
                return .{ .IndexedRef = .{ .container_ref = r, .idx = idx } };
            },
            else => error.TypeMismatch,
        };
    }

    pub fn canCopy(self: ValueImpl) bool {
        return switch (self) {
            .Container => |c| c.abilities.can_copy,
            else => true,
        };
    }

    pub fn canDrop(self: ValueImpl) bool {
        return switch (self) {
            .Container => |c| c.abilities.can_drop,
            else => true,
        };
    }

    pub fn isKey(self: ValueImpl) bool {
        return switch (self) {
            .Container => |c| c.abilities.is_key,
            else => false,
        };
    }
};

/// Public wrapper around ValueImpl.
pub const Value = struct {
    impl: ValueImpl,

    pub fn init(impl: ValueImpl) Value {
        return .{ .impl = impl };
    }

    pub fn makeU8(x: u8) Value { return .{ .impl = .{ .U8 = x } }; }
    pub fn makeU16(x: u16) Value { return .{ .impl = .{ .U16 = x } }; }
    pub fn makeU32(x: u32) Value { return .{ .impl = .{ .U32 = x } }; }
    pub fn makeU64(x: u64) Value { return .{ .impl = .{ .U64 = x } }; }
    pub fn makeU128(x: u128) Value { return .{ .impl = .{ .U128 = x } }; }
    pub fn makeU256(x: u256) Value { return .{ .impl = .{ .U256 = x } }; }
    pub fn makeBool(x: bool) Value { return .{ .impl = .{ .Bool = x } }; }
    pub fn address(x: [32]u8) Value { return .{ .impl = .{ .Address = x } }; }

    pub fn copyValue(self: Value, allocator: std.mem.Allocator) !Value {
        return .{ .impl = try self.impl.copyValue(allocator) };
    }

    pub fn equals(self: Value, other: Value) !bool {
        return try self.impl.equals(other.impl);
    }

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        self.impl.deinit(allocator);
    }

    pub fn isResource(self: Value) bool {
        return self.impl.isKey();
    }
};

/// Integer value wrapper for checked arithmetic operations.
pub const IntegerValue = union(enum) {
    U8: u8,
    U16: u16,
    U32: u32,
    U64: u64,
    U128: u128,
    U256: u256,

    pub fn fromValue(v: Value) !IntegerValue {
        return switch (v.impl) {
            .U8 => |x| .{ .U8 = x },
            .U16 => |x| .{ .U16 = x },
            .U32 => |x| .{ .U32 = x },
            .U64 => |x| .{ .U64 = x },
            .U128 => |x| .{ .U128 = x },
            .U256 => |x| .{ .U256 = x },
            else => error.TypeMismatch,
        };
    }

    pub fn toValue(self: IntegerValue) Value {
        return switch (self) {
            .U8 => |x| Value.makeU8(x),
            .U16 => |x| Value.makeU16(x),
            .U32 => |x| Value.makeU32(x),
            .U64 => |x| Value.makeU64(x),
            .U128 => |x| Value.makeU128(x),
            .U256 => |x| Value.makeU256(x),
        };
    }

    pub fn addChecked(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| .{ .U8 = try std.math.add(u8, x, b.U8) },
            .U16 => |x| .{ .U16 = try std.math.add(u16, x, b.U16) },
            .U32 => |x| .{ .U32 = try std.math.add(u32, x, b.U32) },
            .U64 => |x| .{ .U64 = try std.math.add(u64, x, b.U64) },
            .U128 => |x| .{ .U128 = try std.math.add(u128, x, b.U128) },
            .U256 => |x| .{ .U256 = try std.math.add(u256, x, b.U256) },
        };
    }

    pub fn subChecked(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| .{ .U8 = try std.math.sub(u8, x, b.U8) },
            .U16 => |x| .{ .U16 = try std.math.sub(u16, x, b.U16) },
            .U32 => |x| .{ .U32 = try std.math.sub(u32, x, b.U32) },
            .U64 => |x| .{ .U64 = try std.math.sub(u64, x, b.U64) },
            .U128 => |x| .{ .U128 = try std.math.sub(u128, x, b.U128) },
            .U256 => |x| .{ .U256 = try std.math.sub(u256, x, b.U256) },
        };
    }

    pub fn mulChecked(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| .{ .U8 = try std.math.mul(u8, x, b.U8) },
            .U16 => |x| .{ .U16 = try std.math.mul(u16, x, b.U16) },
            .U32 => |x| .{ .U32 = try std.math.mul(u32, x, b.U32) },
            .U64 => |x| .{ .U64 = try std.math.mul(u64, x, b.U64) },
            .U128 => |x| .{ .U128 = try std.math.mul(u128, x, b.U128) },
            .U256 => |x| .{ .U256 = try std.math.mul(u256, x, b.U256) },
        };
    }

    pub fn divChecked(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        if (b.isZero()) return error.DivisionByZero;
        return switch (a) {
            .U8 => |x| .{ .U8 = try std.math.divTrunc(u8, x, b.U8) },
            .U16 => |x| .{ .U16 = try std.math.divTrunc(u16, x, b.U16) },
            .U32 => |x| .{ .U32 = try std.math.divTrunc(u32, x, b.U32) },
            .U64 => |x| .{ .U64 = try std.math.divTrunc(u64, x, b.U64) },
            .U128 => |x| .{ .U128 = try std.math.divTrunc(u128, x, b.U128) },
            .U256 => |x| .{ .U256 = try std.math.divTrunc(u256, x, b.U256) },
        };
    }

    pub fn remChecked(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        if (b.isZero()) return error.DivisionByZero;
        return switch (a) {
            .U8 => |x| .{ .U8 = try std.math.rem(u8, x, b.U8) },
            .U16 => |x| .{ .U16 = try std.math.rem(u16, x, b.U16) },
            .U32 => |x| .{ .U32 = try std.math.rem(u32, x, b.U32) },
            .U64 => |x| .{ .U64 = try std.math.rem(u64, x, b.U64) },
            .U128 => |x| .{ .U128 = try std.math.rem(u128, x, b.U128) },
            .U256 => |x| .{ .U256 = try std.math.rem(u256, x, b.U256) },
        };
    }

    pub fn bitAnd(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| .{ .U8 = x & b.U8 },
            .U16 => |x| .{ .U16 = x & b.U16 },
            .U32 => |x| .{ .U32 = x & b.U32 },
            .U64 => |x| .{ .U64 = x & b.U64 },
            .U128 => |x| .{ .U128 = x & b.U128 },
            .U256 => |x| .{ .U256 = x & b.U256 },
        };
    }

    pub fn bitOr(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| .{ .U8 = x | b.U8 },
            .U16 => |x| .{ .U16 = x | b.U16 },
            .U32 => |x| .{ .U32 = x | b.U32 },
            .U64 => |x| .{ .U64 = x | b.U64 },
            .U128 => |x| .{ .U128 = x | b.U128 },
            .U256 => |x| .{ .U256 = x | b.U256 },
        };
    }

    pub fn bitXor(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| .{ .U8 = x ^ b.U8 },
            .U16 => |x| .{ .U16 = x ^ b.U16 },
            .U32 => |x| .{ .U32 = x ^ b.U32 },
            .U64 => |x| .{ .U64 = x ^ b.U64 },
            .U128 => |x| .{ .U128 = x ^ b.U128 },
            .U256 => |x| .{ .U256 = x ^ b.U256 },
        };
    }

    pub fn shlChecked(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| {
                if (b.U8 >= 8) return error.Overflow;
                return .{ .U8 = try std.math.shlExact(u8, x, @intCast(b.U8)) };
            },
            .U16 => |x| {
                if (b.U16 >= 16) return error.Overflow;
                return .{ .U16 = try std.math.shlExact(u16, x, @intCast(b.U16)) };
            },
            .U32 => |x| {
                if (b.U32 >= 32) return error.Overflow;
                return .{ .U32 = try std.math.shlExact(u32, x, @intCast(b.U32)) };
            },
            .U64 => |x| {
                if (b.U64 >= 64) return error.Overflow;
                return .{ .U64 = try std.math.shlExact(u64, x, @intCast(b.U64)) };
            },
            .U128 => |x| {
                if (b.U128 >= 128) return error.Overflow;
                return .{ .U128 = try std.math.shlExact(u128, x, @intCast(b.U128)) };
            },
            .U256 => |x| {
                if (b.U256 >= 256) return error.Overflow;
                return .{ .U256 = x << @as(u8, @intCast(b.U256)) };
            },
        };
    }

    pub fn shrChecked(a: IntegerValue, b: IntegerValue) !IntegerValue {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| .{ .U8 = x >> @as(u3, @intCast(b.U8)) },
            .U16 => |x| .{ .U16 = x >> @as(u4, @intCast(b.U16)) },
            .U32 => |x| .{ .U32 = x >> @as(u5, @intCast(b.U32)) },
            .U64 => |x| .{ .U64 = x >> @as(u6, @intCast(b.U64)) },
            .U128 => |x| .{ .U128 = x >> @as(u7, @intCast(b.U128)) },
            .U256 => |x| .{ .U256 = x >> @as(u8, @intCast(b.U256)) },
        };
    }

    pub fn lt(a: IntegerValue, b: IntegerValue) !bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| x < b.U8,
            .U16 => |x| x < b.U16,
            .U32 => |x| x < b.U32,
            .U64 => |x| x < b.U64,
            .U128 => |x| x < b.U128,
            .U256 => |x| x < b.U256,
        };
    }

    pub fn gt(a: IntegerValue, b: IntegerValue) !bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| x > b.U8,
            .U16 => |x| x > b.U16,
            .U32 => |x| x > b.U32,
            .U64 => |x| x > b.U64,
            .U128 => |x| x > b.U128,
            .U256 => |x| x > b.U256,
        };
    }

    pub fn le(a: IntegerValue, b: IntegerValue) !bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| x <= b.U8,
            .U16 => |x| x <= b.U16,
            .U32 => |x| x <= b.U32,
            .U64 => |x| x <= b.U64,
            .U128 => |x| x <= b.U128,
            .U256 => |x| x <= b.U256,
        };
    }

    pub fn ge(a: IntegerValue, b: IntegerValue) !bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return error.TypeMismatch;
        return switch (a) {
            .U8 => |x| x >= b.U8,
            .U16 => |x| x >= b.U16,
            .U32 => |x| x >= b.U32,
            .U64 => |x| x >= b.U64,
            .U128 => |x| x >= b.U128,
            .U256 => |x| x >= b.U256,
        };
    }

    fn isZero(self: IntegerValue) bool {
        return switch (self) {
            .U8 => |x| x == 0,
            .U16 => |x| x == 0,
            .U32 => |x| x == 0,
            .U64 => |x| x == 0,
            .U128 => |x| x == 0,
            .U256 => |x| x == 0,
        };
    }
};

/// Struct value helpers.
pub const StructValue = struct {
    pub fn pack(allocator: std.mem.Allocator, fields: []const Value, abilities: AbilitySet) !Value {
        const container = try Container.new(allocator, .Struct, abilities);
        errdefer container.deinit(allocator);
        for (fields) |field| {
            try container.data.append(allocator, (try field.copyValue(allocator)).impl);
        }
        return Value.init(.{ .Container = container });
    }
};

/// Vector value helpers.
pub const VectorValue = struct {
    pub fn pack(allocator: std.mem.Allocator, elements: []const Value, abilities: AbilitySet) !Value {
        const container = try Container.new(allocator, .Vec, abilities);
        errdefer container.deinit(allocator);
        for (elements) |elem| {
            try container.data.append(allocator, (try elem.copyValue(allocator)).impl);
        }
        return Value.init(.{ .Container = container });
    }

    pub fn len(value: Value) !usize {
        switch (value.impl) {
            .Container => |c| {
                if (c.kind != .Vec) return error.TypeMismatch;
                return c.data.items.len;
            },
            else => return error.TypeMismatch,
        }
    }
};
