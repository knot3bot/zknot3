# zknot3 Mainnet Profiles

> **格式注意**：节点当前**仅加载 JSON 配置**（`-c <file>.json`）。
> 本目录的 TOML 文件是调度参数的设计参考基准，尚无 TOML 加载器；
> 使用前需将参数转换为 JSON 配置。


This directory includes three production-oriented scheduling profiles:

- `production-conservative.toml`
- `production-balanced.toml`
- `production-throughput.toml`

## Recommended Usage

- **Conservative**
  - Use for hostile network periods or when prioritizing consensus liveness over throughput.
  - Tighter per-peer and per-tick processing limits.

- **Balanced**
  - Default mainnet recommendation.
  - Good trade-off between consensus progress and transaction ingress.

- **Throughput**
  - Use when mempool pressure is consistently high and validator hardware/network headroom is sufficient.
  - Higher total processing budget and transaction allocation.

## Quick Switch

Replace active config file with one of the profiles before node startup:

```bash
cp deploy/config/production-balanced.toml deploy/config/production.toml
```

You can also tune only the `[consensus]` message scheduling fields and keep the rest unchanged.

## Scripted Switch (recommended)

Use the helper script to switch profiles and auto-backup the current `production.toml`:

```bash
./deploy/scripts/switch-profile.sh balanced
```

Other examples:

```bash
./deploy/scripts/switch-profile.sh --list
./deploy/scripts/switch-profile.sh conservative
./deploy/scripts/switch-profile.sh throughput --no-backup
```
