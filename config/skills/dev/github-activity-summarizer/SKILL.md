---
name: github-activity-summarizer
description: Summarize commit activity across GitHub repositories over a given period.
author: tanish.shah
version: 1.0.0
allowed-tools:
  - Bash(gh:*)
---

## Description

This skill summarizes commit activity across repositories over a configurable number of days.

## Parameters

| Name   | Type      | Description                                   | Required | Constraints    |
| :----- | :-------- | :-------------------------------------------- | :------- | :------------- |
| `days` | `integer` | The number of days to look back for activity. | Yes      | Min: 1, Max: 7 |

## Execution Logic

Run the script in `scripts/github_activity_summary.sh` with the `days` argument.

```bash
bash scripts/github_activity_summary.sh 4
```

## Notes

- Uses `nameWithOwner` (compatible with current `gh repo list` schema).
- Uses a line-by-line loop to avoid shell word-splitting issues in zsh/bash.
