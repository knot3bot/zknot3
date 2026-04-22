//! NodeInfoCoordinator - validator/system info query helpers for Node

const std = @import("std");
const builtin = @import("builtin");
const EpochConsensusBridge = @import("../metric/EpochConsensusBridge.zig").EpochConsensusBridge;

extern "c" fn sysctl(name: [*]const c_int, namelen: c_uint, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int;

pub const ValidatorInfo = struct {
    id: [32]u8,
    stake: u128,
    voting_power: u128,
    is_active: bool,
};

pub const SystemInfo = struct {
    cpu_count: usize,
    total_memory_bytes: u64,
    cpu_usage_percent: f64,
};

pub fn getValidatorList(allocator: std.mem.Allocator, epoch_bridge: ?*EpochConsensusBridge) ![]ValidatorInfo {
    if (epoch_bridge) |bridge| {
        const quorum = bridge.quorum;
        var list = try std.ArrayList(ValidatorInfo).initCapacity(allocator, quorum.members.items.len);
        errdefer list.deinit(allocator);
        for (quorum.members.items) |member| {
            const power = bridge.getValidatorVotingPower(member.id);
            try list.append(allocator, .{
                .id = member.id,
                .stake = member.stake,
                .voting_power = power,
                .is_active = member.is_active,
            });
        }
        return try list.toOwnedSlice(allocator);
    }
    return &[_]ValidatorInfo{};
}

pub fn getSystemInfo() SystemInfo {
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return .{
        .cpu_count = cpu_count,
        .total_memory_bytes = getTotalSystemMemory(),
        .cpu_usage_percent = 0.0,
    };
}

fn getTotalSystemMemory() u64 {
    if (builtin.target.os.tag == .linux) {
        var buf: [1024]u8 = undefined;
        const file = std.Io.Dir.cwd().openFile(@import("io_instance").io, "/proc/meminfo", .{}) catch return 0;
        defer file.close(@import("io_instance").io);
        var reader = file.reader(
            @import("io_instance").io,
            &.{},
        );
        const n = reader.interface.readSliceShort(&buf) catch return 0;
        const content = buf[0..n];
        const prefix = "MemTotal:";
        if (std.mem.indexOf(u8, content, prefix)) |idx| {
            const line_start = idx + prefix.len;
            const line_end = std.mem.indexOf(u8, content[line_start..], " kB") orelse return 0;
            const num_str = std.mem.trim(u8, content[line_start .. line_start + line_end], " ");
            const kb = std.fmt.parseInt(u64, num_str, 10) catch return 0;
            return kb * 1024;
        }
        return 0;
    } else if (builtin.target.os.tag == .macos) {
        const CTL_HW: c_int = 6;
        const HW_MEMSIZE: c_int = 24;
        const mib = &[_]c_int{ CTL_HW, HW_MEMSIZE };
        var memsize: u64 = 0;
        var len: usize = @sizeOf(u64);

        if (sysctl(mib.ptr, mib.len, &memsize, &len, null, 0) == 0) {
            return memsize;
        }
        return 0;
    }
    return 0;
}

test "NodeInfoCoordinator getValidatorList returns empty without bridge" {
    const allocator = std.testing.allocator;
    const list = try getValidatorList(allocator, null);
    try std.testing.expectEqual(@as(usize, 0), list.len);
}

test "NodeInfoCoordinator getSystemInfo returns sane defaults" {
    const info = getSystemInfo();
    try std.testing.expect(info.cpu_count >= 1);
    try std.testing.expect(info.cpu_usage_percent == 0.0);
}

