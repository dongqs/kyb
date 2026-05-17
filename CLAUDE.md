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
6. **Push & MR** — `git push`, then create merge request

## Commands

```bash
kyb build              # Build base image
kyb create <name>      # Create and start sandbox
kyb enter <name>       # Enter sandbox
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
