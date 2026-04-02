#!/usr/bin/env python3
"""Download agent-config directory trees over HTTP by parsing directory listings."""

from __future__ import annotations

import os
import sys
from html.parser import HTMLParser
from urllib.error import HTTPError
from urllib.parse import urljoin, urlparse
from urllib.request import Request, urlopen


def fetch(url: str) -> bytes:
    req = Request(url, headers={"User-Agent": "agent-config-installer"})
    with urlopen(req) as resp:
        return resp.read()


class LinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[str] = []

    def handle_starttag(self, tag, attrs) -> None:
        if tag.lower() != "a":
            return
        href = dict(attrs).get("href")
        if href:
            self.links.append(href)


def mirror_tree(
    base_url: str,
    out_dir: str,
    root_path: str,
    optional: bool = False,
    *,
    log_urls: bool = False,
) -> None:
    root_url = urljoin(base_url, root_path.rstrip("/") + "/")
    seen: set[str] = set()

    def fetch_logged(url: str) -> bytes:
        if log_urls:
            print(f"[agent-config] GET {url}", file=sys.stderr, flush=True)
        return fetch(url)

    def walk(url: str, rel_root: str) -> None:
        if url in seen:
            return
        seen.add(url)
        try:
            page = fetch_logged(url).decode("utf-8", errors="ignore")
        except HTTPError as exc:
            if optional and exc.code == 404:
                return
            raise

        parser = LinkParser()
        parser.feed(page)
        for href in parser.links:
            if href in ("../", "./") or href.startswith("?") or href.startswith("#"):
                continue
            child_url = urljoin(url, href)
            parsed = urlparse(child_url)
            if parsed.netloc != urlparse(base_url).netloc:
                continue
            child_rel = os.path.normpath(os.path.join(rel_root, href))
            if href.endswith("/"):
                walk(child_url, child_rel)
            else:
                if os.path.basename(child_rel).startswith("index.html"):
                    continue
                target_path = os.path.join(out_dir, child_rel)
                os.makedirs(os.path.dirname(target_path), exist_ok=True)
                with open(target_path, "wb") as f:
                    f.write(fetch_logged(child_url))

    walk(root_url, root_path.rstrip("/"))


def main() -> None:
    if len(sys.argv) != 3:
        print("Usage: remote_mirror_download.py <base_url> <out_dir>", file=sys.stderr)
        sys.exit(2)
    base_url = sys.argv[1]
    out_dir = sys.argv[2]
    mirror_tree(base_url, out_dir, "config/skills", log_urls=True)
    mirror_tree(base_url, out_dir, "packages")
    mirror_tree(base_url, out_dir, "config/agents", optional=True, log_urls=True)


if __name__ == "__main__":
    main()
