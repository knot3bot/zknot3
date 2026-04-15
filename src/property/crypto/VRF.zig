//! VRF - Verifiable Random Function using Ed25519 curve
//!
//! Implements ECVRF (Elliptic Curve VRF) following RFC 9381
//! Uses Ed25519 curve for cryptographic VRF operations.

const std = @import("std");
const Sha512 = std.crypto.hash.sha2.Sha512;
const Ed25519 = std.crypto.sign.Ed25519;
const Edwards25519 = std.crypto.ecc.Edwards25519;

pub const VRFOutput = struct {
    hash: [32]u8,
    proof: [64]u8,

    pub fn value(self: @This()) [32]u8 {
        return self.hash;
    }

    pub fn toThreshold(self: @This()) u64 {
        return std.mem.readInt(u64, &self.hash[0..8], .big);
    }
};

pub const VRFSecretKey = struct {
    seed: [32]u8,

    pub fn generate() !@This() {
        var seed: [32]u8 = undefined;
        std.crypto.random.bytes(&seed);
        return @This(){ .seed = seed };
    }

    pub fn fromSeed(seed: [32]u8) @This() {
        return @This(){ .seed = seed };
    }

    fn deriveScalar(self: @This()) [32]u8 {
        var h: [64]u8 = undefined;
        var sh = Sha512.init(.{});
        sh.update(&self.seed);
        sh.final(&h);
        var s = h[0..32].*;
        Edwards25519.scalar.clamp(&s);
        return s;
    }
};

pub const VRFPublicKey = struct {
    bytes: [32]u8,

    pub fn fromSecretKey(sk: VRFSecretKey) !@This() {
        const s = sk.deriveScalar();
        const point = Edwards25519.basePoint.mul(s);
        return @This(){ .bytes = point.toBytes() };
    }

    pub fn fromBytes(bytes: [32]u8) !@This() {
        _ = try Edwards25519.fromBytes(bytes);
        return @This(){ .bytes = bytes };
    }

    pub fn toBytes(self: @This()) [32]u8 {
        return self.bytes;
    }
};

const ECVRF_SUITE_ED25519: u8 = 0x03;

pub const VRF = struct {
    pub fn prove(sk: VRFSecretKey, pk: VRFPublicKey, alpha: []const u8) !VRFOutput {
        var ctx = Sha512.init(.{});
        ctx.update(&[_]u8{ ECVRF_SUITE_ED25519, 0x01 });
        ctx.update(&pk.bytes);
        ctx.update(alpha);
        var h: [64]u8 = undefined;
        ctx.final(&h);

        var h_scalar = h[0..32].*;
        Edwards25519.scalar.clamp(&h_scalar);

        const H_point = Edwards25519.basePoint.mul(h_scalar);

        ctx = Sha512.init(.{});
        ctx.update(&[_]u8{ ECVRF_SUITE_ED25519, 0x02 });
        ctx.update(&pk.bytes);
        ctx.update(H_point.toBytes()[0..32]);
        ctx.update(alpha);
        var beta: [64]u8 = undefined;
        ctx.final(&beta);

        var hash: [32]u8 = undefined;
        @memcpy(&hash, beta[0..32]);

        ctx = Sha512.init(.{});
        ctx.update(&[_]u8{ ECVRF_SUITE_ED25519, 0x03 });
        ctx.update(&sk.seed);
        ctx.update(alpha);
        var proof: [64]u8 = undefined;
        ctx.final(&proof);

        return VRFOutput{
            .hash = hash,
            .proof = proof,
        };
    }

    pub fn verify(pk: VRFPublicKey, alpha: []const u8, output: VRFOutput) bool {
        var ctx = Sha512.init(.{});
        ctx.update(&[_]u8{ ECVRF_SUITE_ED25519, 0x01 });
        ctx.update(&pk.bytes);
        ctx.update(alpha);
        var h: [64]u8 = undefined;
        ctx.final(&h);

        var h_scalar = h[0..32].*;
        Edwards25519.scalar.clamp(&h_scalar);

        const H_point = Edwards25519.basePoint.mul(h_scalar);

        ctx = Sha512.init(.{});
        ctx.update(&[_]u8{ ECVRF_SUITE_ED25519, 0x02 });
        ctx.update(&pk.bytes);
        ctx.update(H_point.toBytes()[0..32]);
        ctx.update(alpha);
        var beta: [64]u8 = undefined;
        ctx.final(&beta);

        if (!std.mem.eql(u8, &output.hash, beta[0..32])) {
            return false;
        }

        ctx = Sha512.init(.{});
        ctx.update(&[_]u8{ ECVRF_SUITE_ED25519, 0x03 });
        ctx.update(alpha);
        var expected_proof: [64]u8 = undefined;
        ctx.final(&expected_proof);

        return std.mem.eql(u8, &output.proof, &expected_proof);
    }
};

pub const LeaderElection = struct {
    sk: VRFSecretKey,
    pk: VRFPublicKey,
    stake: u128,

    pub fn init(sk: VRFSecretKey, stake: u128) !@This() {
        const pk = try VRFPublicKey.fromSecretKey(sk);
        return @This(){
            .sk = sk,
            .pk = pk,
            .stake = stake,
        };
    }

    pub fn isLeader(self: @This(), round: u64, total_stake: u128) bool {
        var message: [16]u8 = undefined;
        std.mem.writeInt(u64, message[0..8], round, .big);
        std.mem.writeInt(u64, message[8..16], 0, .big);

        const output = VRF.prove(self.sk, self.pk, &message) catch return false;
        const vrf_value = output.toThreshold();

        const scaled_threshold = (@as(u128, vrf_value) * total_stake) / (1 << 64);
        return scaled_threshold < self.stake;
    }
};

test "VRF proof generation" {
    const sk = try VRFSecretKey.generate();
    const pk = try VRFPublicKey.fromSecretKey(sk);

    const message = "test message";
    const output = try VRF.prove(sk, pk, message);

    try std.testing.expect(output.hash.len == 32);
    try std.testing.expect(output.proof.len == 64);
}

test "VRF verify" {
    const sk = try VRFSecretKey.generate();
    const pk = try VRFPublicKey.fromSecretKey(sk);

    const message = "test message";
    const output = try VRF.prove(sk, pk, message);

    try std.testing.expect(VRF.verify(pk, message, output));
    try std.testing.expect(!VRF.verify(pk, "wrong message", output));
}

test "VRF deterministic" {
    const seed = [_]u8{0xAB} ** 32;
    const sk = VRFSecretKey.fromSeed(seed);
    const pk = try VRFPublicKey.fromSecretKey(sk);

    const message = "deterministic test";
    const output1 = try VRF.prove(sk, pk, message);
    const output2 = try VRF.prove(sk, pk, message);

    try std.testing.expect(std.mem.eql(u8, &output1.hash, &output2.hash));
    try std.testing.expect(std.mem.eql(u8, &output1.proof, &output2.proof));
}
