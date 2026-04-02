#!/usr/bin/env python3

from __future__ import annotations

import argparse

from utils import (
    browser_history_connection,
    fetch_recent_history,
    get_default_browser,
    resolve_browser_history_path,
    write_browser_history_csv,
)

# defaults
DEFAULT_LOOKBACK_DAYS = 7
DEFAULT_ITEM_LIMIT_RETURED = 50


def main():
    parser = argparse.ArgumentParser(
        prog="Browser histoy fetcher",
        description="Fetches browser history over a given period of time",
    )

    parser.add_argument(
        "-l",
        "--limit",
        type=int,
        default=DEFAULT_ITEM_LIMIT_RETURED,
        metavar="N",
        help="Maximum number of visits to return (newest first)",
    )
    parser.add_argument(
        "-p",
        "--period-days",
        type=int,
        default=DEFAULT_LOOKBACK_DAYS,
        metavar="DAYS",
        help="Only include visits from the last D days",
    )

    args = parser.parse_args()

    default_browser = get_default_browser()
    print(f"Flagged a default browser called {default_browser} on the user's machine")

    history_database_path = resolve_browser_history_path(browser=default_browser)
    print(f"Found the history database sqlite file at {history_database_path}")

    with browser_history_connection(history_database_path) as db_conn:
        rows = fetch_recent_history(
            db_conn,
            history_database_path,
            lookback_days=args.period_days,
            limit=args.limit,
        )
      
        artifact_path = write_browser_history_csv(rows)
        print(f"Saved browser history CSV artifact: {artifact_path}")
        print(artifact_path)


if __name__ == "__main__":
    main()
