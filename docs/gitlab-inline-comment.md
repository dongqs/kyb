# GitLab Inline DiffNotes via API

Post line-specific comments ("DiffNotes") on GitLab MR diffs using the Discussions API.

## Key Insight

**Don't use** `POST /projects/:id/merge_requests/:iid/notes` — that creates a **regular top-level comment**, not an inline DiffNote.

**Use** `POST /projects/:id/merge_requests/:iid/discussions` instead. This endpoint handles both inline notes and top-level thread replies.

## Required SHA Values

You need three SHAs from the MR source branch:

```bash
# On the source branch:
base_sha=$(git rev-parse origin/main)     # target branch HEAD
start_sha=$(git rev-parse origin/main)    # same as base_sha when commenting on diff vs. target
head_sha=$(git rev-parse HEAD)            # source branch HEAD
```

## Working API Call

```bash
glab api -X POST \
  "projects/:id/merge_requests/:iid/discussions" \
  -f body="your comment text here" \
  -f position[base_sha]="$base_sha" \
  -f position[start_sha]="$start_sha" \
  -f position[head_sha]="$head_sha" \
  -f position[position_type]=text \
  -f position[new_path]="path/to/file.rb" \
  -f position[old_path]="path/to/file.rb" \
  -f position[new_line]=42
```

### Parameters Explained

| Field | Value | Description |
|---|---|---|
| `position[base_sha]` | `origin/main` HEAD | The SHA of the base/target branch |
| `position[start_sha]` | Same as `base_sha` | The SHA at which the diff comparison starts |
| `position[head_sha]` | Source branch HEAD | The latest commit SHA on the MR source branch |
| `position[position_type]` | `text` | For file-level comments (as opposed to image) |
| `position[new_path]` | File path | Path in the new (source branch) version |
| `position[old_path]` | File path | Path in the old (target branch) version — same as new_path unless the file was renamed |
| `position[new_line]` | Line number | The line in the new file to attach the comment to |

### Line Numbering Rules

- **`new_line`**: Line number in the **new** file. GitLab will validate that this line is part of the diff.
- If you want to comment on a deleted line (only in `old_path`), use `old_line` instead of `new_line`.
- The line **must** be part of the diff hunk shown in the MR. If the line is out of range, GitLab returns a `400` error.

## Full Example Script

```bash
#!/usr/bin/env bash
set -euo pipefail

PROJECT_ID="42"       # GitLab project ID
MR_IID="123"          # MR internal ID (no leading #)

# Get SHAs
base_sha=$(git rev-parse origin/main)
start_sha="$base_sha"
head_sha=$(git rev-parse HEAD)

FILE="app/models/user.rb"
LINE=87

glab api -X POST \
  "projects/$PROJECT_ID/merge_requests/$MR_IID/discussions" \
  -f body="## Review Comment\n\nThis method needs error handling. Consider wrapping with `rescue`." \
  -f "position[base_sha]=$base_sha" \
  -f "position[start_sha]=$start_sha" \
  -f "position[head_sha]=$head_sha" \
  -f "position[position_type]=text" \
  -f "position[new_path]=$FILE" \
  -f "position[old_path]=$FILE" \
  -f "position[new_line]=$LINE"
```

## Using `glab mr comment` (Simpler Alternative)

If you only need multi-line suggestions (not arbitrary inline comments), `glab` provides a shorthand:

```bash
glab mr comment 123 -m "suggestion" --force-line-note
```

Under the hood this uses the same `/discussions` endpoint.

## Troubleshooting

| Error | Likely Cause |
|---|---|
| `400 {position is not valid}` | Wrong SHA values — re-check `git rev-parse` |
| `400 is not a valid line code` | The line number is not in the MR diff — double-check the file and line |
| `404` | Wrong project ID or MR IID |
| A comment appears, but not inline | You used `/notes` instead of `/discussions` |

## References

- [GitLab API: Create MR Discussion](https://docs.gitlab.com/ee/api/discussions.html#create-new-merge-request-discussion)
- [GitLab API: Position parameter](https://docs.gitlab.com/ee/api/discussions.html#create-a-thread-in-a-merge-request-diff)
