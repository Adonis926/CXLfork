#!/bin/bash
set -euo pipefail

REPO_NAME="${1:-cxlfork-repro}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is not installed. Install it first, for example:"
  echo "  sudo apt-get update && sudo apt-get install -y gh"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Run:"
  echo "  gh auth login"
  exit 1
fi

cd "$(dirname "$0")/.."
git branch -M main
gh repo create "$REPO_NAME" --private --source=. --remote=origin --push

