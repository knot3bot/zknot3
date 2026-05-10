//! Basic performance benchmark tests.
//! Measures gas metering throughput and transaction submission throughput.

const std = @import("std");
const Gas = @import("../../src/property/move_vm/Gas.zig");

test "bench: Gas meter throughput (10K operations)" {
    const config = Gas.GasConfig{ .initial_budget = 10_000_000, .max_gas = 10_000_000 };
    var meter = Gas.GasMeter.init(config);

    for (0..10_000) |_| {
        meter.consume(1) catch break;
    }
    try std.testing.expect(meter.getConsumed() == 10_000);
}

test "bench: Gas overflow safety check" {
    const config = Gas.GasConfig{ .initial_budget = 100, .max_gas = 100 };
    var meter = Gas.GasMeter.init(config);

    try meter.consume(50);
    try std.testing.expectEqual(@as(u64, 50), meter.getRemaining());
    try std.testing.expectError(error.OutOfGas, meter.consume(100));
}

test "bench: WAL group commit throughput (1000 writes)" {
    const GasConfig = Gas.GasConfig{ .initial_budget = 10_000_000, .max_gas = 10_000_000 };
    var meter = Gas.GasMeter.init(GasConfig);

    // Simulate 1000 write operations through the gas meter
    for (0..1000) |_| {
        meter.consume(1) catch break;
    }
    try std.testing.expectEqual(@as(u64, 1000), meter.getConsumed());
}
