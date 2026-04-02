---
name: browser-history-summarizer
description: >-
  Exports recent local browser history (visit time, URL, title) on Linux, writes a
  timestamped CSV under /tmp/browser_history_artifacts/, and prints the artifact
  path. Use when the user asks to summarize, review, or list recent browsing
  history, visited sites, or tabs from their default browser (Chromium family or
  Firefox).
author: tanish.shah
version: 1.0.0
allowed-tools:
  - Bash(python3:*)
  - Read
---

## Description

Runs the bundled Python script against the **default browser** on **Linux** (KDE `kreadconfig6` or `xdg-settings`, then resolves the profile `History` or `places.sqlite` path). Copies the SQLite DB to a temp file to avoid lock errors while the browser is open, queries recent visits, prints human-readable lines to stdout, and saves **`/tmp/browser_history_artifacts/browser_history_<timestamp>.csv`**.

Requires **Python 3.11+** and the **standard library only** (`utils.py` is a sibling import).

## Parameters

| Name           | CLI flag          | Type    | Default | Description                                      |
| :------------- | :---------------- | :------ | :------ | :----------------------------------------------- |
| `period_days`  | `-p` / `--period-days` | integer | 7       | Only visits from the last *D* days (UTC cutoff). |
| `limit`        | `-l` / `--limit`  | integer | 50      | Max rows returned, newest first.                 |

## Execution

1. `cd` to the skill directory (the folder that contains this `SKILL.md` and `scripts/`).
2. Run:

```bash
python3 scripts/get_browser_history.py -p <period_days> -l <limit>
```

Examples:

```bash
python3 scripts/get_browser_history.py -p 7 -l 100
python3 scripts/get_browser_history.py --period-days 1 --limit 25
```

## Output and follow-up

- **Stdout:** Status lines, then one line per visit: `visit_time | title | url`, then `Saved browser history CSV artifact: <path>`, then **a final line that is only the absolute CSV path** (use this path for the next step).
- **Artifact:** CSV with header `visit_time,url,title` (UTF-8). **Read that file** to summarize or answer questions; do not rely only on truncated terminal scrollback for large limits.

## Supported browsers

Chromium-based paths under `~/.config` (e.g. Brave, Chrome, Chromium, Edge, Opera, Vivaldi) and Firefox / Librewolf (`places.sqlite`). Unknown desktop IDs raise a clear error from `resolve_browser_history_path`.

## Notes

- **Privacy:** History can contain sensitive URLs; treat the CSV and terminal output as confidential unless the user says otherwise.
- **Environment:** Linux only; uses the invoking user’s `$HOME` and default browser detection.
- If the script fails with a missing DB path, confirm the default browser matches a supported mapping or ask the user which browser to target (future extension: explicit browser flag).
