"""Path resolution, default browser detection, SQLite access, history queries, CSV artifacts."""

from __future__ import annotations

import configparser
import csv
import json
import shutil
import sqlite3
import subprocess
import tempfile
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterator

BROWSER_HISTORY_ARTIFACTS_DIR = Path("/tmp/browser_history_artifacts")
_BLACKLIST_JSON = Path(__file__).resolve().parent / "blacklisted_properties.json"


def _load_url_blacklist() -> tuple[list[str], list[str], list[str]]:
    if not _BLACKLIST_JSON.is_file():
        return [], [], []
    with _BLACKLIST_JSON.open(encoding="utf-8") as f:
        data = json.load(f)
    return (
        list(data.get("domains", [])),
        list(data.get("paths", [])),
        list(data.get("urlParameters", [])),
    )


def _sql_url_blacklist_and_params(url_sql_expr: str) -> tuple[str, list[str]]:
    domains, paths, params = _load_url_blacklist()
    url_lower = f"LOWER(COALESCE({url_sql_expr}, ''))"
    parts: list[str] = []
    bind: list[str] = []
    for d in domains:
        if not d:
            continue
        parts.append(f"INSTR({url_lower}, LOWER(?)) = 0")
        bind.append(d)
    for p in paths:
        if not p:
            continue
        parts.append(f"INSTR(COALESCE({url_sql_expr}, ''), ?) = 0")
        bind.append(p)
    for name in params:
        if not name:
            continue
        parts.append(f"INSTR({url_lower}, LOWER(?)) = 0")
        bind.append(name)
    if not parts:
        return "", []
    return " AND " + " AND ".join(parts), bind

# Chromium visit_time: microseconds since midnight UTC on 1601-01-01 (WebKit epoch)
_CHROME_EPOCH_UTC = datetime(1601, 1, 1, tzinfo=timezone.utc)
_UNIX_EPOCH_UTC = datetime(1970, 1, 1, tzinfo=timezone.utc)

# chromium history database path mapping (~/.config per XDG_CONFIG_HOME default)
_CHROME_FAMILY_HISTORY: dict[str, tuple[str, ...]] = {
    "brave": (".config", "BraveSoftware", "Brave-Browser", "Default", "History"),
    "brave-browser": (
        ".config",
        "BraveSoftware",
        "Brave-Browser",
        "Default",
        "History",
    ),
    "chromium": (".config", "chromium", "Default", "History"),
    "google-chrome": (".config", "google-chrome", "Default", "History"),
    "google-chrome-stable": (".config", "google-chrome", "Default", "History"),
    "microsoft-edge": (".config", "microsoft-edge", "Default", "History"),
    "opera": (".config", "opera", "Default", "History"),
    "vivaldi": (".config", "vivaldi", "Default", "History"),
    "vivaldi-stable": (".config", "vivaldi", "Default", "History"),
}


def _normalize_cmd_output(cmd_output: str) -> str:
    return cmd_output.replace("\n", "").strip()


def _normalize_browser_key(browser: str) -> str:
    s = browser.strip()
    if "/" in s:
        s = Path(s).name
    s = s.lower()
    if s.endswith(".desktop"):
        s = s.removesuffix(".desktop")
    return s


def _firefox_places_path(home: Path, variant: str) -> Path:
    base = (
        home / ".librewolf" if variant == "librewolf" else home / ".mozilla" / "firefox"
    )
    profiles_ini = base / "profiles.ini"
    if not profiles_ini.is_file():
        msg = f"Cannot resolve Firefox history: missing {profiles_ini}"
        raise FileNotFoundError(msg)

    cfg = configparser.ConfigParser()
    cfg.read(profiles_ini)
    for section in cfg.sections():
        if not section.lower().startswith("profile"):
            continue
        if cfg.get(section, "Default", fallback="0") != "1":
            continue
        rel_path = cfg.get(section, "Path", fallback="")
        if not rel_path:
            continue
        if cfg.get(section, "IsRelative", fallback="1") == "1":
            return base / rel_path / "places.sqlite"
        return Path(rel_path) / "places.sqlite"

    msg = f"No default profile marked in {profiles_ini}"
    raise FileNotFoundError(msg)


def resolve_browser_history_path(browser: str) -> Path:
    key = _normalize_browser_key(browser)
    home = Path.home()

    if key in _CHROME_FAMILY_HISTORY:
        return home.joinpath(*_CHROME_FAMILY_HISTORY[key])

    if key in ("firefox", "librewolf"):
        return _firefox_places_path(home, key)

    msg = (
        f"Unknown browser for history path resolution: {browser!r} (normalized {key!r})"
    )
    raise ValueError(msg)


@contextmanager
def browser_history_connection(history_path: Path) -> Iterator[sqlite3.Connection]:
    history_path = history_path.expanduser().resolve()
    if not history_path.is_file():
        msg = f"No history database at {history_path}"
        raise FileNotFoundError(msg)

    tmpdir = tempfile.mkdtemp(prefix="browser-history-")
    try:
        dest_dir = Path(tmpdir)
        name = history_path.name
        shutil.copy2(history_path, dest_dir / name)
        for ext in ("-wal", "-shm"):
            peer = history_path.parent / f"{name}{ext}"
            if peer.is_file():
                shutil.copy2(peer, dest_dir / f"{name}{ext}")

        conn = sqlite3.connect(dest_dir / name)
        try:
            yield conn
        finally:
            conn.close()
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def get_default_browser() -> str:
    k6_output = _normalize_cmd_output(
        subprocess.run(
            ["kreadconfig6", "--group", "General", "--key", "BrowserApplication"],
            capture_output=True,
            text=True,
        ).stdout
    )

    if k6_output:
        return k6_output

    xdg_output = _normalize_cmd_output(
        subprocess.run(
            ["xdg-settings", "get", "default-web-browser"],
            capture_output=True,
            text=True,
        ).stdout
    )

    return xdg_output


def write_browser_history_csv(
    rows: list[tuple[str, str, str]],
    *,
    filename_prefix: str = "browser_history",
) -> Path:
    BROWSER_HISTORY_ARTIFACTS_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    out_path = (
        BROWSER_HISTORY_ARTIFACTS_DIR / f"{filename_prefix}_{stamp}.csv"
    ).resolve()
    with out_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["visit_time", "url", "title"])
        writer.writerows(rows)
    return out_path


def _format_visit_local(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")


def _chrome_cutoff_visit_time(lookback_days: int) -> int:
    cutoff = datetime.now(timezone.utc) - timedelta(days=lookback_days)
    return int((cutoff - _CHROME_EPOCH_UTC).total_seconds() * 1_000_000)


def _chrome_visit_time_to_datetime(visit_time: int) -> datetime:
    return _CHROME_EPOCH_UTC + timedelta(microseconds=visit_time)


def _firefox_cutoff_visit_date(lookback_days: int) -> int:
    cutoff = datetime.now(timezone.utc) - timedelta(days=lookback_days)
    return int((cutoff - _UNIX_EPOCH_UTC).total_seconds() * 1_000_000)


def _firefox_visit_date_to_datetime(visit_date: int) -> datetime:
    return _UNIX_EPOCH_UTC + timedelta(microseconds=visit_date)


def fetch_recent_history(
    conn: sqlite3.Connection,
    history_path: Path,
    *,
    lookback_days: int,
    limit: int,
) -> list[tuple[str, str, str]]:
    name = history_path.name.lower()
    if name == "places.sqlite":
        cutoff = _firefox_cutoff_visit_date(lookback_days)
        bl_sql, bl_params = _sql_url_blacklist_and_params("p.url")
        sql = f"""
            SELECT p.url, p.title, v.visit_date
            FROM moz_historyvisits v
            INNER JOIN moz_places p ON p.id = v.place_id
            WHERE v.visit_date >= ?{bl_sql}
            ORDER BY v.visit_date DESC
            LIMIT ?
        """
        cur = conn.execute(sql, (cutoff, *bl_params, limit))
        rows: list[tuple[str, str, str]] = []
        for url, title, visit_date in cur:
            when = _format_visit_local(_firefox_visit_date_to_datetime(int(visit_date)))
            rows.append((when, url or "", title or ""))
        return rows

    cutoff = _chrome_cutoff_visit_time(lookback_days)
    bl_sql, bl_params = _sql_url_blacklist_and_params("u.url")
    sql = f"""
        SELECT u.url, u.title, v.visit_time
        FROM visits v
        INNER JOIN urls u ON u.id = v.url
        WHERE v.visit_time >= ?{bl_sql}
        ORDER BY v.visit_time DESC
        LIMIT ?
    """
    cur = conn.execute(sql, (cutoff, *bl_params, limit))
    out: list[tuple[str, str, str]] = []
    for url, title, visit_time in cur:
        when = _format_visit_local(_chrome_visit_time_to_datetime(int(visit_time)))
        out.append((when, url or "", title or ""))
    return out
