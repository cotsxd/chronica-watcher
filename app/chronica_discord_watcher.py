#!/usr/bin/env python3
"""Watch authenticated Chronica pages and post Discord webhook updates."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from http.cookiejar import CookieJar
from html.parser import HTMLParser
from pathlib import Path
from typing import Any


VERBOSE = False
CONTENT_FILTER_VERSION = 7
LOG_FILE: Path | None = None


def configure_console_encoding() -> None:
    for stream_name in ("stdout", "stderr"):
        stream = getattr(sys, stream_name, None)
        if stream is None or not hasattr(stream, "reconfigure"):
            continue
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (OSError, ValueError):
            pass


def write_log_file(message: str) -> None:
    if LOG_FILE is None:
        return
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        with LOG_FILE.open("a", encoding="utf-8") as file:
            file.write(f"[{timestamp}] {message}\n")
    except OSError:
        pass


def log(message: str, always: bool = False) -> None:
    if always or VERBOSE:
        print(message, flush=True)
        write_log_file(message)


DEFAULT_CONFIG = {
    "site_base_url": "https://chronica.ventures",
    "login_url": "https://chronica.ventures/login",
    "sitemap_url": "https://chronica.ventures/sitemap.xml",
    "watched_urls": [],
    "fallback_urls": [],
    "requires_login": True,
    "discover_links_from_watched_pages": False,
    "link_discovery_max_depth": 2,
    "link_discovery_max_pages": 1000,
    "allowed_url_patterns": [],
    "check_interval_seconds": 60,
    "state_file": ".chronica-watch-state.json",
    "known_pages_file": "known-pages.json",
    "lock_file": "watcher.lock",
    "log_file": "data/chronica-watcher.log",
    "cache_dir": "data/chronica-page-cache-fresh",
    "notification_pause_file": "data/notifications-paused.flag",
    "sent_messages_file": "data/sent-messages.json",
    "notify_on_first_seen": False,
    "discord_delay_seconds": 1,
    "discovery_interval_seconds": 300,
    "max_concurrent_checks": 12,
    "skip_hidden_or_secret_pages": True,
    "user_agent": "ChronicaDiscordWatcher/1.0 (+https://chronica.ventures)",
    "ignore_url_patterns": [
        "/login",
        "/new($|[/?#])",
        "/edit($|[/?#])",
        "/guide($|[/?#])",
        "/admin",
        "/settings",
    ],
    "ignore_urls": [],
}


class WatcherLock:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.acquired = False
        self.started_at = int(time.time())

    @staticmethod
    def process_is_running(pid: int) -> bool:
        if pid <= 0:
            return False
        if os.name == "nt":
            result = subprocess.run(
                ["tasklist", "/FI", f"PID eq {pid}", "/FO", "CSV", "/NH"],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            return f'"{pid}"' in result.stdout
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        return True

    def __enter__(self) -> "WatcherLock":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        now = int(time.time())
        if self.path.exists():
            try:
                data = json.loads(self.path.read_text(encoding="utf-8"))
                pid = int(data.get("pid", 0))
                age = now - int(data.get("started_at", now))
            except (json.JSONDecodeError, OSError, ValueError):
                pid = 0
                age = 0
            if pid and self.process_is_running(pid):
                raise RuntimeError(
                    f"Watcher already appears to be running as process {pid}. "
                    "Use Stop first if you started it from the GUI."
                )
            log(f"Removed stale watcher lock: {self.path}", always=True)
            try:
                self.path.unlink()
            except OSError:
                if age < 24 * 60 * 60:
                    raise RuntimeError(
                        f"Could not remove stale watcher lock: {self.path}. "
                        "Close any open editor/viewer using that file and try again."
                    )

        self.path.write_text(
            json.dumps({"pid": os.getpid(), "started_at": now, "heartbeat_at": now}, indent=2) + "\n",
            encoding="utf-8",
        )
        self.started_at = now
        self.acquired = True
        return self

    def heartbeat(self, status: str = "running") -> None:
        if not self.acquired:
            return
        now = int(time.time())
        try:
            self.path.write_text(
                json.dumps(
                    {
                        "pid": os.getpid(),
                        "started_at": self.started_at,
                        "heartbeat_at": now,
                        "status": status,
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
        except OSError:
            pass

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        if self.acquired:
            try:
                self.path.unlink()
            except OSError:
                pass


class VisibleTextParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self._skip_depth = 0
        self.parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() in {"script", "style", "noscript", "svg"}:
            self._skip_depth += 1

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() in {"script", "style", "noscript", "svg"} and self._skip_depth:
            self._skip_depth -= 1

    def handle_data(self, data: str) -> None:
        if not self._skip_depth:
            cleaned = " ".join(data.split())
            if cleaned:
                self.parts.append(cleaned)

    @property
    def text(self) -> str:
        return "\n".join(self.parts)


class LinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "a":
            return
        attr_map = dict(attrs)
        href = attr_map.get("href")
        if href:
            self.links.append(href)


class HeadingParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self._skip_depth = 0
        self._current_heading: str | None = None
        self._parts: list[str] = []
        self.headings: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        if tag in {"script", "style", "noscript", "svg"}:
            self._skip_depth += 1
        elif tag in {"h1", "h2", "h3"} and not self._skip_depth:
            self._current_heading = tag
            self._parts = []

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if tag in {"script", "style", "noscript", "svg"} and self._skip_depth:
            self._skip_depth -= 1
        elif self._current_heading == tag:
            heading = " ".join(" ".join(self._parts).split())
            if heading:
                self.headings.append(heading)
            self._current_heading = None
            self._parts = []

    def handle_data(self, data: str) -> None:
        if self._current_heading and not self._skip_depth:
            cleaned = " ".join(data.split())
            if cleaned:
                self._parts.append(cleaned)


class LoginFormParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.forms: list[dict[str, Any]] = []
        self._current: dict[str, Any] | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attr_map = {name.lower(): value or "" for name, value in attrs}
        if tag.lower() == "form":
            self._current = {
                "action": attr_map.get("action", ""),
                "method": attr_map.get("method", "get").lower(),
                "inputs": [],
            }
            self.forms.append(self._current)
            return

        if tag.lower() == "input" and self._current is not None:
            self._current["inputs"].append(attr_map)

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "form":
            self._current = None


class ChronicaSession:
    def __init__(self, user_agent: str) -> None:
        self.user_agent = user_agent
        self.cookie_jar = CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.cookie_jar))

    def fetch_text(self, url: str) -> str:
        request = urllib.request.Request(url, headers={"User-Agent": self.user_agent})
        with self.opener.open(request, timeout=30) as response:
            charset = response.headers.get_content_charset() or "utf-8"
            return response.read().decode(charset, errors="replace")

    def post_form(self, url: str, fields: dict[str, str]) -> tuple[str, str]:
        body = urllib.parse.urlencode(fields).encode("utf-8")
        request = urllib.request.Request(
            url,
            data=body,
            headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": self.user_agent,
            },
            method="POST",
        )
        with self.opener.open(request, timeout=30) as response:
            charset = response.headers.get_content_charset() or "utf-8"
            return response.read().decode(charset, errors="replace"), response.geturl()


def load_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        return DEFAULT_CONFIG.copy()

    with path.open("r", encoding="utf-8-sig") as file:
        loaded = json.load(file)

    config = DEFAULT_CONFIG.copy()
    config.update(loaded)
    validate_config(config)
    return config


def validate_config(config: dict[str, Any]) -> None:
    if not config.get("watched_urls") and not config.get("fallback_urls"):
        raise RuntimeError("config.json needs at least one watched URL.")
    if int(config.get("check_interval_seconds", 0)) < 30:
        raise RuntimeError("check_interval_seconds should be 30 or higher to avoid hammering Chronica.")
    if int(config.get("max_concurrent_checks", 1)) < 1:
        raise RuntimeError("max_concurrent_checks must be at least 1.")
    if int(config.get("max_concurrent_checks", 1)) > 30:
        raise RuntimeError("max_concurrent_checks should not be above 30; Chronica may rate-limit or fail.")


def load_env_file(path: Path) -> None:
    if not path.exists():
        return

    with path.open("r", encoding="utf-8") as file:
        for line in file:
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue

            key, value = stripped.split("=", 1)
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = value


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"pages": {}}

    with path.open("r", encoding="utf-8") as file:
        return json.load(file)


def save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    with tmp_path.open("w", encoding="utf-8") as file:
        json.dump(state, file, indent=2, sort_keys=True)
        file.write("\n")
    replace_with_retry(tmp_path, path)


def replace_with_retry(tmp_path: Path, path: Path, attempts: int = 5) -> None:
    for attempt in range(attempts):
        try:
            tmp_path.replace(path)
            return
        except PermissionError:
            if attempt == attempts - 1:
                fallback_write(tmp_path, path)
                return
            time.sleep(0.25)


def fallback_write(tmp_path: Path, path: Path) -> None:
    content = tmp_path.read_text(encoding="utf-8")
    with path.open("w", encoding="utf-8") as file:
        file.write(content)
    try:
        tmp_path.unlink()
    except OSError:
        pass


def load_known_pages(path: Path, state: dict[str, Any]) -> dict[str, Any]:
    if path.exists():
        with path.open("r", encoding="utf-8") as file:
            loaded = json.load(file)
        if isinstance(loaded, dict) and isinstance(loaded.get("pages"), dict):
            return loaded

    pages = {}
    for url, page in state.get("pages", {}).items():
        pages[url] = {
            "title": page.get("title", "Chronica page") if isinstance(page, dict) else "Chronica page",
            "first_seen": page.get("last_checked", int(time.time())) if isinstance(page, dict) else int(time.time()),
        }
    return {"pages": pages}


def save_known_pages(path: Path, known_pages: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    with tmp_path.open("w", encoding="utf-8") as file:
        json.dump(known_pages, file, indent=2, sort_keys=True)
        file.write("\n")
    replace_with_retry(tmp_path, path)


def load_json_file(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    with path.open("r", encoding="utf-8-sig") as file:
        return json.load(file)


def save_json_file(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    with tmp_path.open("w", encoding="utf-8") as file:
        json.dump(data, file, indent=2, sort_keys=True)
        file.write("\n")
    replace_with_retry(tmp_path, path)


def choose_login_form(html: str) -> dict[str, Any]:
    parser = LoginFormParser()
    parser.feed(html)
    for form in parser.forms:
        if any(input_tag.get("type", "").lower() == "password" for input_tag in form["inputs"]):
            return form
    raise RuntimeError("Could not find a password login form on the Chronica login page.")


def input_name_contains(input_tag: dict[str, str], *needles: str) -> bool:
    haystack = " ".join(
        input_tag.get(key, "").lower() for key in ("name", "id", "placeholder", "autocomplete")
    )
    return any(needle in haystack for needle in needles)


def build_login_fields(form: dict[str, Any], email: str, password: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    email_field = ""
    password_field = ""

    for input_tag in form["inputs"]:
        name = input_tag.get("name", "")
        if not name:
            continue

        input_type = input_tag.get("type", "text").lower()
        if input_type in {"submit", "button", "file", "image"}:
            continue

        fields[name] = input_tag.get("value", "")
        if input_type == "password" or input_name_contains(input_tag, "password"):
            password_field = name
        elif input_type == "email" or input_name_contains(input_tag, "email", "username", "login"):
            email_field = name

    if not email_field:
        text_fields = [
            input_tag.get("name", "")
            for input_tag in form["inputs"]
            if input_tag.get("name") and input_tag.get("type", "text").lower() in {"text", "email"}
        ]
        if text_fields:
            email_field = text_fields[0]

    if not email_field or not password_field:
        raise RuntimeError("Could not identify the email and password fields on the Chronica login form.")

    fields[email_field] = email
    fields[password_field] = password
    return fields


def login(session: ChronicaSession, config: dict[str, Any]) -> None:
    email = os.environ.get("CHRONICA_EMAIL", "").strip()
    password = os.environ.get("CHRONICA_PASSWORD", "").strip()
    if not email or not password:
        raise RuntimeError("Set CHRONICA_EMAIL and CHRONICA_PASSWORD before running authenticated checks.")
    if email == "bot-account@example.com" or password == "your-bot-account-password":
        raise RuntimeError("Replace the placeholder CHRONICA_EMAIL and CHRONICA_PASSWORD values in .env.")

    login_url = normalize_url(config["login_url"], config["site_base_url"])
    log(f"Opening Chronica login page: {login_url}")
    login_html = session.fetch_text(login_url)
    form = choose_login_form(login_html)
    action = urllib.parse.urljoin(login_url, form.get("action") or login_url)
    fields = build_login_fields(form, email, password)
    log("Submitting Chronica login form...")
    response_html, final_url = session.post_form(action, fields)

    if looks_like_login_page(response_html):
        form_field_names = ", ".join(sorted(fields.keys()))
        raise RuntimeError(
            "Chronica login did not appear to succeed. "
            f"Final URL after login attempt: {final_url}. "
            f"Submitted form fields: {form_field_names}. "
            "Check that the bot account can log into Chronica in a browser, and that no email verification, "
            "captcha, or two-factor step is required."
        )
    log(f"Chronica login succeeded. Landed on: {final_url}")


def looks_like_login_page(html: str) -> bool:
    lower_html = html.lower()
    return "password" in lower_html and "please log in" in lower_html


def normalize_url(url: str, base_url: str) -> str:
    absolute = urllib.parse.urljoin(base_url, url)
    parsed = urllib.parse.urlsplit(absolute)
    clean_path = parsed.path or "/"
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, clean_path, parsed.query, ""))


def is_allowed_watch_url(url: str, config: dict[str, Any]) -> bool:
    base_url = config["site_base_url"]
    normalized_url = normalize_url(url, base_url)
    if urllib.parse.urlsplit(url).netloc != urllib.parse.urlsplit(base_url).netloc:
        return False

    ignored_urls = {
        normalize_url(ignored, base_url).rstrip("/")
        for ignored in config.get("ignore_urls", [])
        if isinstance(ignored, str) and ignored.strip()
    }
    if normalized_url.rstrip("/") in ignored_urls:
        return False

    allowed_patterns = [re.compile(pattern) for pattern in config.get("allowed_url_patterns", [])]
    if allowed_patterns and not any(pattern.search(url) for pattern in allowed_patterns):
        return False

    ignore_patterns = [re.compile(pattern) for pattern in config.get("ignore_url_patterns", [])]
    return not any(pattern.search(url) for pattern in ignore_patterns)


def is_detail_watch_url(url: str) -> bool:
    parsed = urllib.parse.urlsplit(url)
    if parsed.query:
        return False
    return bool(re.search(r"/campaigns/\d+/(characters|kinships|places|developments)/\d+/?$", parsed.path))


def page_kind(url: str) -> str:
    path = urllib.parse.urlsplit(url).path
    match = re.search(r"/campaigns/\d+/(characters|kinships|places|developments)/\d+/?$", path)
    if not match:
        return "page"
    return {
        "characters": "character",
        "kinships": "kinship",
        "places": "place",
        "developments": "development",
    }[match.group(1)]


def new_page_message(title: str, url: str) -> str:
    kind = page_kind(url)
    return f"A new Chronica {kind} has been created: {title}\n{url}"


def updated_page_message(title: str, url: str) -> str:
    kind = page_kind(url)
    return f"The Chronica {kind} {title} has been updated.\n{url}"


def notification_title(title: str, url: str, text: str = "") -> str:
    if is_specific_title(title):
        return title
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    fallback = detail_title_from_lines(lines, url)
    if fallback and is_specific_title(fallback):
        return fallback
    return f"{page_kind(url).title()} page"


def preview_message_for_page(title: str, url: str, is_new: bool = False) -> str:
    title = notification_title(title, url)
    if is_new:
        return new_page_message(title, url)
    return updated_page_message(title, url)


def discover_urls(config: dict[str, Any], session: ChronicaSession) -> list[str]:
    urls: set[str] = set()
    base_url = config["site_base_url"]

    for url in config.get("watched_urls", []):
        urls.add(normalize_url(url, base_url))

    for url in config.get("fallback_urls", []):
        urls.add(normalize_url(url, base_url))

    if not urls:
        try:
            sitemap_xml = session.fetch_text(config["sitemap_url"])
            root = ET.fromstring(sitemap_xml)
            for node in root.iter():
                if node.tag.endswith("loc") and node.text:
                    urls.add(normalize_url(node.text.strip(), base_url))
        except (ET.ParseError, urllib.error.URLError, TimeoutError) as exc:
            print(f"Could not read sitemap: {exc}", file=sys.stderr)

    if config.get("discover_links_from_watched_pages"):
        log(f"Discovering linked campaign pages from {len(urls)} starting page(s)...")
        urls.update(discover_page_links(config, session, sorted(urls)))

    final_urls = sorted(url for url in urls if is_allowed_watch_url(url, config) and is_detail_watch_url(url))
    log(f"Discovery complete. Found {len(final_urls)} watchable page(s).")
    return final_urls


def discover_page_links(config: dict[str, Any], session: ChronicaSession, start_urls: list[str]) -> set[str]:
    base_url = config["site_base_url"]
    discovered: set[str] = set()
    seen: set[str] = set(start_urls)
    queue: list[tuple[str, int]] = [(url, 0) for url in start_urls]
    max_depth = int(config.get("link_discovery_max_depth", 2))
    max_pages = int(config.get("link_discovery_max_pages", 250))

    while queue and len(seen) <= max_pages:
        url, depth = queue.pop(0)
        log(f"Scanning links depth {depth}: {url}")
        try:
            html = session.fetch_text(url)
        except (urllib.error.URLError, TimeoutError) as exc:
            print(f"Could not discover links from {url}: {exc}", file=sys.stderr)
            continue

        parser = LinkParser()
        parser.feed(html)
        added_from_page = 0
        for href in parser.links:
            normalized = normalize_url(href, base_url)
            if normalized in seen or not is_allowed_watch_url(normalized, config):
                continue
            if len(seen) >= max_pages:
                break

            seen.add(normalized)
            discovered.add(normalized)
            added_from_page += 1
            if depth < max_depth:
                queue.append((normalized, depth + 1))
        if added_from_page:
            log(f"Found {added_from_page} new link(s). Total discovered so far: {len(seen)}")

    return discovered


GENERIC_TITLES = {
    "chronica tabletop manager",
    "chronica tabletop manager",
    "chronica - rpg tabletop campaign manager & tracking",
    "chronica - tabletop rpg campaign manager and builder | join free",
    "swords and sails",
    "developments",
    "developments view development",
    "view development",
    "characters",
    "kinships",
    "places",
    "npc codex",
    "player codex",
    "character profile",
    "npc codex character profile",
    "player codex character profile",
    "nations",
    "information",
    "the carribean",
}


def clean_title(title: str) -> str:
    title = re.sub(r"\s+", " ", title).strip()
    title = re.sub(r"\s*\|\s*Chronica.*$", "", title, flags=re.IGNORECASE)
    title = re.sub(r"\s*-\s*Chronica.*$", "", title, flags=re.IGNORECASE)
    return title.strip()


def is_specific_title(title: str) -> bool:
    cleaned = clean_title(title)
    if not cleaned:
        return False
    if cleaned.lower() in GENERIC_TITLES:
        return False
    if looks_like_date_or_metadata(cleaned):
        return False
    if len(cleaned) > 120:
        return False
    return True


def looks_like_date_or_metadata(text: str) -> bool:
    months = (
        "january",
        "february",
        "march",
        "april",
        "may",
        "june",
        "july",
        "august",
        "september",
        "october",
        "november",
        "december",
    )
    cleaned = text.strip().lower()
    if cleaned in {"plot", "event", "quest", "lore", "rumor", "rumour", "session"}:
        return True
    if re.match(r"^\d{3,4}$", cleaned):
        return True
    if any(cleaned.startswith(month) for month in months):
        return True
    return False


def best_heading_title(html: str) -> str | None:
    parser = HeadingParser()
    parser.feed(html)
    for heading in parser.headings:
        cleaned = clean_title(heading)
        if is_specific_title(cleaned):
            return cleaned
    return None


def title_from_visible_text(text: str, url: str) -> str | None:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    detail_title = detail_title_from_lines(lines, url)
    if detail_title:
        return detail_title

    markers = []
    if "/developments/" in url:
        markers = ["Back to Campaign Calendar", "Back to Developments", "View Development"]
    elif "/characters/" in url:
        markers = ["Back to NPC Codex", "Back to Player Codex", "View Character"]
    elif "/kinships/" in url:
        markers = ["Back to Kinships", "View Kinship"]
    elif "/places/" in url:
        markers = ["Back to Places", "View Place"]

    ignored = {
        "Direct Link:",
        "Direct Link to Development",
        "Calendar Date:",
        "Out of Game Date:",
        "Category:",
        "Involving:",
        "Place(s):",
        "Quest(s):",
        "Content",
        "Author:",
        "Created:",
        "Updated:",
    }

    for marker in markers:
        if marker not in lines:
            continue
        index = lines.index(marker)
        for candidate in lines[index + 1 : index + 10]:
            if candidate in ignored:
                continue
            if is_specific_title(candidate):
                return clean_title(candidate)
    return None


def detail_title_from_lines(lines: list[str], url: str) -> str | None:
    if "/developments/" in url:
        return (
            development_title_from_header(lines)
            or development_title_from_content(lines)
            or title_after_markers(lines, ["Back to Campaign Calendar", "Back to Developments", "View Development"])
        )
    if "/characters/" in url:
        return (
            title_before_label(lines, "Status:")
            or adjacent_duplicate_title(lines)
            or character_title_from_description(lines)
        )
    if "/kinships/" in url:
        return adjacent_duplicate_title(lines) or title_before_label(lines, "Information")
    if "/places/" in url:
        return adjacent_duplicate_title(lines) or title_before_label(lines, "Links") or title_before_label(lines, "Description")
    return None


def title_after_markers(lines: list[str], markers: list[str]) -> str | None:
    ignored = {
        "Back to Campaign Calendar",
        "Back to Developments",
        "View Development",
        "Direct Link:",
        "Direct Link to Development",
    }
    for marker in markers:
        if marker not in lines:
            continue
        index = lines.index(marker)
        for candidate in lines[index + 1 : index + 8]:
            if candidate in ignored:
                continue
            if is_specific_title(candidate):
                return clean_title(candidate)
    return None


def development_title_from_header(lines: list[str]) -> str | None:
    start_index = 0
    for marker in ["View Development", "Back to Developments", "Back to Campaign Calendar"]:
        if marker in lines:
            start_index = lines.index(marker) + 1
            break

    stop_markers = {
        "Direct Link:",
        "Direct Link to Development",
        "Calendar Date:",
        "Out of Game Date:",
        "Category:",
        "Involving:",
        "Place(s):",
        "Quest(s):",
        "Content",
        "Author:",
        "Created:",
        "Updated:",
    }
    ignored = {
        "Developments",
        "View Development",
        "Back to Developments",
        "Back to Campaign Calendar",
        "Direct Link:",
        "Direct Link to Development",
    }

    for line in lines[start_index : start_index + 20]:
        candidate = clean_title(line.strip(" ,;:-"))
        if not candidate or candidate in ignored:
            continue
        if candidate in stop_markers:
            break
        if candidate.startswith("Direct Link"):
            break
        if is_specific_title(candidate):
            return candidate
    return None


def development_title_from_content(lines: list[str]) -> str | None:
    if "Content" not in lines:
        return None
    index = lines.index("Content")
    content_lines = [line.strip() for line in lines[index + 1 : index + 8] if line.strip()]
    if not content_lines:
        return None

    first = clean_title(content_lines[0].strip(" ,.;:-"))
    patterns = [
        r"^(The\s+[A-Z][A-Za-z0-9'’&.,: -]{3,80}?)\s+(?:marked|marks|was|were|is|became|began|ended|started|sent|shattered)\b",
        r"^([A-Z][A-Za-z0-9'’&.,: -]{3,80}?)\s+(?:marked|marks|was|were|is|became|began|ended|started|sent|shattered)\b",
    ]
    for pattern in patterns:
        match = re.match(pattern, first)
        if match:
            candidate = clean_title(match.group(1).strip(" ,.;:-"))
            if is_specific_title(candidate):
                return candidate

    if len(first) <= 70 and is_specific_title(first):
        return first
    return None


def adjacent_duplicate_title(lines: list[str]) -> str | None:
    for first, second in zip(lines, lines[1:]):
        if first == second and is_specific_title(first):
            return clean_title(first)
    return None


def title_before_label(lines: list[str], label: str) -> str | None:
    if label not in lines:
        return None
    ignored = {
        "Back to NPC Codex",
        "Back to Player Codex",
        "Back to Kinships",
        "Back to Places",
        "Character Profile",
        "NPC Codex",
        "Player Codex",
        "Kinships",
        "Places",
        "Nations",
    }
    index = lines.index(label)
    for candidate in reversed(lines[max(0, index - 8) : index]):
        if candidate in ignored:
            continue
        if is_specific_title(candidate):
            return clean_title(candidate)
    return None


def character_title_from_description(lines: list[str]) -> str | None:
    if "Description" not in lines:
        return None
    index = lines.index("Description")
    for line in lines[index + 1 : index + 8]:
        candidate = name_from_intro_sentence(line)
        if candidate:
            return candidate
    return None


def name_from_intro_sentence(line: str) -> str | None:
    clean = re.sub(r"\s+", " ", line).strip()
    if not clean:
        return None

    match = re.match(
        r"^([A-Z][A-Za-z'’.-]*(?:\s+(?:[A-Z][A-Za-z'’.-]*|of|the|de|del|van|von|da|la)){0,5})\s+"
        r"(?:is|was|were|has|had|stands|appears|serves|remains|became|becomes)\b",
        clean,
    )
    if not match:
        return None

    candidate = clean_title(match.group(1).strip(" ,.;:-"))
    blocked = {
        "The",
        "A",
        "An",
        "This",
        "Once",
        "With",
        "Though",
        "Current Status",
    }
    if candidate in blocked or not is_specific_title(candidate):
        return None
    return candidate


def extract_relevant_text(text: str, url: str, title: str) -> str:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines:
        return text

    focused = extract_focused_detail_text(lines, url, title)
    if focused:
        return focused

    start_markers: list[str] = []
    if "/developments/" in url:
        start_markers = ["View Development", "Back to Campaign Calendar", "Back to Developments"]
    elif "/characters/" in url:
        start_markers = ["Character Profile", "Back to NPC Codex", "Back to Player Codex"]
    elif "/kinships/" in url:
        start_markers = ["Back to Kinships", "Kinships"]
    elif "/places/" in url:
        start_markers = ["Back to Places", "Places"]
    elif url.rstrip("/").endswith("/developments"):
        start_markers = ["Developments Timeline", "Table", "Timeline"]
    elif url.rstrip("/").endswith("/characters"):
        start_markers = ["NPC Codex", "Player Codex"]
    elif url.rstrip("/").endswith("/kinships"):
        start_markers = ["Kinships"]
    elif url.rstrip("/").endswith("/places"):
        start_markers = ["Places"]

    hard_end_markers = {
        "Dice Roller",
        "Reset All",
        "Close Dice Roller",
    }
    modal_start_markers = {
        "New Connection",
        "New Place Connection",
        "View Connection",
        "Edit Link",
        "New Link",
    }
    modal_end_markers = {
        "Bug Report Form",
        "ERRViewConnectionModal",
        "ERRCampaignEditTargetLinkModal",
        "ERRCampaignNewTargetLinkModal",
        "ERRCampaignEditTargetLinkModal",
    }

    start_index = 0
    for marker in start_markers:
        if marker in lines:
            start_index = lines.index(marker)
            break

    relevant = lines[start_index:]
    filtered: list[str] = []
    skipping_modal = False
    for line in relevant:
        if line in hard_end_markers:
            break
        if skipping_modal:
            if line in modal_end_markers:
                skipping_modal = False
            continue
        if line in modal_start_markers:
            skipping_modal = True
            continue
        filtered.append(line)

    cleaned = remove_repeated_chrome_lines(filtered, title)
    return "\n".join(cleaned).strip() or "\n".join(filtered).strip() or text


def extract_focused_detail_text(lines: list[str], url: str, title: str) -> str | None:
    if "/characters/" in url:
        return focused_character_text(lines, title)
    if "/kinships/" in url:
        return focused_kinship_text(lines, title)
    if "/places/" in url:
        return focused_place_text(lines, title)
    if "/developments/" in url:
        return focused_development_text(lines, title)
    return None


def focused_character_text(lines: list[str], title: str) -> str:
    output = [title]
    for label in ["Status:", "Title:", "Gender:", "Race:", "Class:", "Alignment:", "Faction:"]:
        value = value_after_label(lines, label)
        if value:
            output.append(label)
            output.append(value)

    flair = section_between(lines, "Flair", {"Base Stats", "NPC Specific Stats", "Kinship Ranks", "Connections", "Links", "Developments", "Description"})
    if flair:
        output.append("Flair")
        output.extend(flair)

    description = section_between(lines, "Description", {"New Connection", "View Connection", "Dice Roller", "Bug Report Form"})
    if description:
        output.append("Description")
        output.extend(description)
    return "\n".join(dedupe_adjacent(output))


def focused_kinship_text(lines: list[str], title: str) -> str:
    output = [title]
    info_index = lines.index("Information") if "Information" in lines else -1
    if info_index >= 2:
        for candidate in lines[max(0, info_index - 4) : info_index]:
            if candidate != title and is_specific_title(candidate):
                output.append(candidate)

    description = section_between(lines, "Description", {"Ranks", "Kinship Ranks", "Character Connections", "New Connection", "View Connection", "Dice Roller", "Bug Report Form"})
    if description:
        output.append("Description")
        output.extend(description)
    return "\n".join(dedupe_adjacent(output))


def focused_place_text(lines: list[str], title: str) -> str:
    output = [title]
    links_index = lines.index("Links") if "Links" in lines else -1
    if links_index >= 2:
        for candidate in lines[max(0, links_index - 4) : links_index]:
            if candidate != title and is_specific_title(candidate):
                output.append(candidate)

    description = section_between(lines, "Description", {"New Connection", "New Place Connection", "View Connection", "Dice Roller", "Bug Report Form"})
    if description:
        output.append("Description")
        output.extend(description)
    return "\n".join(dedupe_adjacent(output))


def focused_development_text(lines: list[str], title: str) -> str:
    output = [title]
    for label in ["Calendar Date:", "Out of Game Date:", "Category:", "Involving:", "Place(s):", "Quest(s):"]:
        values = values_after_label_until_next_label(lines, label)
        if values:
            output.append(label)
            output.extend(values)

    content = section_between(lines, "Content", {"Author:", "Created:", "Updated:", "Dice Roller", "Bug Report Form"})
    if content:
        output.append("Content")
        output.extend(content)
    return "\n".join(dedupe_adjacent(output))


def value_after_label(lines: list[str], label: str) -> str | None:
    if label not in lines:
        return None
    index = lines.index(label)
    if index + 1 < len(lines):
        value = lines[index + 1]
        return value if is_specific_title(value) or value else None
    return None


def values_after_label_until_next_label(lines: list[str], label: str) -> list[str]:
    labels = {"Calendar Date:", "Out of Game Date:", "Category:", "Involving:", "Place(s):", "Quest(s):", "Content", "Author:", "Created:", "Updated:"}
    if label not in lines:
        return []
    index = lines.index(label)
    values: list[str] = []
    for line in lines[index + 1 :]:
        if line in labels:
            break
        if line == "Direct Link:" or line == "Direct Link to Development":
            continue
        values.append(line)
    return values


def section_between(lines: list[str], start: str, stops: set[str]) -> list[str]:
    if start not in lines:
        return []
    index = lines.index(start)
    values: list[str] = []
    for line in lines[index + 1 :]:
        if line in stops:
            break
        values.append(line)
    return values


def dedupe_adjacent(lines: list[str]) -> list[str]:
    output: list[str] = []
    for line in lines:
        if not line:
            continue
        if output and output[-1] == line:
            continue
        output.append(line)
    return output


def remove_repeated_chrome_lines(lines: list[str], title: str) -> list[str]:
    chrome = {
        "Dice",
        "Help",
        "Guidebook",
        "Help / FAQ",
        "Feature Request",
        "Bug Report",
        "Contact Us",
        "User Dashboard",
        "Account Settings",
        "Invites & Referrals",
        "Log Out",
        "Campaign Overview",
        "Party Info",
        "Player Dashboard",
        "Player Inventories",
        "Adventure Notes",
        "Session Tools",
        "Quest Log",
        "NPC Codex",
        "Player Codex",
        "Kinships",
        "World & Region Maps",
        "Places",
        "Campaign Shops",
        "Domains & Regions",
        "Item Library",
        "Campaign Tools",
        "Campaign Calendar",
        "Developments",
        "Developments View Development",
        "View Development",
        "Events & Attendance",
        "MENU",
        "Bug Report Form",
    }
    cleaned = [line for line in lines if line not in chrome]
    if cleaned and title and cleaned[0] != title:
        return [title, *cleaned]
    return cleaned


def html_title(html: str) -> str | None:
    title_match = re.search(r"<title[^>]*>(.*?)</title>", html, flags=re.IGNORECASE | re.DOTALL)
    if not title_match:
        return None
    title = clean_title(title_match.group(1))
    return title if is_specific_title(title) else None


def visible_text_hash(html: str, url: str = "") -> tuple[str, str, str]:
    parser = VisibleTextParser()
    parser.feed(html)
    raw_text = parser.text
    title = (
        title_from_visible_text(raw_text, url)
        or best_heading_title(html)
        or html_title(html)
        or "Chronica page"
    )
    text = extract_relevant_text(raw_text, url, title)
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    return digest, title, text


def page_looks_hidden_or_secret(html: str, text: str) -> bool:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if setting_value_near(lines, "Private?", {"Private", "Yes", "True"}):
        return True
    if setting_value_near(lines, "Hidden?", {"Hidden", "Yes", "True"}):
        return True
    if setting_value_near(lines, "Secret?", {"Secret", "Yes", "True"}):
        return True
    if setting_value_near(lines, "Visible to Party (Public)?", {"No", "False", "Private"}):
        return True

    lower_html = html.lower()
    sensitive_checked_patterns = [
        r'name=["\'](?:private|hidden|secret|gm_only|gm-only)["\'][^>]{0,200}\bchecked\b',
        r'\bchecked\b[^>]{0,200}name=["\'](?:private|hidden|secret|gm_only|gm-only)["\']',
        r'name=["\'](?:visible_to_party|public|published)["\'][^>]{0,200}value=["\'](?:0|false|no)["\']',
    ]
    return any(re.search(pattern, lower_html, flags=re.IGNORECASE | re.DOTALL) for pattern in sensitive_checked_patterns)


def page_has_gm_access_markers(html: str, text: str) -> bool:
    lower = f"{html}\n{text}".lower()
    markers = [
        "gm notes",
        "game master",
        "private notes",
        "secret notes",
        "hidden from players",
        "visible to party",
        "campaign tools",
        "account settings",
        "edit character",
        "edit development",
        "edit place",
        "delete character",
        "delete development",
        "delete place",
    ]
    return any(marker in lower for marker in markers)


def setting_value_near(lines: list[str], label: str, private_values: set[str]) -> bool:
    if label not in lines:
        return False
    index = lines.index(label)
    nearby = lines[index + 1 : index + 4]
    return any(value in private_values for value in nearby)


def cache_filename_for_url(url: str) -> str:
    parsed = urllib.parse.urlsplit(url)
    path = parsed.path.strip("/").replace("/", "__") or "home"
    if parsed.query:
        query_hash = hashlib.sha1(parsed.query.encode("utf-8")).hexdigest()[:12]
        path = f"{path}__query-{query_hash}"
    safe_path = re.sub(r"[^A-Za-z0-9._-]+", "_", path)
    url_hash = hashlib.sha1(url.encode("utf-8")).hexdigest()[:12]
    return f"{safe_path}__{url_hash}.txt"


def save_page_cache(cache_dir: Path, url: str, title: str, text: str) -> str:
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_path = cache_dir / cache_filename_for_url(url)
    with cache_path.open("w", encoding="utf-8") as file:
        file.write(f"URL: {url}\n")
        file.write(f"Title: {title}\n")
        file.write(f"Cached: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        file.write("\n")
        file.write(text)
        file.write("\n")
    return str(cache_path)


def post_discord(webhook_url: str, message: str) -> bool:
    if post_discord_with_python(webhook_url, message):
        return True
    print("Trying Discord webhook again with PowerShell transport...", file=sys.stderr, flush=True)
    return post_discord_with_powershell(webhook_url, message)


def record_sent_message(config: dict[str, Any], message: str, url: str, title: str) -> None:
    path = Path(config.get("sent_messages_file", "data/sent-messages.json"))
    try:
        loaded = load_json_file(path, [])
    except (json.JSONDecodeError, OSError):
        loaded = []
    if not isinstance(loaded, list):
        loaded = []
    loaded.append(
        {
            "sent_at": int(time.time()),
            "title": title,
            "url": url,
            "message": message,
        }
    )
    save_json_file(path, loaded[-20:])


def list_sent_messages(config: dict[str, Any]) -> int:
    path = Path(config.get("sent_messages_file", "data/sent-messages.json"))
    try:
        messages = load_json_file(path, [])
    except (json.JSONDecodeError, OSError):
        messages = []
    if not isinstance(messages, list) or not messages:
        print("No Discord notifications have been recorded yet.", flush=True)
        return 0
    for item in messages[-20:]:
        sent_at = item.get("sent_at", 0) if isinstance(item, dict) else 0
        stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(sent_at)) if sent_at else "unknown time"
        title = item.get("title", "Chronica page") if isinstance(item, dict) else "Chronica page"
        url = item.get("url", "") if isinstance(item, dict) else ""
        print(f"[{stamp}] {title}\n{url}\n", flush=True)
    return len(messages[-20:])


def post_discord_with_python(webhook_url: str, message: str) -> bool:
    payload = json.dumps({"content": message}).encode("utf-8")
    request = urllib.request.Request(
        webhook_url,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 ChronicaDiscordWatcher/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status >= 300:
                print(f"Discord returned HTTP {response.status}; message was not sent.", file=sys.stderr, flush=True)
                return False
            return True
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        print(f"Discord returned HTTP {exc.code}; message was not sent. Response: {body}", file=sys.stderr, flush=True)
        return False
    except (urllib.error.URLError, TimeoutError) as exc:
        print(f"Discord message failed: {exc}", file=sys.stderr, flush=True)
        return False


def post_discord_with_powershell(webhook_url: str, message: str) -> bool:
    script = """
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$body = @{ content = $env:CHRONICA_DISCORD_MESSAGE } | ConvertTo-Json -Compress
Invoke-RestMethod -Uri $env:CHRONICA_DISCORD_WEBHOOK_URL -Method Post -ContentType 'application/json' -Body $body | Out-Null
"""
    env = os.environ.copy()
    env["CHRONICA_DISCORD_WEBHOOK_URL"] = webhook_url
    env["CHRONICA_DISCORD_MESSAGE"] = message
    try:
        result = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                script,
            ],
            capture_output=True,
            text=True,
            timeout=45,
            env=env,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"PowerShell Discord transport failed: {exc}", file=sys.stderr, flush=True)
        return False

    if result.returncode == 0:
        return True

    error_text = (result.stderr or result.stdout or "").strip()
    print(f"PowerShell Discord transport failed with exit code {result.returncode}. {error_text}", file=sys.stderr, flush=True)
    return False


def test_discord_message() -> None:
    webhook_url = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    if not webhook_url:
        raise RuntimeError("Set DISCORD_WEBHOOK_URL before sending a Discord test.")
    if post_discord(webhook_url, "Chronica watcher test: Discord webhook is connected."):
        print("Discord test message sent.", flush=True)
    else:
        raise RuntimeError("Discord test message failed. Check the webhook URL and Discord permissions.")


def notifications_paused(config: dict[str, Any]) -> bool:
    pause_file = Path(config.get("notification_pause_file", "data/notifications-paused.flag"))
    return pause_file.exists()


def check_once(config: dict[str, Any], dry_run: bool = False, baseline: bool = False) -> int:
    webhook_url = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    if not webhook_url and not dry_run and not baseline:
        raise RuntimeError("Set DISCORD_WEBHOOK_URL before running the watcher.")

    state_path = Path(config["state_file"])
    known_pages_path = Path(config.get("known_pages_file", "known-pages.json"))
    cache_dir = Path(config["cache_dir"])
    state = load_state(state_path)
    known_pages = load_known_pages(known_pages_path, state)
    pages = state.setdefault("pages", {})
    known_page_urls = known_pages.setdefault("pages", {})
    found_changes = 0
    sent_messages = 0
    session = ChronicaSession(config["user_agent"])
    notify_on_first_seen = bool(config.get("notify_on_first_seen", False))
    discord_delay = float(config.get("discord_delay_seconds", 1))
    pause_notifications = notifications_paused(config)

    if config.get("requires_login"):
        login(session, config)

    urls = page_urls_to_check(config, session, known_pages)
    max_workers = max(1, int(config.get("max_concurrent_checks", 12)))
    log(f"Checking {len(urls)} page(s) with up to {max_workers} concurrent request(s).")
    if baseline:
        log("Quiet cache rebuild is active. Pages will be cached without Discord notifications.", always=True)
    elif pause_notifications:
        log("Discord notifications are paused. Changes will be cached without Discord notifications.", always=True)

    completed = 0
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_url = {
            executor.submit(fetch_page_snapshot, session, config, url): url
            for url in urls
        }

        for future in as_completed(future_to_url):
            url = future_to_url[future]
            completed += 1
            log(f"Checked page {completed}/{len(urls)}: {url}")
            try:
                url, digest, title, text, is_hidden = future.result()
            except (urllib.error.URLError, TimeoutError, RuntimeError) as exc:
                print(f"Could not check {url}: {exc}", file=sys.stderr, flush=True)
                continue

            previous = pages.get(url)
            was_known = url in known_page_urls
            title = notification_title(title, url, text)
            cache_path = save_page_cache(cache_dir, url, title, text)
            pages[url] = {
                "hash": digest,
                "title": title,
                "last_checked": int(time.time()),
                "cache_path": cache_path,
                "content_filter_version": CONTENT_FILTER_VERSION,
                "hidden_or_secret": is_hidden,
            }
            if not was_known:
                known_page_urls[url] = {
                    "title": title,
                    "first_seen": int(time.time()),
                    "cache_path": cache_path,
                    "hidden_or_secret": is_hidden,
                }
                save_known_pages(known_pages_path, known_pages)

            if is_hidden:
                log(f"Skipped Discord notification for hidden/private page: {title}", always=True)
                continue
            elif baseline:
                log(f"Quietly cached page: {title}")
                continue
            elif not was_known and notify_on_first_seen:
                message = new_page_message(title, url)
            elif not was_known:
                log(f"Baselined new page without Discord notification: {title}")
                continue
            elif previous is None:
                log(f"Known page has no previous hash yet, cached without notification: {title}")
                continue
            elif previous.get("content_filter_version") != CONTENT_FILTER_VERSION:
                log(f"Re-baselined clean page content without notification: {title}")
                continue
            elif previous.get("hash") != digest:
                message = updated_page_message(title, url)
            else:
                continue

            save_state(state_path, state)
            found_changes += 1
            if pause_notifications:
                log(f"Notifications paused; cached change without Discord message: {title}", always=True)
                continue
            if dry_run:
                print(message, flush=True)
            else:
                if post_discord(webhook_url, message):
                    record_sent_message(config, message, url, title)
                    sent_messages += 1
                    if discord_delay > 0:
                        time.sleep(discord_delay)

    save_state(state_path, state)
    save_known_pages(known_pages_path, known_pages)
    if not dry_run:
        log(f"Discord messages sent: {sent_messages}", always=True)
    return found_changes


def list_pages(config: dict[str, Any]) -> int:
    session = ChronicaSession(config["user_agent"])
    if config.get("requires_login"):
        login(session, config)

    urls = discover_urls(config, session)
    for url in urls:
        print(url, flush=True)
    print(f"\nDiscovered {len(urls)} watchable Chronica pages.", flush=True)
    return len(urls)


def show_status(config: dict[str, Any]) -> None:
    state_path = Path(config["state_file"])
    known_pages_path = Path(config.get("known_pages_file", "known-pages.json"))
    cache_dir = Path(config["cache_dir"])
    state = load_state(state_path)
    known_pages = load_known_pages(known_pages_path, state)
    save_known_pages(known_pages_path, known_pages)
    pages = state.get("pages", {})
    last_checked_values = [
        page.get("last_checked", 0)
        for page in pages.values()
        if isinstance(page, dict) and page.get("last_checked")
    ]
    last_checked = max(last_checked_values) if last_checked_values else None

    print("Chronica watcher status", flush=True)
    print(f"Known pages: {len(pages)}", flush=True)
    print(f"Known page index: {len(known_pages.get('pages', {}))}", flush=True)
    print(f"State file: {state_path}", flush=True)
    print(f"Known pages file: {known_pages_path}", flush=True)
    print(f"Cache folder: {cache_dir}", flush=True)
    print(f"Cache files: {len(list(cache_dir.glob('*.txt'))) if cache_dir.exists() else 0}", flush=True)
    if last_checked:
        print(f"Last checked: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(last_checked))}", flush=True)
    else:
        print("Last checked: never", flush=True)


def list_known_pages(config: dict[str, Any]) -> int:
    state = load_state(Path(config["state_file"]))
    known_pages_path = Path(config.get("known_pages_file", "known-pages.json"))
    known_pages = load_known_pages(known_pages_path, state)
    save_known_pages(known_pages_path, known_pages)
    pages = known_pages.get("pages", {})
    for url, page in sorted(pages.items()):
        title = page.get("title", "Chronica page") if isinstance(page, dict) else "Chronica page"
        print(f"{title}\t{url}", flush=True)
    print(f"\nKnown pages in cache: {len(pages)}", flush=True)
    return len(pages)


def repair_development_titles(config: dict[str, Any]) -> int:
    session = ChronicaSession(config["user_agent"])
    if config.get("requires_login"):
        login(session, config)

    state_path = Path(config["state_file"])
    known_pages_path = Path(config.get("known_pages_file", "known-pages.json"))
    cache_dir = Path(config["cache_dir"])
    state = load_state(state_path)
    known_pages = load_known_pages(known_pages_path, state)
    urls = sorted(
        url
        for url in known_pages.get("pages", {})
        if "/developments/" in url and is_allowed_watch_url(url, config) and is_detail_watch_url(url)
    )

    if not urls:
        print("No known development pages found yet. Run Find New Pages or Quiet Cache Rebuild first.", flush=True)
        return 0

    print(f"Repairing development titles for {len(urls)} page(s). No Discord messages will be sent.", flush=True)
    changed = 0
    failed = 0
    pages = state.setdefault("pages", {})
    known_page_urls = known_pages.setdefault("pages", {})

    for index, url in enumerate(urls, 1):
        old_title = ""
        if isinstance(known_page_urls.get(url), dict):
            old_title = known_page_urls[url].get("title", "")
        try:
            _, digest, raw_title, text, is_hidden = fetch_page_snapshot(session, config, url)
            fixed_title = notification_title(raw_title, url, text)
            cache_path = save_page_cache(cache_dir, url, fixed_title, text)
            pages[url] = {
                "hash": digest,
                "title": fixed_title,
                "last_checked": int(time.time()),
                "cache_path": cache_path,
                "content_filter_version": CONTENT_FILTER_VERSION,
                "hidden_or_secret": is_hidden,
            }
            known_page_urls.setdefault(url, {})
            known_page_urls[url].update(
                {
                    "title": fixed_title,
                    "cache_path": cache_path,
                    "hidden_or_secret": is_hidden,
                }
            )
            if not known_page_urls[url].get("first_seen"):
                known_page_urls[url]["first_seen"] = int(time.time())

            if old_title != fixed_title:
                changed += 1
                print(f"[{index}/{len(urls)}] {old_title or 'Untitled'} -> {fixed_title}", flush=True)
            else:
                print(f"[{index}/{len(urls)}] OK {fixed_title}", flush=True)
        except (urllib.error.URLError, TimeoutError, RuntimeError) as exc:
            failed += 1
            print(f"[{index}/{len(urls)}] Could not repair {url}: {exc}", file=sys.stderr, flush=True)

    save_state(state_path, state)
    save_known_pages(known_pages_path, known_pages)
    print(f"\nDevelopment title repair complete. Changed: {changed}. Failed: {failed}.", flush=True)
    return changed


def test_one_page(config: dict[str, Any], url: str) -> int:
    session = ChronicaSession(config["user_agent"])
    if config.get("requires_login"):
        login(session, config)

    normalized_url = normalize_url(url, config["site_base_url"])
    allowed = is_allowed_watch_url(normalized_url, config)
    detail = is_detail_watch_url(normalized_url)
    html = session.fetch_text(normalized_url)
    if config.get("requires_login") and looks_like_login_page(html):
        raise RuntimeError(f"Chronica asked for login again while reading {normalized_url}")
    digest, title, text = visible_text_hash(html, normalized_url)
    is_hidden = bool(config.get("skip_hidden_or_secret_pages", True)) and page_looks_hidden_or_secret(html, text)
    state = load_state(Path(config["state_file"]))
    previous = state.get("pages", {}).get(normalized_url)
    would_notify = allowed and detail and not is_hidden and previous is not None and previous.get("hash") != digest
    would_baseline = allowed and detail and previous is None
    gm_warning = page_has_gm_access_markers(html, text)

    print("Chronica one-page test", flush=True)
    print(f"URL: {normalized_url}", flush=True)
    print(f"Title detected: {title}", flush=True)
    print(f"Page type: {page_kind(normalized_url)}", flush=True)
    print(f"Allowed by watcher: {'yes' if allowed else 'no'}", flush=True)
    print(f"Real detail page: {'yes' if detail else 'no'}", flush=True)
    print(f"Hidden/private-looking: {'yes' if is_hidden else 'no'}", flush=True)
    print(f"Already known: {'yes' if previous is not None else 'no'}", flush=True)
    if gm_warning:
        print("Safety warning: this page/account shows GM-style controls or private fields. A player-only bot account is safer.", flush=True)
    if would_notify:
        print("Would notify Discord: yes", flush=True)
    elif would_baseline:
        print("Would notify Discord: no, first scan would save it quietly unless new-page notices are enabled.", flush=True)
    else:
        print("Would notify Discord: no", flush=True)
    print("\nDiscord message preview:", flush=True)
    print(preview_message_for_page(notification_title(title, normalized_url, text), normalized_url, is_new=previous is None), flush=True)
    return 0


def account_safety_check(config: dict[str, Any]) -> int:
    session = ChronicaSession(config["user_agent"])
    if config.get("requires_login"):
        login(session, config)
    warning_count = 0
    for url in config.get("watched_urls", []):
        html = session.fetch_text(url)
        parser = VisibleTextParser()
        parser.feed(html)
        if page_has_gm_access_markers(html, parser.text):
            warning_count += 1
            print(f"Safety warning on {url}: bot account can see GM-style controls or private fields.", flush=True)
    if warning_count:
        print("\nRecommendation: use a player-level Chronica account for the bot if you do not want hidden/secret content posted.", flush=True)
    else:
        print("No obvious GM-only controls were detected on the watched section pages.", flush=True)
    return warning_count


def should_discover_pages(known_pages: dict[str, Any], config: dict[str, Any]) -> bool:
    pages = known_pages.get("pages", {})
    if not pages:
        return True

    last_discovery_count = int(known_pages.get("last_discovery_count", 0) or 0)
    if last_discovery_count and len(pages) < last_discovery_count:
        log(
            f"Previous discovery found {last_discovery_count} page(s), but only {len(pages)} are cached. Re-running discovery.",
            always=True,
        )
        return True

    last_discovery = int(known_pages.get("last_discovery", 0) or 0)
    interval = int(config.get("discovery_interval_seconds", 300))
    return interval <= 0 or int(time.time()) - last_discovery >= interval


def page_urls_to_check(config: dict[str, Any], session: ChronicaSession, known_pages: dict[str, Any]) -> list[str]:
    if should_discover_pages(known_pages, config):
        log("Running new-page discovery pass.", always=True)
        urls = discover_urls(config, session)
        known_pages["last_discovery"] = int(time.time())
        known_pages["last_discovery_count"] = len(urls)
        known_count = len(known_pages.get("pages", {}))
        new_count = len([url for url in urls if url not in known_pages.get("pages", {})])
        log(f"Discovery pass found {len(urls)} detail page(s). New since last cache: {new_count}. Known before check: {known_count}.", always=True)
        return urls

    urls = sorted(url for url in known_pages.get("pages", {}).keys() if is_allowed_watch_url(url, config) and is_detail_watch_url(url))
    last_discovery = int(known_pages.get("last_discovery", 0) or 0)
    interval = int(config.get("discovery_interval_seconds", 300))
    next_discovery = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(last_discovery + interval))
    log(f"Using {len(urls)} known page(s). Next new-page discovery around {next_discovery}.")
    return urls


def fetch_page_snapshot(session: ChronicaSession, config: dict[str, Any], url: str) -> tuple[str, str, str, str, bool]:
    html = session.fetch_text(url)
    if config.get("requires_login") and looks_like_login_page(html):
        raise RuntimeError(f"Chronica asked for login again while reading {url}")
    digest, title, text = visible_text_hash(html, url)
    is_hidden = bool(config.get("skip_hidden_or_secret_pages", True)) and page_looks_hidden_or_secret(html, text)
    return url, digest, title, text, is_hidden


def main() -> int:
    configure_console_encoding()
    parser = argparse.ArgumentParser(description="Watch authenticated Chronica pages and notify Discord.")
    parser.add_argument("--config", default="config/config.json", help="Path to config JSON.")
    parser.add_argument("--env-file", default="config/.env", help="Path to private environment settings.")
    parser.add_argument("--once", action="store_true", help="Run one check and exit.")
    parser.add_argument("--dry-run", action="store_true", help="Print updates instead of posting to Discord.")
    parser.add_argument("--list-pages", action="store_true", help="List discovered campaign pages and exit.")
    parser.add_argument("--list-known-pages", action="store_true", help="List pages already saved in watcher state.")
    parser.add_argument("--status", action="store_true", help="Show saved watcher status and exit.")
    parser.add_argument("--test-discord", action="store_true", help="Send a Discord webhook test message and exit.")
    parser.add_argument("--baseline", action="store_true", help="Scan and cache pages without posting Discord messages.")
    parser.add_argument("--test-page", help="Inspect one Chronica page and show what would happen.")
    parser.add_argument("--list-sent", action="store_true", help="Show the last recorded Discord notifications.")
    parser.add_argument("--safety-check", action="store_true", help="Warn if the bot account appears to have GM-style access.")
    parser.add_argument("--repair-development-titles", action="store_true", help="Fetch all known developments and repair saved titles without Discord posts.")
    parser.add_argument("--verbose", action="store_true", help="Show progress while logging in and scanning pages.")
    args = parser.parse_args()

    global VERBOSE
    VERBOSE = args.verbose

    load_env_file(Path(args.env_file))
    config = load_config(Path(args.config))
    global LOG_FILE
    LOG_FILE = Path(config.get("log_file", "data/chronica-watcher.log"))
    log("Chronica watcher started.", always=True)

    if args.test_discord:
        test_discord_message()
        return 0
    if args.status:
        show_status(config)
        return 0
    if args.test_page:
        return test_one_page(config, args.test_page)
    if args.list_sent:
        list_sent_messages(config)
        return 0
    if args.safety_check:
        account_safety_check(config)
        return 0
    if args.repair_development_titles:
        repair_development_titles(config)
        return 0
    if args.list_known_pages:
        list_known_pages(config)
        return 0
    if args.list_pages:
        list_pages(config)
        return 0

    def run_loop(lock: WatcherLock | None = None) -> int:
        cycle = 0
        while True:
            cycle += 1
            if lock:
                lock.heartbeat("checking")
            log(f"Starting page check #{cycle}.", always=True)
            changes = check_once(config, dry_run=args.dry_run, baseline=args.baseline)
            log(f"Finished page check #{cycle}. Changes found: {changes}", always=True)
            if args.once or args.baseline:
                return 0
            if lock:
                lock.heartbeat("sleeping")
            sleep_remaining = int(config["check_interval_seconds"])
            next_check_time = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() + sleep_remaining))
            log(f"Waiting {sleep_remaining} seconds. Next page check starts around {next_check_time}.", always=True)
            while sleep_remaining > 0:
                time.sleep(min(30, sleep_remaining))
                sleep_remaining -= 30
                if lock:
                    lock.heartbeat("sleeping")

    if args.once or args.dry_run or args.baseline:
        return run_loop()

    with WatcherLock(Path(config.get("lock_file", "watcher.lock"))) as lock:
        return run_loop(lock)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        if LOG_FILE is None:
            LOG_FILE = Path("data/chronica-watcher.log")
        write_log_file("Watcher crashed:")
        for line in traceback.format_exc().rstrip().splitlines():
            write_log_file(line)
        raise
