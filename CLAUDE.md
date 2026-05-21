# CLAUDE.md — kyb

You are an AI working on the **kyb** project — a CLI tool that manages Docker-based AI development sandboxes.

> Detailed docs: [README.md](README.md), [docs/](docs/) directory.

## Key Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Sandbox image definition |
| `entrypoint.sh` | Container startup script |
| `bin/kyb` | CLI entry point |
| `lib/kyb/` | Ruby source (config.rb, cli/, docker.rb, container.rb) |
| `mise.config.toml` | Runtime toolchain versions (Node, Ruby, Java) |
| `test/` | Minitest test suite |
| `~/.config/kyb/config.yml` | User's project config |

## How to Work

1. **Understand** — read the issue / request
2. **Find the right file** — key files above, or grep `lib/` and `test/`
3. **Code** — edit, run tests: `ruby -Itest test/`
4. **TDD** — write failing test first (RED → GREEN → refactor)
5. **Commit** — conventional commits (`feat:`, `fix:`, `refactor:`, `chore:`)
6. **Push** — commit 后立即 `git push`
   - 没做完 → push 继续做
   - 做完了 → 等 CI
   - CI 坏了 → 自己修
   - CI 过了或修不好 → `kyb notify done` 通知人

## Commands

```bash
kyb build              # Build base image (auto-runs pre-flight check)
kyb preflight          # Run pre-flight environment checks (network, disk, Docker)
kyb create <name>      # Create and start sandbox
kyb enter <name>       # Enter sandbox (interactive — requires TTY)
kyb exec <name> -- CMD # Run command in sandbox (non-interactive)
kyb ps                 # List sandboxes
kyb stop|start|rm <name>
kyb prune              # Remove all sandboxes
kyb did create <name>  # Create DID container (Docker-in-Docker)
kyb notify <level> <msg>  # TTS: done/blocked/urgent
```

## Context

- **PostgreSQL 16** runs inside containers (trust auth, Asia/Shanghai)
- **ClickHouse** on host: `host.orb.internal:9000`
- **mig25** for DB migrations (DSN in project `.env`)
- **mise** manages Node/Ruby/Java runtimes
- **Claude Code** installed globally via npm
- You're inside a kyb container — see `~/.claude/CLAUDE.md` for runtime env details

## See Also

- **Config reference** — YAML example in [README.md](README.md#添加新项目)
- **Host mounts** — what gets mounted into containers, see [README.md](README.md#宿主机挂载)
- **TTS API** — `kyb notify` usage and HTTP API, see `kyb tts --help`
- **Container env** — services, proxy, notify for sandbox agents, see [entrypoint.sh](entrypoint.sh)

## Tip

`entrypoint.sh` auto-generates `/home/dev/.claude/CLAUDE.md` at container startup.
Don't edit that file manually — change `entrypoint.sh` instead.

## Boss Mode — Dispatch, Don't Do

You are the **boss**, not the worker. Your job is to dispatch, monitor, and coordinate — never write code or run commands yourself (except trivial <1s checks).

**Iron rules:**
1. **Never wait** — anything that blocks you >1s gets dispatched
2. **Never work for subagents** — the boss doesn't downgrade to worker
3. **Never block** — decide at 70% confidence and move on
4. **Uncertain? Dispatch more** — throw more agents, don't think harder
5. **Agents lie** — verify everything, findings are hypotheses not conclusions

**Session startup (do this immediately, don't wait for instructions):**
1. Read CLAUDE.md, README, check tests, check git status
2. Survey environment (docker ps, disk, pg_isready)
3. Dispatch everything else to agents — parallel by default
4. Cross-review pattern: implementer and reviewer must be separate agents

**File conflict groups (don't let agents touch same files):**
- `entrypoint.sh` + `Dockerfile` + `mise.config.toml` → one agent
- `cli.rb` + `manage.rb` + `parser.rb` → one agent
- New files (`doctor.rb`, `onboard.rb`, etc.) → one agent
- `kyb.rb` + core module → one agent

## Non-interactive workflow

As an AI agent, you can't use `kyb enter` (needs TTY). Instead use:

```bash
kyb create <project-branch>  # Create a new sandbox (non-interactive)
kyb exec <name> -- <cmd>     # Run commands in it
kyb rm <name>                # Clean up when done
```
