#!/usr/bin/env bash
# stale-branches.sh: read-only report of branches with no commit in DAYS days.
#   stale-branches.sh git [remote]        run inside a clone (default remote: origin)
#   stale-branches.sh github OWNER/REPO   uses the gh CLI and its login
#   stale-branches.sh gitlab GROUP%2FPROJ public projects, or set GITLAB_TOKEN
# Env: DAYS (default 90), KEEP (regex of names never reported), GITLAB_URL (gitlab mode).
# Output (tab-separated): age_days  merged  name. It never deletes anything.
set -euo pipefail
DAYS=${DAYS:-90}
KEEP=${KEEP:-'^(main|master|develop|release/.*)$'}
now=$(date +%s)
cutoff=$(( now - DAYS * 86400 ))

# Every source prints: epoch <TAB> merged(yes/no) <TAB> protected(yes/no/-) <TAB> name
from_git() {
  local remote=$1 default merged ts ref
  git fetch --prune --quiet "$remote"
  default=$(git symbolic-ref --short "refs/remotes/$remote/HEAD")   # e.g. origin/main
  merged=$(git for-each-ref --merged "$default" --format='%(refname:short)' "refs/remotes/$remote")
  git for-each-ref --format='%(committerdate:unix)%09%(refname:short)' "refs/remotes/$remote" |
  while IFS=$'\t' read -r ts ref; do
    if [ "$ref" = "$default" ] || [ "$ref" = "$remote" ]; then continue; fi  # skip default and HEAD
    if grep -qxF "$ref" <<<"$merged"; then m=yes; else m=no; fi
    printf '%s\t%s\t-\t%s\n' "$ts" "$m" "${ref#"$remote"/}"
  done
}

from_github() {
  local repo=$1 default protected
  default=$(gh api "repos/$repo" --jq .default_branch)
  protected=$(gh api --paginate "repos/$repo/branches?protected=true&per_page=100" --jq '.[].name')
  gh api graphql --paginate -F owner="${repo%%/*}" -F name="${repo#*/}" -F base="$default" -f query='
    query($owner: String!, $name: String!, $base: String!, $endCursor: String) {
      repository(owner: $owner, name: $name) {
        refs(refPrefix: "refs/heads/", first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes { name
            target { ... on Commit { committedDate } }
            compare(headRef: $base) { behindBy } } } } }' \
    --jq '.data.repository.refs.nodes[] | [(.target.committedDate | fromdateiso8601),
          (if .compare.behindBy == 0 then "yes" else "no" end), .name] | @tsv' |
  while IFS=$'\t' read -r ts m name; do
    [ "$name" = "$default" ] && continue
    if grep -qxF "$name" <<<"$protected"; then p=yes; else p=no; fi
    printf '%s\t%s\t%s\t%s\n' "$ts" "$m" "$p" "$name"
  done
}

from_gitlab() {
  local api="${GITLAB_URL:?set GITLAB_URL to your GitLab base URL}/api/v4/projects/$1/repository/branches" page=1 body
  while :; do
    # An empty "PRIVATE-TOKEN:" value makes curl drop the header, so public projects need no token.
    body=$(curl -fsS -H "PRIVATE-TOKEN:${GITLAB_TOKEN:-}" "$api?per_page=100&page=$page")
    [ "$(jq length <<<"$body")" -eq 0 ] && break
    jq -r 'def epoch: capture("^(?<d>[0-9-]{10}T[0-9:]{8})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$")
             | (.d + "Z" | fromdateiso8601) - (if .z == "Z" then 0 else
               ((.z[1:3] | tonumber) * 3600 + (.z[4:6] | tonumber) * 60)
               * (if .z[0:1] == "+" then 1 else -1 end) end);
           .[] | select(.default | not)
           | [(.commit.committed_date | epoch), (if .merged then "yes" else "no" end),
              (if .protected then "yes" else "no" end), .name] | @tsv' <<<"$body"
    page=$(( page + 1 ))
  done
}

case "${1:-}" in
  git)    src() { from_git "${2:-origin}"; } ;;
  github) src() { from_github "$2"; } ;;
  gitlab) src() { from_gitlab "$2"; } ;;
  *) echo "usage: $0 git [remote] | github OWNER/REPO | gitlab GROUP%2FPROJECT" >&2; exit 2 ;;
esac

printf 'age_days\tmerged\tname\n'
src "$@" | while IFS=$'\t' read -r ts m p name; do
  [ "$p" = yes ] && continue                 # protected on the server: never a cleanup candidate
  [[ "$name" =~ $KEEP ]] && continue         # default, release and other long-lived names
  [ "$ts" -lt "$cutoff" ] || continue        # touched in the last DAYS days
  printf '%s\t%s\t%s\n' $(( (now - ts) / 86400 )) "$m" "$name"
done | sort -rn
