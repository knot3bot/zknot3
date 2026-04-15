# Build stage - cross-compile for Linux ARM64
FROM ubuntu:22.04 AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    curl \
    xz-utils \
    librocksdb-dev \
    && rm -rf /var/lib/apt/lists/*

# Download and install Zig 0.15.1 (pre-built for aarch64 Linux)
RUN curl -fsSL https://ziglang.org/download/0.15.1/zig-aarch64-linux-0.15.1.tar.xz | tar xJ --strip-components=1 -C /opt

# Add Zig to PATH

# Add Zig to PATH
ENV PATH="/opt:$PATH"

# Copy source code
WORKDIR /src
COPY . .

# Cross-compile for ARM64 Linux
RUN /opt/zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-gnu

# Final stage - runtime image
FROM ubuntu:22.04

# Install rocksdb runtime libraries
RUN apt-get update && apt-get install -y \
    librocksdb-dev \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy binary from build stage
COPY --from=builder /src/zig-out/bin/zknot3-node-safe /usr/local/bin/zknot3

# Create non-root user
RUN useradd -m -s /bin/bash zknot3

# Create data directory
RUN mkdir -p /var/lib/zknot3 && chown zknot3:zknot3 /var/lib/zknot3

# Copy default config
COPY deploy/config/production.toml /var/lib/zknot3/config.toml
COPY deploy/config/production.toml /etc/zknot3/config.toml

# Set working directory
WORKDIR /var/lib/zknot3

# Switch to non-root user (disabled for debugging)
# USER zknot3

# Expose ports
EXPOSE 9000 8080 8081

# Run
ENTRYPOINT ["/usr/local/bin/zknot3"]
CMD ["--config", "/etc/zknot3/config.toml"]
HEALTHCHECK --interval=10s --timeout=5s --start-period=5s --retries=3 CMD curl -fs http://localhost:8080/health || exit 1
