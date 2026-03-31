---
name: github-activity-summarizer
description: Summarize the commit activity on all Github activity over a given period of time.
author: tanish.shah
version: 1.0.0
allowed-tools:
  - Bash(gh:*)
---

## Description

This skill is used to summarize the commit activity on all Github activity over a given period of time.

## Parameters

| Name   | Type      | Description                                   | Required | Constraints    |
| :----- | :-------- | :-------------------------------------------- | :------- | :------------- |
| `days` | `integer` | The number of days to look back for activity. | Yes      | Min: 1, Max: 7 |

## Execution Logic

You should execute the following bash script using the `gh` (GitHub CLI) tool to aggregate data across repositories.

```bash
#!/bin/bash

# Define the timeframe
DAYS_LIMIT=$1
SINCE_DATE=$(date -d "$DAYS_LIMIT days ago" +"%Y-%m-%dT%H:%M:%SZ")

# Get the list of the most recently active repositories (limit 15 for performance)
REPOS=$(gh repo list --limit 15 --json fullName --jq '.[].fullName')

echo "Activity summary since: $SINCE_DATE"
echo "--------------------------------"

for REPO in $REPOS; do
  # Fetch commits from the authenticated user only
  COMMITS=$(gh api "repos/$REPO/commits?since=$SINCE_DATE" \
    --jq '.[] | "- " + .commit.message + " (" + .sha[:7] + ")"')

  if [ ! -z "$COMMITS" ]; then
    echo "## Repository: $REPO"
    echo "$COMMITS"
    echo ""
  fi
done
```
