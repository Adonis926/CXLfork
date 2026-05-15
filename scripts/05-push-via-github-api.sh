#!/bin/bash
set -euo pipefail

OWNER="${1:-qmyyxtl}"
REPO="${2:-cxlfork-repro}"
BRANCH="${3:-main}"

cd "$(dirname "$0")/.."

tmp_tree="$(mktemp)"
trap 'rm -f "$tmp_tree"' EXIT
printf '[]' > "$tmp_tree"

while read -r mode type sha path; do
  if [[ "$type" == "blob" ]]; then
    sha="$(
      jq -n --rawfile content "$path" '{content:$content, encoding:"utf-8"}' |
        gh api -X POST "repos/${OWNER}/${REPO}/git/blobs" --input - |
        jq -r '.sha'
    )"
  fi
  jq \
    --arg path "$path" \
    --arg mode "$mode" \
    --arg type "$type" \
    --arg sha "$sha" \
    '. + [{path:$path, mode:$mode, type:$type, sha:$sha}]' \
    "$tmp_tree" > "${tmp_tree}.next"
  mv "${tmp_tree}.next" "$tmp_tree"
done < <(git ls-tree -r HEAD)

base_tree_args=()
if base_sha="$(gh api "repos/${OWNER}/${REPO}/git/ref/heads/${BRANCH}" --jq '.object.sha' 2>/dev/null)"; then
  base_tree="$(gh api "repos/${OWNER}/${REPO}/git/commits/${base_sha}" --jq '.tree.sha')"
  base_tree_args=(-f "base_tree=${base_tree}")
else
  base_sha=""
fi

tree_sha="$(
  jq -n --slurpfile tree "$tmp_tree" '{tree:$tree[0]}' |
    gh api -X POST "repos/${OWNER}/${REPO}/git/trees" "${base_tree_args[@]}" --input - |
    jq -r '.sha'
)"

commit_payload="$(jq -n \
  --arg message "$(git log -1 --pretty=%B)" \
  --arg tree "$tree_sha" \
  --arg parent "$base_sha" \
  'if $parent == "" then {message:$message, tree:$tree} else {message:$message, tree:$tree, parents:[$parent]} end')"

commit_sha="$(
  printf '%s' "$commit_payload" |
    gh api -X POST "repos/${OWNER}/${REPO}/git/commits" --input - |
    jq -r '.sha'
)"

if [[ -n "$base_sha" ]]; then
  gh api -X PATCH "repos/${OWNER}/${REPO}/git/refs/heads/${BRANCH}" -f sha="$commit_sha" -F force=false >/dev/null
else
  gh api -X POST "repos/${OWNER}/${REPO}/git/refs" -f ref="refs/heads/${BRANCH}" -f sha="$commit_sha" >/dev/null
fi

gh api -X PATCH "repos/${OWNER}/${REPO}" -f default_branch="$BRANCH" >/dev/null

echo "Pushed ${commit_sha} to https://github.com/${OWNER}/${REPO}/tree/${BRANCH}"
