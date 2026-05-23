---
decision: 稍后做
---

# Review E2: GitLab API for Issue Automation

> Review of the GitLab API integration for polling new issues.
> Design doc: `docs/infra/designs/issue-automation.md`

## Summary

`check-issues.sh` uses the GitLab REST API via `curl` to fetch issues and detect new
ones. This review covers API design, authentication, pagination, and error handling.

## Findings

### 1. API Endpoint

**Recommendation**: Use the project-level issues endpoint with a `updated_after` filter:

```
GET /api/v4/projects/:id/issues?updated_after=2026-05-23T00:00:00Z&scope=all&per_page=100
```

- `scope=all` includes issues created by all users (not just the authenticated one).
- `updated_after` reduces payload size per poll.
- `per_page=100` minimizes round trips (max allowed by GitLab).

**Do not** use the `/api/v4/issues` (global) endpoint — it requires admin access for
cross-project queries and is significantly slower.

### 2. Authentication

**Risk**: Token embedded in a shell script checked into the repo or visible in
`ps aux` output.

**Mitigation**:

- Read token from a file (`/run/secrets/gitlab_token` or mounted Docker secret).
- Never pass token as a command-line argument or env var printed to logs.
- Use a project-scoped token (not a personal access token) with minimal scopes:
  `read_api`.

### 3. Pagination

**Risk**: Default `per_page` is 20. If more than 20 issues were created since last poll,
the script silently misses issues on later pages.

**Mitigation**:

- Set `per_page=100` (maximum).
- Parse the `Link` header or `X-Total-Pages` header to iterate all pages.
- With a 10-minute poll interval, 100 issues per poll is a safe upper bound for most
  projects. Add pagination logic as a safety net.

### 4. Rate Limiting

**Risk**: GitLab enforces rate limits (default: 600 requests per minute for API).
A misconfigured poll loop or a bug causing rapid retries may trigger a ban.

**Mitigation**:

- One request per poll cycle (with pagination safety) is well within limits.
- Implement exponential backoff on 429 responses.
- Log rate limit headers (`RateLimit-Remaining`, `RateLimit-Reset`) for observability.

### 5. Error Handling

| HTTP Status | Meaning | Action |
|-------------|---------|--------|
| 200 | Success | Parse response |
| 401 | Bad/expired token | Alert ops channel, stop polling |
| 403 | Insufficient scope | Alert ops channel, stop polling |
| 429 | Rate limited | Backoff and retry |
| 5xx | GitLab outage | Retry next cycle, log warning |

**Critical**: A non-200 response should **never** reset `last_issue_id`, or all
existing issues will be re-notified when the API recovers.

### 6. Issue ID Tracking

- Use GitLab's internal `iid` (project-scoped sequential integer), not `id` (globally
  unique integer). IID is monotonic within a project and easier to compare.
- Store `last_iid` persistently (see E1 review).

## Conclusion

GitLab API is straightforward for polling. Key risks are token exposure and pagination.
Both are easily mitigated. **Approve** with token-from-file and pagination handled.
