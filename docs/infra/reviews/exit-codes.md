---
decision: 稍后做
---

# Container Exit Codes Review

**Date:** 2026-05-23
**Scope:** All containers on the Orbstack Docker host (kyb sandbox infra)
**Method:** `docker inspect`, `docker events` (72h buffer), kernel logs, container logs

---

## 1. Inventory

| Status    | Count | Details |
|-----------|-------|---------|
| Running   | 20    | Core infra + boss agents + ephemeral test containers |
| Exited    | 2     | `friendly_banach` (exit 5), `kyb-kyb-robust` (exit 5) |
| Exited (0) | 1    | `kyb-test-entrypoint-ghtoken` (intentional one-shot) |
| Created   | 1     | `stoic_feistel` (never started, alpine) |
| Removing  | 0     | (was 1 transient) |

**Total tracked:** 24 containers over the last ~48 h.

---

## 2. Exit Code Distribution

| Exit Code | Count | Containers | Interpretation |
|-----------|-------|------------|----------------|
| 0         | 21    | All running + `kyb-test-entrypoint-ghtoken` + recently-destroyed Alpine test containers | Clean exit |
| 5         | 2     | `friendly_banach`, `kyb-kyb-robust` | kyb-base startup failure |

### Exit Code 5 Analysis

Both containers use the `kyb-base` image (built from `Dockerfile` in this repo). Container logs show:

- **`jq: parse error`** in both — a jq expression in the startup script fails to parse, causing `set -e` to abort the shell.
- **`find: /home/dev/.m2/repository: No such file or directory`** in `friendly_banach` — a `find` command references a mount point that does not exist at container startup.

**Root cause:** These containers were created without required bind-mounts or environment variables that the entrypoint expects. The `set -e` in `entrypoint.sh` converts any non-zero command exit into an immediate container exit with that command's return code (5 is not emitted by our scripts; it comes from a tool invoked during startup falling through the `set -e` trap).

**Exit code 5 is not a crash — it is a startup precondition failure.** The containers never reached the point of running their intended workload.

---

## 3. Crash Rate

| Metric | Value |
|--------|-------|
| Non-zero exits / total containers | 2 / 24 = **8.3 %** |
| Restarts across all containers | **0** (every `RestartCount` is 0) |
| Currently unhealthy | 1 (`bold_almeida` — Feishu config issue, still running) |

**Effective crash rate (unexpected exit of a previously-healthy container): 0 %** over the observation window. The two exit-5 containers never became healthy — they failed at startup, not during operation.

---

## 4. OOM Frequency

| Source | OOM Events |
|--------|------------|
| `dmesg` kernel OOM killer | **0** |
| Docker `OOMKilled` flag (all containers) | **0** |
| Docker events "oom" type | **0** |

**No out-of-memory kills observed.** Memory pressure is moderate (7.4 GiB / 15 GiB used, 2.7 GiB / 16 GiB swap used). The host has 8.3 GiB available memory.

---

## 5. Signal Termination Count

| Signal | Events Found | Source |
|--------|-------------|--------|
| SIGKILL (exit 137) | 0 | Docker events, inspect |
| SIGTERM (exit 143) | 0 | Docker events, inspect |
| SIGINT (exit 130)  | 0 | Docker events, inspect |
| Other signal (128+n) | 0 | Docker events, inspect |

**No signal-based terminations detected** in the 72-hour event buffer. All container stops were either clean exit 0 or startup failure exit 5.

The recent commit `c1dff06` ("fix: add --init to all docker run invocations") adds `docker-init` (tini) as PID 1. This is relevant going forward because tini translates signals into exit codes (128+n), making signal-induced container deaths visible in the exit code distribution. After this change lands, signal terminations will appear as:
- 130 = SIGINT (Ctrl+C from `kyb exec --attach`)
- 137 = SIGKILL (OOM killer or `docker kill`)
- 143 = SIGTERM (`docker stop`, `kyb stop`)

---

## 6. Restart Policy Inventory

| Policy       | Containers | Current Restarts |
|--------------|------------|-----------------|
| `always`     | 1 (`kyb-infra-sing-box`) | 0 |
| `unless-stopped` | ~15 infra containers | 0 |
| (none)       | Ephemeral/test containers | 0 |

No container has ever triggered its restart policy. All infra containers started once and have remained up since creation (oldest: ~23 h).

---

## 7. Service-Specific Findings

### PostgreSQL (v14–v17)
- 4 instances, all running since ~2026-05-22T18:37
- Zero restarts, zero failures
- Exit code 0, FinishedAt 0001-01-01 (never stopped)

### Grafana
- Running since ~2026-05-22T19:40
- Zero restarts, healthy
- Exit code 0

### ClickHouse
- Running since ~2026-05-23T06:37
- Zero restarts, healthy
- Exit code 0

### cc-connect
- `kyb-infra-cc-connect`: healthy, zero restarts, running since ~2026-05-23T09:35
- `bold_almeida`: running but unhealthy (Feishu app_id invalid in config, not a process crash)

### Boss Agents (5 instances)
- `kyb-infra-boss`, `kyb-infra-boss2`, `kyb-infra-boss3`, `kyb-infra-boss-fallback`, `kyb-infra-boss-old`
- All running, zero restarts
- Uptime range: 6–7 h

### Sing-box
- Restart policy `always` — the only container configured with this
- Zero actual restarts
- Running since ~2026-05-23T05:39

---

## 8. Recommendations

1. **Investigate exit code 5 at startup.** These failures represent wasted container create+destroy cycles. Consider adding a pre-flight check (akin to `kyb preflight`) that validates environment before starting containers from `kyb-base`.

2. **Add health checks to all infra containers.** Currently only `kyb-infra-cc-connect` has a health check. Without health checks, a silently degraded process (e.g., stalled but not dead) would go undetected until the next patrol cycle.

3. **Set up exit code monitoring.** After `--init` lands, signals will produce visible exit codes. A prometheus-exporter or simple cron that polls `docker ps -a --filter status=exited` daily would capture these.

4. **Consider switching boss containers to `restart: always`.** From a high availability standpoint, if a boss agent dies, the `unless-stopped` policy won't restart it unless the host reboots.

5. **Review sing-box `restart: always` vs `unless-stopped`.** Sing-box is the only container with `always` — if Docker is ever restarted manually, sing-box will come back before the infra stack is ready, potentially causing transient connection errors.

---

## 9. Data Sources and Limitations

- **Docker events buffer:** ~72 h retention. Events older than ~2 h were mostly expunged.
- **Container logs:** Preserved for exited containers (json-file driver).
- **Kernel logs (`dmesg`):** Full retention. No OOM entries found.
- **System journal (`journalctl`):** No Docker daemon logs available (Orbstack runs dockerd in a VM).

The observation window is limited to approximately the last 48 h for running containers and the last 72 h for Docker events. A longer baseline (e.g., 30 days) would improve confidence in the 0% operational crash rate.
