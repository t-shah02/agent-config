#!/usr/bin/env bash

set -euo pipefail

DAYS_LIMIT="${1:-4}"
REPO_LIMIT="${REPO_LIMIT:-15}"

if ! [[ "$DAYS_LIMIT" =~ ^[0-9]+$ ]]; then
  echo "days must be an integer (received: $DAYS_LIMIT)" >&2
  exit 1
fi

if [ "$DAYS_LIMIT" -lt 1 ] || [ "$DAYS_LIMIT" -gt 7 ]; then
  echo "days must be between 1 and 7 (received: $DAYS_LIMIT)" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required but not installed." >&2
  exit 1
fi

SINCE_DATE="$(date -u -d "$DAYS_LIMIT days ago" +"%Y-%m-%dT%H:%M:%SZ")"

REPOS="$(gh repo list --limit "$REPO_LIMIT" --json nameWithOwner --jq '.[].nameWithOwner')"

echo "Activity summary since: $SINCE_DATE"
echo "--------------------------------"

printf "%s\n" "$REPOS" | while IFS= read -r REPO; do
  [ -z "$REPO" ] && continue

  COMMITS="$(gh api "repos/$REPO/commits?since=$SINCE_DATE" \
    --jq '.[] | "- " + .commit.message + " (" + .sha[:7] + ")"' || true)"

  if [ -n "$COMMITS" ]; then
    echo "## Repository: $REPO"
    echo "$COMMITS"
    echo
  fi
done
