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

# Copy Zig tarball from build context (pre-downloaded)
COPY zig-bin/zig-aarch64-linux-0.16.0.tar.xz /tmp/zig.tar.xz
RUN tar xJf /tmp/zig.tar.xz --strip-components=1 -C /opt && rm /tmp/zig.tar.xz

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

# Create data directory
RUN mkdir -p /var/lib/zknot3

# Copy default config
COPY deploy/config/production.toml /var/lib/zknot3/config.toml

# Set working directory
WORKDIR /var/lib/zknot3

# Expose ports
EXPOSE 9000 8080 8081

# Run
ENTRYPOINT ["/usr/local/bin/zknot3"]
CMD ["--config", "/var/lib/zknot3/config.toml"]
