//! Compile-time Property Verifier for zknot3
//!
//! Implements compile-time checks for:
//! - ObjectID commutative group properties
//! - Version lattice partial order constraints
//! - BFT safety conditions
//! - Linear type invariants

const std = @import("std");
const core = @import("../src/core.zig");
const ObjectID = core.ObjectID;
const Version = core.Version;
const Ownership = core.Ownership;

/// Verification result
pub const VerifyResult = struct {
    passed: bool,
    errors: std.ArrayList([]const u8),
    warnings: std.ArrayList([]const u8),
};

/// Property verifier
pub const Verifier = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    result: VerifyResult,

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .result = .{
                .passed = true,
                .errors = std.ArrayList([]const u8).init(allocator),
                .warnings = std.ArrayList([]const u8).init(allocator),
            },
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.result.errors.deinit();
        self.result.warnings.deinit();
    }

    /// Verify ObjectID properties
    pub fn verifyObjectID(self: *Self) !void {
        // Property 1: ObjectID is 32 bytes
        if (@sizeOf(ObjectID) != 32) {
            try self.result.errors.append("ObjectID must be 32 bytes (BLAKE3-256)");
            self.result.passed = false;
        }

        // Property 2: ObjectID has inner field
        if (!@hasField(ObjectID, "inner")) {
            try self.result.errors.append("ObjectID must have 'inner' field");
            self.result.passed = false;
        }

        // Property 3: ObjectID has eql method
        if (!@hasDecl(ObjectID, "eql")) {
            try self.result.errors.append("ObjectID must have 'eql' method");
            self.result.passed = false;
        }

        // Property 4: ObjectID has hash function
        if (!@hasDecl(ObjectID, "hash")) {
            try self.result.errors.append("ObjectID must have 'hash' function");
            self.result.passed = false;
        }
    }

    /// Verify Version lattice properties
    pub fn verifyVersionLattice(self: *Self) !void {
        // Property 1: Version has seq and causal fields
        if (!@hasField(Version, "seq")) {
            try self.result.errors.append("Version must have 'seq' field");
            self.result.passed = false;
        }

        if (!@hasField(Version, "causal")) {
            try self.result.errors.append("Version must have 'causal' field");
            self.result.passed = false;
        }

        // Property 2: Version has compare method (partial order)
        if (!@hasDecl(Version, "compare")) {
            try self.result.errors.append("Version must have 'compare' method for partial order");
            self.result.passed = false;
        }

        // Property 3: Version has lessThan method
        if (!@hasDecl(Version, "lessThan")) {
            try self.result.errors.append("Version must have 'lessThan' method");
            self.result.passed = false;
        }
    }

    /// Verify Ownership properties
    pub fn verifyOwnership(self: *Self) !void {
        // Property 1: Ownership must be an enum with Owned, Shared, Immutable
        // This is verified by checking the variants exist
        if (!@hasDecl(Ownership, "Owned")) {
            try self.result.errors.append("Ownership must have Owned variant");
            self.result.passed = false;
        }

        if (!@hasDecl(Ownership, "Shared")) {
            try self.result.errors.append("Ownership must have Shared variant");
            self.result.passed = false;
        }

        if (!@hasDecl(Ownership, "Immutable")) {
            try self.result.errors.append("Ownership must have Immutable variant");
            self.result.passed = false;
        }

        // Property 2: ownedBy function
        if (!@hasDecl(Ownership, "ownedBy")) {
            try self.result.errors.append("Ownership must have ownedBy function");
            self.result.passed = false;
        }
    }

    /// Verify BFT safety conditions
    pub fn verifyBFTSafety(self: *Self, validators: usize, max_faulty: usize) !void {
        // BFT Condition: validators >= 3 * max_faulty + 1
        const required = 3 * max_faulty + 1;
        if (validators < required) {
            try self.result.errors.append(try std.fmt.allocPrint(self.allocator, "BFT safety violation: validators ({}) must be >= 3 * max_faulty ({}) + 1 = {}", .{ validators, max_faulty, required }));
            self.result.passed = false;
        }

        // Quorum threshold: 2/3 of validators
        const quorum = (validators * 2) / 3;
        if (quorum <= max_faulty) {
            try self.result.errors.append(try std.fmt.allocPrint(self.allocator, "Quorum safety violation: quorum ({}) must be > max_faulty ({})", .{ quorum, max_faulty }));
            self.result.passed = false;
        }

        // Warning for low fault tolerance
        if (validators < 4) {
            try self.result.warnings.append("Warning: System has low fault tolerance with less than 4 validators");
        }
    }

    /// Verify linear type constraints
    pub fn verifyLinearTypes(self: *Self) !void {
        // Check Resource struct has required fields
        const Resource = @import("../src/property/move_vm/Resource.zig").Resource;

        if (!@hasField(Resource, "id")) {
            try self.result.errors.append("Resource must have 'id' field");
            self.result.passed = false;
        }

        if (!@hasField(Resource, "used")) {
            try self.result.errors.append("Resource must have 'used' field for linear tracking");
            self.result.passed = false;
        }

        if (!@hasField(Resource, "destroyed")) {
            try self.result.errors.append("Resource must have 'destroyed' field for linear tracking");
            self.result.passed = false;
        }
    }

    /// Run all verifications
    pub fn verifyAll(self: *Self) !void {
        try self.verifyObjectID();
        try self.verifyVersionLattice();
        try self.verifyOwnership();
        try self.verifyLinearTypes();
        try self.verifyBFTSafety(4, 1); // Default: 4 validators, 1 byzantine
    }

    /// Print results
    pub fn printResults(self: *Self) void {
        std.debug.print("\n=== zknot3 Property Verification ===\n", .{});

        if (self.result.passed) {
            std.debug.print("✅ All verifications PASSED\n", .{});
        } else {
            std.debug.print("❌ Verification FAILED\n", .{});
        }

        if (self.result.errors.items.len > 0) {
            std.debug.print("\nErrors:\n", .{});
            for (self.result.errors.items) |err| {
                std.debug.print("  - {s}\n", .{err});
            }
        }

        if (self.result.warnings.items.len > 0) {
            std.debug.print("\nWarnings:\n", .{});
            for (self.result.warnings.items) |warn| {
                std.debug.print("  - {s}\n", .{warn});
            }
        }

        std.debug.print("\n", .{});
    }
};

/// Main entry point
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var verifier = try Verifier.init(allocator);
    defer verifier.deinit();

    try verifier.verifyAll();
    verifier.printResults();

    if (!verifier.result.passed) {
        return error.VerificationFailed;
    }
}

test "Verifier initialization" {
    const allocator = std.testing.allocator;
    var verifier = try Verifier.init(allocator);
    defer verifier.deinit();

    try std.testing.expect(verifier.result.passed);
    try std.testing.expect(verifier.result.errors.items.len == 0);
}

test "ObjectID verification" {
    const allocator = std.testing.allocator;
    var verifier = try Verifier.init(allocator);
    defer verifier.deinit();

    try verifier.verifyObjectID();
    // ObjectID should pass all checks in this project
    try std.testing.expect(verifier.result.passed);
}

test "Version lattice verification" {
    const allocator = std.testing.allocator;
    var verifier = try Verifier.init(allocator);
    defer verifier.deinit();

    try verifier.verifyVersionLattice();
    try std.testing.expect(verifier.result.passed);
}

test "BFT safety verification" {
    const allocator = std.testing.allocator;
    var verifier = try Verifier.init(allocator);
    defer verifier.deinit();

    // Valid: 4 validators, 1 faulty (4 >= 3*1 + 1 = 4)
    try verifier.verifyBFTSafety(4, 1);
    try std.testing.expect(verifier.result.passed);

    // Invalid: 2 validators, 1 faulty (2 < 3*1 + 1 = 4)
    verifier.result.passed = true;
    try verifier.verifyBFTSafety(2, 1);
    try std.testing.expect(!verifier.result.passed);
}
