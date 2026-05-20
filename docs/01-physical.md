# Physical Layer — boss-12 (192.168.215.12)

## Machine Identity

| Field | Value |
|-------|-------|
| Name | boss-12 (kyb boss container) |
| IP | 192.168.215.12 |
| Hostname | 591d31275ebc (container ID) |
| Type | kyb boss container (non-interactive, agent-driven) |
| Managed by | kyb on host (192.168.215.5) |

## Host Hardware (OrbStack on Apple Silicon)

| Component | Detail |
|-----------|--------|
| Architecture | aarch64 (ARM64) |
| Vendor | Apple |
| CPU | 10 cores (Apple Silicon) |
| CPU max MHz | 2000 MHz |
| RAM | 15 GiB |
| Swap | 16 GiB (zram0 + vdc) |

### Attached Storage

| Device | Size | Type |
|--------|------|------|
| vdb | 8 TiB | Raw block device |
| vdb1 | 926 GiB | Partition (used as container overlay) |
| vda | 364 MiB | Read-only (container metadata) |
| overlay | 78 GiB | Docker overlay (51G used / 28G avail, 65%) |

## Container Environment

- Runs inside Docker on OrbStack
- Overlay filesystem (ephemeral)
- No systemd (PID 1 is not init system)
- Timezone: UTC
- Uptime: 7+ days

## Notes

- This is a **boss container** — it manages other kyb sandboxes, not used for interactive development
- No `/kyb` mount (different from regular sandbox containers)
- No Docker daemon socket available
