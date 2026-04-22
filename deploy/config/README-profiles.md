# zknot3 Mainnet Profiles

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
