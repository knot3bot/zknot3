const std = @import("std");
comptime {
    _ = @import("test/unit/graphql_test.zig");
    _ = @import("test/unit/serialization_test.zig");
    _ = @import("test/unit/test_framework.zig");
    _ = @import("test/integration/cluster_integration_test.zig");
    _ = @import("test/integration/consensus_flow_test.zig");
    _ = @import("test/integration/full_pipeline_test.zig");
    _ = @import("test/integration/move_contract_test.zig");
    _ = @import("test/integration/pipeline_test.zig");
    _ = @import("test/integration/rpc_network_test.zig");
    _ = @import("test/integration/test_cluster.zig");
    _ = @import("test/integration/transaction_execution_test.zig");
    _ = @import("test/property/property_test.zig");
    _ = @import("test/fuzz/fuzz_framework.zig");
    _ = @import("test/fuzz/ObjectIDFuzzTests.zig");
}


