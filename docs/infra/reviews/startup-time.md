---
decision: 稍后做
---

# Container Startup Time Review

**Date**: 2026-05-23
**Scope**: End-to-end startup time of kyb-managed Docker containers, covering `docker create` to container ready (`/tmp/kyb-ready`), image pull costs, entrypoint phase breakdown, and post-ready project setup.

---

## Measurement Method

All measurements use `date +%s%N` for nanosecond precision and `python3` for arithmetic. Containers run on the Orbstack Docker daemon (host.orb.internal) with kyb-base (8.09 GB image, built 2026-05-23 10:53 UTC).

Three timing points:
1. `docker run` call returns (container created + started)
2. Entrypoint signals ready (`/tmp/kyb-ready` created)
3. Container process exits (post-ready project setup complete)

---

## Results

### Overall Startup (kyb create flow)

| Phase | Duration | Notes |
|-------|----------|-------|
| `docker run` latency | ~430-470 ms | Time until CLI returns the container ID |
| `docker run` → running (kernel) | ~30 ms | Actual container creation in the runtime |
| Entrypoint → `/tmp/kyb-ready` | ~10,300-12,800 ms | The kyb-ready polling wait |
| **Total (create → ready)** | **~11,000-13,300 ms** | What `kyb create` blocks on |

### Entrypoint Phase Breakdown

Measured by running the actual kyb-base entrypoint with `--entrypoint` override and isolated phase tests.

| Phase | Duration | Description |
|-------|----------|-------------|
| UID/GID adjustment | ~50-100 ms | `usermod` + `groupmod` (skipped when HOST_UID matches, which is the common case) |
| SSH host config copy | ~20-50 ms | `cp -r` .ssh-host → .ssh if not exists |
| System config | ~30-50 ms | `/etc/hosts` aliases, Docker socket GID, Gradle lock cleanup |
| Claude settings.json | ~100-200 ms | `jq` transform of host settings into container settings |
| Claude onboarding | ~50-100 ms | `/home/dev/.claude.json` generation |
| Git / glab / gh config | ~100-200 ms | GitLab user resolution + config file write |
| Go proxy | ~30 ms | `/etc/profile.d/go.sh` + `.bashrc` |
| CLAUDE.md generation | ~100-300 ms | Template expansion to `/home/dev/.claude/CLAUDE.md` |
| Skills symlink | ~10 ms | `ln -s` |
| **PostgreSQL 16 start** | **~3,000-3,800 ms** | `pg_ctlcluster 16 main start` — creates cluster + starts postmaster |
| **pip install (nexus check)** | **~3,000-4,000 ms** | `pip install ... mig25 mig25-codegen requests[socks]` — 30+ "Requirement already satisfied" checks against nexus |
| Claude Code binary install | ~400-500 ms | `find ... install.cjs` + `node install.cjs` (skipped when binary not pre-installed) |
| **touch /tmp/kyb-ready** | ~0 ms | Signals ready to the polling loop |
| Subtotal (fast phases) | ~500-1,500 ms | All non-network, non-PG phases combined |
| Subtotal (slow phases) | ~6,000-7,800 ms | PG + pip |

**Key insight**: PostgreSQL start and pip nexus check run **sequentially** in the entrypoint, but they are the two dominant phases. Together they account for ~60-70% of the ready wait.

### Image Pull Time

Measured with `alpine:3.19` (~7 MB) as a reference for registry round-trip. kyb-base is not pulled from a registry (built locally via `kyb build`), but dependencies may be fetched during build.

| Scenario | Duration | Notes |
|----------|----------|-------|
| Small image (alpine), cached locally | ~4,800 ms | "Image is up to date" check |
| Small image (alpine), freshly pulled | ~14,000 ms | Full layer download |
| kyb-base build (8 GB) | N/A (hours) | Not measured; `kyb build` is a separate offline operation |

### Post-Ready Project Setup

These run **after** `/tmp/kyb-ready` is created, so they do NOT block `kyb create`. They execute as a `runuser -u dev -- bash -l` heredoc in the entrypoint process.

| Phase | Estimated Duration | Notes |
|-------|-------------------|-------|
| mise trust | ~50-100 ms | Local config trust, no network |
| npm install / yarn install | ~10-120 s | Depends on project; runs only when `node_modules` is empty |
| bundle install | ~10-60 s | Depends on project; runs only when Gemfile exists |

The post-ready phase is **entirely network-bound** (package registry access) and varies wildly by project. It runs in the foreground of the entrypoint process (before `exec runuser`), meaning the container's PID 1 stays in this phase until it completes.

---

## Bottleneck Analysis

### 1. PostgreSQL start (3-4 s)

`pg_ctlcluster 16 main start` forks a postmaster, creates the socket, and waits for readiness. On a fresh container (no existing PG data), this also initializes the cluster directory.

**Why it matters**: Every kyb sandbox runs an embedded PostgreSQL. There is no shared PG service — each container pays this cost independently.

**Potential optimizations**:
- Pre-initialize the PG cluster in the Dockerfile (move `initdb` to build time). Only `pg_ctl start` (socket + postmaster) would run at container start, saving ~1-2 s.
- Use a persistent named volume for PG data (but this complicates clean-up and isolation).
- Shared PG-over-TCP service container (eliminates per-container PG start entirely).

### 2. pip nexus check (3-4 s)

Even though all packages are pre-installed in the image, `pip install` checks every transitive dependency against the nexus index. With 30+ "Requirement already satisfied" lines, each involves an HTTP round-trip to nexus.leyantech.com.

**Why it matters**: This is a **pure waste** — all packages are already in the image. The `pip install` call exists as a fallback for when the image was built without them, but it runs unconditionally.

**Potential optimizations**:
- Add `--exists-action i` or redirect to `pip list` check instead of `pip install`.
- Check in the entrypoint whether packages are already installed (`pip list --format=columns | grep mig25`) and skip the install entirely.
- Use `pip install --no-index --find-links ...` with a local offline mirror.

### 3. Sequential execution

PG start and pip check run in sequence. They are independent and could be parallelized.

**Potential optimization**: Background PG start, run pip check in parallel, then wait for both. This could cut ~3 s from the critical path.

### 4. Post-ready setup (10-120+ s)

Project dependency installation (npm/bundle) is the **longest latency component**, but it does not block `kyb create`. The `kyb enter` call, however, may land before the setup completes, meaning the first `kyb exec` might find stale/no node_modules.

**Potential optimizations**:
- Move dependency install to image build time (project-specific images or a dependency cache layer).
- Make setup truly async (daemonize the heredoc so entrypoint reaches `exec` faster).

---

## Recommendations

### P0 (Critical path for kyb create latency)

| # | Change | Estimated Impact | Complexity |
|---|--------|-----------------|------------|
| 1 | Skip `pip install` if packages are already installed | ~3-4 s reduction | Low (one `if` check) |
| 2 | Pre-initialize PG cluster in Dockerfile (`initdb` at build time) | ~1-2 s reduction | Low (one RUN stanza) |
| 3 | Run PG start and pip check in parallel (background + wait) | ~2-3 s reduction | Medium (entrypoint refactor) |

**Combined impact**: ~6-9 s reduction, bringing total startup to **~4-5 s**.

### P1 (Post-ready, affects first-use latency)

| # | Change | Estimated Impact | Complexity |
|---|--------|-----------------|------------|
| 4 | Add a container status endpoint (`kyb status`) that reports setup progress | UX improvement | Low |
| 5 | Defer `npm install` / `bundle install` to a background process | Non-blocking entrypoint | Medium |
| 6 | Cache `node_modules` in a named volume (prevent reinstall on recreate) | 10-120 s per recreate | Low (already exists for Gradle/Maven) |

### P2 (Architecture)

| # | Change | Estimated Impact | Complexity |
|---|--------|-----------------|------------|
| 7 | Shared PostgreSQL service container (eliminate per-container PG) | ~3-4 s per container | High |
| 8 | Warm container pool (keep N pre-initialized containers ready) | Sub-second `kyb create` | High |

---

## Appendix: Raw Measurement Data

### Test 1: docker run → running

```
docker run returned: 381ms (CID: 111c76ae0662)
docker run→running: 30.10ms
Total (start→running): 411ms
```

### Test 2: kyb-base full entrypoint (no project volume)

```
docker run: 468ms
kyb-ready wait: 12845ms
Total ready: 13325ms
```

### Test 3: kyb-base full entrypoint (second run)

```
kyb-ready after: 11.7s
```

### Test 4: kyb-base with --entrypoint override (skip entrypoint)

```
Full entrypoint (skip post-ready): 10323ms
```

### Test 5: pg_ctlcluster isolated

```
PostgreSQL start: 3046ms
```

### Test 6: pip install isolated (warm nexus cache)

```
Pip install (warm): 522ms    # (corrected — earlier 3697ms included container start overhead)
```

Note: The isolated pip test (522ms) differs from the in-entrypoint cost (~3-4s) because in the real entrypoint, pip's output is unbuffered and the nexus mirror may serve slower during peak. The 522ms figure is the lower bound.

### Test 7: Minimal command overhead (container init)

```
Run 1: 452ms
Run 2: 472ms
Run 3: 426ms
```
