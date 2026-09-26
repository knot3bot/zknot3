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

# Fetch the pinned official 0.17.0-dev nightly for the build host arch
# (0.17.0 stable does not exist; the codebase tracks the dev line).
ARG ZIG_VERSION=0.17.0-dev.2307+392b17125
RUN case "$(uname -m)" in \
      x86_64) ZARCH=x86_64 ;; \
      aarch64|arm64) ZARCH=aarch64 ;; \
      *) echo "unsupported build arch" >&2; exit 1 ;; \
    esac && \
    curl -sL "https://ziglang.org/builds/zig-${ZARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz && \
    mkdir -p /opt && tar xJf /tmp/zig.tar.xz --strip-components=1 -C /opt && rm /tmp/zig.tar.xz

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
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Copy binary from build stage
COPY --from=builder /src/zig-out/bin/zknot3-node-safe /usr/local/bin/zknot3

# Entry point wrapper to render config templates with env vars
COPY deploy/docker/zknot3-entrypoint.sh /usr/local/bin/zknot3-entrypoint
RUN chmod +x /usr/local/bin/zknot3-entrypoint

# Create data directory
RUN mkdir -p /var/lib/zknot3

# Copy default config
COPY deploy/config/production.toml /var/lib/zknot3/config.toml

# Set working directory
WORKDIR /var/lib/zknot3

# Expose ports
EXPOSE 9003 8083 9133

# Health check via HTTP API
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 \
    CMD curl -sf http://localhost:9003/health || exit 1

# Run
ENTRYPOINT ["/usr/local/bin/zknot3-entrypoint"]
CMD ["--config", "/var/lib/zknot3/config.toml"]
