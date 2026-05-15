#!/bin/bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "usage: $0 OWNER REPO BRANCH PATH..." >&2
  exit 1
fi

OWNER="$1"
REPO="$2"
BRANCH="$3"
shift 3

base_sha="$(gh api "repos/${OWNER}/${REPO}/git/ref/heads/${BRANCH}" --jq '.object.sha')"
base_tree="$(gh api "repos/${OWNER}/${REPO}/git/commits/${base_sha}" --jq '.tree.sha')"

tmp_tree="$(mktemp)"
trap 'rm -f "$tmp_tree"' EXIT
printf '[]' > "$tmp_tree"

for path in "$@"; do
  entry="$(git ls-tree HEAD -- "$path")"
  if [[ -z "$entry" ]]; then
    echo "path not found in HEAD: $path" >&2
    exit 1
  fi
  read -r mode type sha name <<<"$entry"
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
done

tree_sha="$(
  jq -n --slurpfile tree "$tmp_tree" '{tree:$tree[0]}' |
    gh api -X POST "repos/${OWNER}/${REPO}/git/trees" -f "base_tree=${base_tree}" --input - |
    jq -r '.sha'
)"

message="$(git log -1 --pretty=%B)"
author_name="$(git log -1 --pretty=%an)"
author_email="$(git log -1 --pretty=%ae)"
author_date="$(git log -1 --pretty=%aI)"
committer_name="$(git log -1 --pretty=%cn)"
committer_email="$(git log -1 --pretty=%ce)"
committer_date="$(git log -1 --pretty=%cI)"

commit_sha="$(
  jq -n \
    --arg message "$message" \
    --arg tree "$tree_sha" \
    --arg parent "$base_sha" \
    --arg an "$author_name" \
    --arg ae "$author_email" \
    --arg ad "$author_date" \
    --arg cn "$committer_name" \
    --arg ce "$committer_email" \
    --arg cd "$committer_date" \
    '{
      message:$message,
      tree:$tree,
      parents:[$parent],
      author:{name:$an,email:$ae,date:$ad},
      committer:{name:$cn,email:$ce,date:$cd}
    }' |
    gh api -X POST "repos/${OWNER}/${REPO}/git/commits" --input - |
    jq -r '.sha'
)"

gh api -X PATCH "repos/${OWNER}/${REPO}/git/refs/heads/${BRANCH}" -f sha="$commit_sha" -F force=false >/dev/null

echo "Pushed ${commit_sha} to https://github.com/${OWNER}/${REPO}/tree/${BRANCH}"
