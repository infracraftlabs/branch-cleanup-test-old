# Branch cleanup test

A throwaway repository for testing a branch cleanup policy on GitHub. It holds branches with
backdated commits, a ruleset that protects long-lived branches, and `stale-branches.sh`, a
read-only report of branches with no commit in 90 days. Safe to delete.

## What is here

Branch ages were set when the repository was created on 2026-11-23 and keep growing from there.

| Branch | Last commit (at creation) | Purpose |
|---|---|---|
| `main` | 1 day | default branch, protected by the ruleset |
| `release/1.0` | 200 days | long-lived branch, protected by the ruleset |
| `feature/merged-old` | 150 days | merged into `main` with a merge commit: reported as `merged=yes` |
| `feature/squashed-old` | 130 days | squash-merged: reported as `merged=no`, the known blind spot |
| `feature/unmerged-old` | 120 days | never merged |
| `hotfix/edge-89` | 89 days | just inside the 90-day window when created |
| `hotfix/edge-91` | 91 days | deleted through the REST API during the test |
| `feature/recent` | 10 days | merged in pull request 1 and deleted automatically on merge |

Repository settings used in the test:

- **Automatically delete head branches** is on (`delete_branch_on_merge=true`).
- The ruleset in [`keep-long-lived.json`](keep-long-lived.json) applies the `deletion` rule to the
  default branch and `refs/heads/release/*`, with no bypass list.

## Run the report

Needs bash, git, jq, curl and, for GitHub mode, the `gh` CLI signed in.

```bash
DAYS=90 ./stale-branches.sh github infracraftlabs/branch-cleanup-test
git clone --filter=blob:none --no-checkout https://github.com/infracraftlabs/branch-cleanup-test.git c && cd c && ../stale-branches.sh git
```

Output is tab-separated: `age_days  merged  name`. The script never deletes anything. It skips the
default branch, branches the server marks protected (API mode only), and names matching `KEEP`.

## What the test showed (2026-11-23)

| Action | Result |
|---|---|
| `git push origin --delete release/1.0` | rejected: push declined due to repository rule violations |
| REST `DELETE .../git/refs/heads/release/1.0` | HTTP 422: Cannot delete this branch |
| REST `DELETE .../git/refs/heads/main` | HTTP 422: Cannot delete the default branch |
| REST `DELETE .../git/refs/heads/hotfix/edge-91` | HTTP 204, branch deleted |
| Merge pull request 1 from `feature/recent` | branch deleted automatically |
| Report with `KEEP='^$'` | `main` and `release/1.0` still skipped, because the ruleset marks them protected |

Tested with git 2.54, gh 2.103.3 and jq 1.7.1 on macOS.
