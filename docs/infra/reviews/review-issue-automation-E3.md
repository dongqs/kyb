---
decision: 稍后做
---

# Review E3: curl for Issue Automation

> Review of the curl-based script approach for GitLab API calls.
> Design doc: `docs/infra/designs/issue-automation.md`

## Summary

`check-issues.sh` uses `curl` to call the GitLab API and `jq` to parse responses.
This review covers script-level reliability, security, and edge cases.

## Findings

### 1. Token Security in curl

**Risk**: Passing `PRIVATE-TOKEN` in the command line exposes it in `ps aux`:

```sh
# DANGEROUS: visible to all users on the system
curl -H "PRIVATE-TOKEN: $token" ...
```

**Mitigation**: Use `curl -H @/path/to/headers.txt` or read token from a file with
`$(cat /run/secrets/gitlab_token)` and pass via stdin or `-K` config file.

### 2. curl Error Handling

**Default behavior**: curl exits 0 even on HTTP errors (4xx, 5xx) unless `-f` is
passed.

**Recommendation**: Always use `-fsSL`:

```sh
curl -fsSL -H "PRIVATE-TOKEN: $(cat /run/secrets/gitlab_token)" \
  "https://git.leyantech.com/api/v4/projects/:id/issues?per_page=100"
```

- `-f`: Fail on HTTP error (non-zero exit on 4xx/5xx).
- `-s`: Silent (no progress meter).
- `-S`: Show errors (still show error messages).
- `-L`: Follow redirects (GitLab API occasionally redirects).

### 3. JSON Parsing with jq

**Risk**: `jq` fails silently if the API returns an empty body, HTML error page, or
malformed JSON.

**Mitigation**:

- Validate API response before piping to `jq`:
  ```sh
  response=$(curl -fsSL ...)
  echo "$response" | jq -e '.' > /dev/null 2>&1 || {
    echo "ERROR: invalid JSON response" >&2
    exit 1
  }
  ```
- Use `jq -e` to get non-zero exit on filter failure (e.g., missing field).
- Wrap `jq` calls in `set -e` protected context to catch parse errors.

### 4. Shell Script Robustness

| Pattern | Issue | Fix |
|---------|-------|-----|
| `set -e` missing | Script continues on error | Add `set -euo pipefail` |
| Unquoted variables | Word splitting on spaces/special chars | Always `"$variable"` |
| Missing `||` fallback | Pipeline failure kills whole script | Handle expected failures gracefully |
| `$(...)` without default | Empty state file causes errors | Use `${state:-0}` for default |

### 5. Idempotency

**Risk**: If the script is killed mid-execution (after sending notification but before
writing state), the next run re-notifies.

**Mitigation**: Write state file atomically:

```sh
echo "$last_iid" > /tmp/last_iid.tmp
mv /tmp/last_iid.tmp /data/last_iid
```

This ensures the state file is never truncated mid-write.

### 6. Cron Environment

**Risk**: Cron runs with a minimal `PATH` and no interactive shell config. `curl`,
`jq`, or other tools may not be found.

**Mitigation**: Set `PATH` explicitly at the top of the script:

```sh
export PATH="/usr/local/bin:/usr/bin:/bin"
```

Also log script output to a file for debugging:

```
*/10 * * * * sh /scripts/check-issues.sh >> /var/log/issue-automation.log 2>&1
```

## Conclusion

The curl approach is simple and effective. The script needs hardening (token security,
error handling, atomic writes). With those changes it is production-ready.
**Conditionally approve**: address token exposure and add `-f` flag before deploying.
