# Runtime Layer — boss-12 (192.168.215.12)

All runtimes managed by **mise** at `/home/dev/.local/bin/mise` (v2026.5.12 linux-arm64).

## Mise Tools

| Tool | Version | Installed Path |
|------|---------|----------------|
| mise | 2026.5.12 | `/home/dev/.local/bin/mise` |
| ruby | 3.3.11 | mise-managed |
| node | v25.9.0 | mise-managed |
| python | 3.10.20 | mise-managed |
| maven | 3.9.16 | mise-managed |
| glab | 1.92.1 | mise-managed |
| clickhouse | 26.4.2.10 | mise-managed |
| claude-code | 2.x (npm) | mise-managed |

## System Tools

| Tool | Version |
|------|---------|
| git | 2.43.0 |
| make | GNU Make 4.3 |
| psql (PostgreSQL) | 16.13 (Ubuntu) |
| clickhouse-client | 26.4.2.10 |
| Docker | 29.1.3 (client only) |
| Docker Compose | 2.40.3 |
| glab | 1.92.1 |

## Tools NOT Installed

- `gh` (GitHub CLI) — not present
- Go — not installed
- Java / JDK — not installed
- `curl`/`wget` — not confirmed

## Shell Init

- Bash shell (`/bin/bash`)
- Mise activated via `eval "$($HOME/.local/bin/mise activate bash)"` in `.bashrc`
- `.bash_profile` sources `.bashrc`
- No proxy env vars set

## Config Files

| File | Content |
|------|---------|
| `~/.gitconfig` | `safe.directory = /home/dev/.claude` only |
| `~/.ssh/config` | None |
| `~/.npmrc` | Present (empty/minimal) |
| `~/.gemrc` | Present (empty/minimal) |
| `~/.pip/` | Present |
| `~/.m2/` | Present (Maven cache) |
| `~/.gradle/` | Present (Gradle cache) |
| `~/.bundle/` | Present |

## Environment PATH

```
~/.local/share/mise/installs/ruby/3.3/bin:
~/.local/share/mise/installs/node/25/bin:
~/.local/share/mise/installs/python/3.10/bin:
~/.local/share/mise/installs/maven/3.9/apache-maven-3.9.16/bin:
~/.local/share/mise/installs/glab/1.92/bin:
~/.local/share/mise/installs/clickhouse/26/bin:
~/.local/share/mise/installs/npm-anthropic-ai-claude-code/2/bin:
~/.local/bin:
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:
/usr/games:/usr/local/games:/snap/bin
```
