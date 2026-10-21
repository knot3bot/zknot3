// Unit test suite — fast, no filesystem/network dependencies.
comptime {
    _ = @import("test/unit/graphql_test.zig");
    _ = @import("test/unit/bls_checkpoint_test.zig");
    _ = @import("test/unit/m4_rpc_params_test.zig");
    _ = @import("test/unit/serialization_test.zig");
    _ = @import("test/unit/transaction_golden_vectors.zig");
    _ = @import("test/unit/sdk_protocol_test.zig");
    _ = @import("test/unit/move_vm_native_test.zig");
    _ = @import("src/property/move_vm/stdlib.zig");
    _ = @import("src/property/move_vm/marketplace.zig");
    _ = @import("src/property/crypto/Merkle.zig");
    _ = @import("src/property/move_vm/agent_registry.zig");
    _ = @import("src/property/move_vm/agent_messaging.zig");
    _ = @import("test/unit/governance_vote_test.zig");
    _ = @import("test/unit/test_framework.zig");
    _ = @import("test/unit/performance_bench_test.zig");
    _ = @import("test/fuzz/fuzz_framework.zig");
    _ = @import("test/fuzz/ObjectIDFuzzTests.zig");
    _ = @import("test/fuzz/interpreter_fuzz.zig");
    _ = @import("src/form/network/P2PServer.zig");
    _ = @import("src/form/network/Kademlia.zig");
    _ = @import("src/form/network/AsyncHTTPServer.zig");
    _ = @import("src/app/CheckpointProofFile.zig");
    _ = @import("src/form/storage/Checkpoint.zig");
    // Peer-liveness error classification: the devnet silently held zero peers
    // until this file's tests were compiled in.
    _ = @import("src/form/consensus/ConsensusIntegration.zig");
    // Stake-weighted commit quorum: the ballot-count check it replaced was not
    // covered by any test.
    _ = @import("src/app/BlockCommit.zig");
    _ = @import("src/property/move_vm/ModuleRegistry.zig");
    _ = @import("src/property/move_vm/values.zig");
    _ = @import("src/property/move_vm/License.zig");
    _ = @import("src/app/MCP.zig");
    _ = @import("src/pipeline/Egress.zig");
    // VMConfig gas-payment defaults + JSON round-trip.
    _ = @import("src/app/Config.zig");
    // Gas ledger credit/overflow + RPC write-method auth flag for knot3_creditGas.
    _ = @import("src/pipeline/Executor.zig");
    _ = @import("src/form/network/HTTPServer.zig");
}
