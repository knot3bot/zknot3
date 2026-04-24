const std = @import("std");
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
    _ = @import("test/integration/cluster_integration_test.zig");
    _ = @import("test/integration/consensus_flow_test.zig");
    _ = @import("test/integration/full_pipeline_test.zig");
    _ = @import("test/integration/move_contract_test.zig");
    _ = @import("test/integration/pipeline_test.zig");
    _ = @import("test/integration/rpc_network_test.zig");
    _ = @import("test/integration/m4_contract_parity_test.zig");
    _ = @import("test/integration/m4_wal_recovery_test.zig");
    _ = @import("test/integration/m4_adversarial_recovery_test.zig");
    _ = @import("test/integration/m4_multi_validator_checkpoint_test.zig");
    _ = @import("test/integration/p2p_async_test.zig");
    _ = @import("test/integration/test_cluster.zig");
    _ = @import("test/integration/transaction_execution_test.zig");
    _ = @import("test/integration/indexing_end_to_end_test.zig");
    _ = @import("test/integration/epoch_advance_test.zig");
    _ = @import("test/property/property_test.zig");
    _ = @import("test/property/mysticeti_concurrency_test.zig");
    _ = @import("test/fuzz/fuzz_framework.zig");
    _ = @import("test/fuzz/ObjectIDFuzzTests.zig");
    _ = @import("src/form/network/P2PServer.zig");
}


