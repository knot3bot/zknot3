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
    // Peer-liveness error classification: the devnet silently held zero peers
    // until this file's tests were compiled in.
    _ = @import("src/form/consensus/ConsensusIntegration.zig");
    // Stake-weighted commit quorum: the ballot-count check it replaced was not
    // covered by any test.
    _ = @import("src/app/BlockCommit.zig");
    _ = @import("src/property/move_vm/ModuleRegistry.zig");
}
