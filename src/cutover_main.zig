//! Operator commands for a mainnet cutover.
//!
//!   zknot3-cutover snapshot verify <file>
//!   zknot3-cutover snapshot digest <file>
//!   zknot3-cutover proof verify <genesis> <proof>
//!   zknot3-cutover genesis write-sample <file>
//!
//! `snapshot verify` refuses a file whose Blake3 digest does not match.
//! `proof verify` checks the proof against the genesis validator set.

const std = @import("std");
const StateSnapshot = @import("form/storage/StateSnapshot.zig");
const Genesis = @import("app/Genesis.zig");
const CheckpointProofFile = @import("app/CheckpointProofFile.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io_mod = @import("io_instance");
    io_mod.io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const group = args.next() orelse return usage();
    const cmd = args.next() orelse return usage();

    if (std.mem.eql(u8, group, "snapshot") and std.mem.eql(u8, cmd, "verify")) {
        const path = args.next() orelse return usage();
        const bytes = try readFile(allocator, path);
        defer allocator.free(bytes);
        const hdr = StateSnapshot.header(bytes) catch {
            std.debug.print("snapshot rejected\n", .{});
            std.process.exit(1);
        };
        std.debug.print("sequence={d} objects={d}\n", .{ hdr.checkpoint_sequence, hdr.object_count });
        return;
    }
    if (std.mem.eql(u8, group, "snapshot") and std.mem.eql(u8, cmd, "digest")) {
        const path = args.next() orelse return usage();
        const bytes = try readFile(allocator, path);
        defer allocator.free(bytes);
        _ = StateSnapshot.header(bytes) catch {
            std.debug.print("snapshot rejected\n", .{});
            std.process.exit(1);
        };
        const hex = std.fmt.bytesToHex(bytes[StateSnapshot.magic.len..][0..32].*, .lower);
        std.debug.print("{s}\n", .{&hex});
        return;
    }
    if (std.mem.eql(u8, group, "proof") and std.mem.eql(u8, cmd, "verify")) {
        const genesis_path = args.next() orelse return usage();
        const proof_path = args.next() orelse return usage();
        const genesis = try readFile(allocator, genesis_path);
        defer allocator.free(genesis);
        const proof = try readFile(allocator, proof_path);
        defer allocator.free(proof);
        const ok = CheckpointProofFile.verify(allocator, genesis, proof) catch {
            std.debug.print("proof rejected\n", .{});
            std.process.exit(1);
        };
        if (!ok) {
            std.debug.print("proof rejected\n", .{});
            std.process.exit(1);
        }
        std.debug.print("proof ok\n", .{});
        return;
    }
    if (std.mem.eql(u8, group, "genesis") and std.mem.eql(u8, cmd, "write-sample")) {
        const path = args.next() orelse return usage();
        var vals = Genesis.sampleMainnetValidators();
        const bytes = try Genesis.encode(allocator, Genesis.sampleMainnet(&vals));
        defer allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(io_mod.io, .{ .sub_path = path, .data = bytes });
        const hex = std.fmt.bytesToHex(bytes[Genesis.magic.len..][0..32].*, .lower);
        std.debug.print("{s}\n", .{&hex});
        return;
    }
    return usage();
}

fn usage() noreturn {
    std.debug.print(
        \\zknot3-cutover snapshot verify <file>
        \\zknot3-cutover snapshot digest <file>
        \\zknot3-cutover proof verify <genesis> <proof>
        \\zknot3-cutover genesis write-sample <file>
        \\
    , .{});
    std.process.exit(1);
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(@import("io_instance").io, path, allocator, std.Io.Limit.limited(64 * 1024 * 1024));
}
