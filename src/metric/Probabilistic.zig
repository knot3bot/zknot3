//! Probabilistic - Probability models for performance analysis
//!
//! Implements probability distributions for:
//! - Latency modeling
//! - Throughput estimation
//! - Confidence intervals

const std = @import("std");

/// Probability distribution type
pub const DistributionType = enum {
    exponential,
    normal,
    uniform,
};

/// Probability model
pub const ProbabilityModel = struct {
    const Self = @This();

    distribution: DistributionType,
    /// Lambda for exponential, mean for normal, [min,max] for uniform
    param1: f64,
    /// Standard deviation for normal
    param2: f64,

    /// Initialize exponential distribution
    pub fn exponential(lambda: f64) Self {
        return .{
            .distribution = .exponential,
            .param1 = lambda,
            .param2 = 0,
        };
    }

    /// Initialize normal distribution
    pub fn normal(mean_val: f64, stddev: f64) Self {
        return .{
            .distribution = .normal,
            .param1 = mean_val,
            .param2 = stddev,
        };
    }

    /// Initialize uniform distribution
    pub fn uniform(min: f64, max: f64) Self {
        return .{
            .distribution = .uniform,
            .param1 = min,
            .param2 = max,
        };
    }

    /// Get CDF value (probability that X <= x)
    pub fn cdf(self: Self, x: f64) f64 {
        return switch (self.distribution) {
            .exponential => 1.0 - std.math.exp(-self.param1 * x),
            .normal => self.normalCDF(x),
            .uniform => self.uniformCDF(x),
        };
    }

    /// Get PDF value (probability density at x)
    pub fn pdf(self: Self, x: f64) f64 {
        return switch (self.distribution) {
            .exponential => self.param1 * std.math.exp(-self.param1 * x),
            .normal => self.normalPDF(x),
            .uniform => if (x >= self.param1 and x <= self.param2) 1.0 / (self.param2 - self.param1) else 0.0,
        };
    }

    fn normalCDF(self: Self, x: f64) f64 {
        // Approximation using error function
        const z = (x - self.param1) / (self.param2 * std.math.sqrt(2.0));
        return 0.5 * (1.0 + std.math.erf(z));
    }

    fn normalPDF(self: Self, x: f64) f64 {
        const z = (x - self.param1) / self.param2;
        return (1.0 / (self.param2 * std.math.sqrt(2.0 * std.math.pi))) *
            std.math.exp(-0.5 * z * z);
    }

    fn uniformCDF(self: Self, x: f64) f64 {
        if (x < self.param1) return 0.0;
        if (x > self.param2) return 1.0;
        return (x - self.param1) / (self.param2 - self.param1);
    }

    /// Get mean
    pub fn mean(self: Self) f64 {
        return switch (self.distribution) {
            .exponential => 1.0 / self.param1,
            .normal => self.param1,
            .uniform => (self.param1 + self.param2) / 2.0,
        };
    }

    /// Get variance
    pub fn variance(self: Self) f64 {
        return switch (self.distribution) {
            .exponential => 1.0 / (self.param1 * self.param1),
            .normal => self.param2 * self.param2,
            .uniform => std.math.pow(f64, self.param2 - self.param1, 2.0) / 12.0,
        };
    }

    /// Get percentile (inverse CDF)
    pub fn percentile(self: Self, p: f64) f64 {
        // Approximate inverse
        if (p < 0 or p > 1) return 0;

        return switch (self.distribution) {
            .exponential => -std.math.log(1.0 - p) / self.param1,
            .normal => self.param1 + self.param2 * std.math.sqrt(2.0) * inverseErrorFunction(2.0 * p - 1.0),
            .uniform => self.param1 + p * (self.param2 - self.param1),
        };
    }
};

/// Approximate inverse error function
fn inverseErrorFunction(x: f64) f64 {
    // Simple approximation
    const a = 0.147;
    const b = std.math.ln(1.0 - x * x);
    const c = 2.0 / (std.math.pi * a) + b / 2.0;
    return x * std.math.sqrt(std.math.sqrt(c * c - b / a) - c);
}

/// Performance metrics with confidence intervals
pub const PerformanceMetrics = struct {
    latency: ProbabilityModel,
    throughput: f64, // transactions per second
    sample_count: usize,

    const Self = @This();

    /// Get P50 latency
    pub fn p50(self: Self) f64 {
        return self.latency.percentile(0.50);
    }

    /// Get P95 latency
    pub fn p95(self: Self) f64 {
        return self.latency.percentile(0.95);
    }

    /// Get P99 latency
    pub fn p99(self: Self) f64 {
        return self.latency.percentile(0.99);
    }

    /// Get confidence that latency < target
    pub fn latencyConfidence(self: Self, target_ms: f64) f64 {
        return self.latency.cdf(target_ms);
    }
};

test "Exponential distribution" {
    const dist = ProbabilityModel.exponential(2.0); // lambda = 2

    try std.testing.expect(dist.mean() == 0.5);

    // CDF at mean should be ~0.63
    const cdf_at_mean = dist.cdf(dist.mean());
    try std.testing.expect(cdf_at_mean > 0.63);
    try std.testing.expect(cdf_at_mean < 0.64);
}

test "Normal distribution" {
    const dist = ProbabilityModel.normal(100.0, 10.0);

    try std.testing.expect(dist.mean() == 100.0);
    try std.testing.expect(dist.variance() == 100.0);

    // P50 should be close to mean
    const p50 = dist.percentile(0.50);
    try std.testing.expect(p50 > 99.0);
    try std.testing.expect(p50 < 101.0);
}

test "Performance metrics" {
    const metrics = PerformanceMetrics{
        .latency = ProbabilityModel.exponential(1.0 / 100.0), // mean 100ms
        .throughput = 10000.0,
        .sample_count = 1000,
    };

    try std.testing.expect(metrics.p50() > 60.0);
    try std.testing.expect(metrics.p99() > 400.0);
}
