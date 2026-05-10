// Unit test suite — fast, no filesystem/network dependencies.
comptime {
    _ = @import("test/unit/graphql_test.zig");
    _ = @import("test/unit/bls_checkpoint_test.zig");
    _ = @import("test/unit/m4_rpc_params_test.zig");
    _ = @import("test/unit/serialization_test.zig");
    _ = @import("test/unit/transaction_golden_vectors.zig");
    _ = @import("test/unit/sdk_protocol_test.zig");
    _ = @import("test/unit/move_vm_native_test.zig");
    _ = @import("test/unit/governance_vote_test.zig");
    _ = @import("test/unit/test_framework.zig");
    _ = @import("test/unit/performance_bench_test.zig");
    _ = @import("test/fuzz/fuzz_framework.zig");
    _ = @import("test/fuzz/ObjectIDFuzzTests.zig");
    _ = @import("src/form/network/P2PServer.zig");
}
