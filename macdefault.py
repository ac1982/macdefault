# -*- coding: utf-8 -*-

"""
ext.py

Switch default file associations (via duti) for:
  doc, docx, xls, xlsx, ppt, pptx, rtf, csv

Suites:
  --microsoft / --office   -> Word/Excel/PowerPoint
  --wps / --kingsoft       -> WPS Office (single app)
  --apple                  -> Pages/Numbers/Keynote, rtf->TextEdit, csv->Numbers

Diagnostics:
  --print-bundle-ids       -> Print a SHORT grouped suite summary as pretty ASCII tables
  --doctor                 -> Same as --print-bundle-ids + current defaults (duti -x)

Interactive:
  --ext=doc                -> List apps that declare support for .doc and set the chosen one as default
  --ext=md --show          -> Only show current default + candidates (no changes)

Notes:
- macOS only
- Requires `duti`: brew install duti
- Requires `click`: python3 -m pip install click
- Requires `questionary`: python3 -m pip install questionary
- Requires `wcwidth` (for aligned table output): python3 -m pip install wcwidth
- WPS name lookup via AppleScript can be unreliable; we prefer /Applications/wpsoffice.app if present.
"""

import platform
import plistlib
import os
import shutil
import subprocess
import sys
import tempfile
from typing import Dict, List, Tuple, Optional

import click
import questionary
from prompt_toolkit.key_binding import KeyBindings
from wcwidth import wcswidth


# ---- Extensions we manage (the "SAMPLES subset" you requested) ----
EXTS_WORD = ["doc", "docx"]
EXTS_EXCEL = ["xls", "xlsx"]
EXTS_PPT = ["ppt", "pptx"]
EXTS_OTHER = ["rtf", "csv"]
ALL_EXTS = EXTS_WORD + EXTS_EXCEL + EXTS_PPT + EXTS_OTHER

# ---- Suites we show in diagnostics (concise) ----
SUITE_APPS = {
    "Microsoft": ["Microsoft Word", "Microsoft Excel", "Microsoft PowerPoint"],
    "WPS / Kingsoft": ["WPS Office"],
    "Apple": ["Pages", "Numbers", "Keynote", "TextEdit"],
}

# Stable WPS install path (your machine: /Applications/wpsoffice.app)
WPS_APP_PATH = "/Applications/wpsoffice.app"

APP_SEARCH_DIRS = [
    "/Applications",
    "/System/Applications",
    "/System/Applications/Utilities",
    shutil.os.path.expanduser("~/Applications"),
]

GENERIC_UTI_CUTOFF = {"public.data", "public.item", "public.content"}


# --------------------------- helpers ---------------------------

def _run(cmd: List[str]) -> Tuple[int, str, str]:
    """Run command and return (returncode, stdout, stderr). Raise on OS-level exec errors."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except OSError as e:
        raise click.ClickException(f"Failed to execute: {' '.join(cmd)}\nOS error: {e}")


def require_macos() -> None:
    if platform.system().lower() != "darwin":
        raise click.ClickException("This tool only supports macOS.")


def find_duti() -> str:
    duti = shutil.which("duti")
    if not duti:
        raise click.ClickException("`duti` not found. Install it with: brew install duti")
    return duti


def normalize_ext(ext: str) -> str:
    e = ext.strip().lower()
    if e.startswith("."):
        e = e[1:]
    return e


def require_ext(ext: str) -> str:
    e = normalize_ext(ext)
    if not e:
        raise click.ClickException("Empty extension.")
    return e


def read_info_plist(app_path: str) -> Optional[Dict[str, object]]:
    p = app_path.rstrip("/")
    info_plist = f"{p}/Contents/Info.plist"
    try:
        with open(info_plist, "rb") as f:
            info = plistlib.load(f)
    except OSError:
        return None
    except Exception:
        return None
    if not isinstance(info, dict):
        return None
    return info


def bundle_id_of_app(app_name: str) -> Optional[str]:
    """Resolve bundle id from LaunchServices by app display name."""
    rc, out, err = _run(["/usr/bin/osascript", "-e", f'id of app "{app_name}"'])
    if rc != 0 or not out:
        return None
    return out


def bundle_id_from_app_path(app_path: str) -> Optional[str]:
    """Read CFBundleIdentifier from an .app path without relying on LaunchServices name lookup."""
    p = app_path.rstrip("/")
    if not p.endswith(".app"):
        return None

    # Prefer mdls (fast) when available
    if shutil.which("mdls"):
        rc, out, err = _run(["/usr/bin/mdls", "-raw", "-name", "kMDItemCFBundleIdentifier", p])
        if rc == 0 and out and out not in ("(null)", "null"):
            return out.strip()

    info = read_info_plist(p)
    if info:
        bid = info.get("CFBundleIdentifier")
        if isinstance(bid, str) and bid:
            return bid

    return None


def app_info_from_app_path(app_path: str) -> Optional[Dict[str, object]]:
    """Read basic app info from Info.plist (bundle id, display name, document types)."""
    p = app_path.rstrip("/")
    info = read_info_plist(p)
    if not info:
        return None

    bundle_id = info.get("CFBundleIdentifier")
    if not isinstance(bundle_id, str) or not bundle_id:
        return None
    name = info.get("CFBundleDisplayName") or info.get("CFBundleName")
    if not name:
        base = shutil.os.path.basename(p)
        name = base[:-4] if base.lower().endswith(".app") else base
    doc_types = info.get("CFBundleDocumentTypes") or []
    if not isinstance(doc_types, list):
        doc_types = []
    return {"name": name, "bundle_id": bundle_id, "path": p, "doc_types": doc_types}


def _parse_mdls_list(out: str) -> List[str]:
    items: List[str] = []
    for line in out.splitlines():
        s = line.strip()
        if not s or s in ("(", ")"):
            continue
        if s.endswith(","):
            s = s[:-1]
        if (s.startswith('"') and s.endswith('"')) or (s.startswith("'") and s.endswith("'")):
            s = s[1:-1]
        if s:
            items.append(s)
    if not items:
        s = out.strip()
        if s and s not in ("(null)", "null"):
            s = s.strip(",")
            if (s.startswith('"') and s.endswith('"')) or (s.startswith("'") and s.endswith("'")):
                s = s[1:-1]
            if s:
                items.append(s)
    return items


def extension_utis(ext: str) -> List[str]:
    e = require_ext(ext)
    if not shutil.which("mdls"):
        return []

    fd, tmp_path = tempfile.mkstemp(prefix="__ext_tmp__", suffix=f".{e}")
    os.close(fd)
    utis: List[str] = []
    try:
        rc, out, _err = _run(["/usr/bin/mdls", "-raw", "-name", "kMDItemContentType", tmp_path])
        if rc == 0 and out and out not in ("(null)", "null"):
            utis.append(out.strip())

        rc, out, _err = _run(["/usr/bin/mdls", "-raw", "-name", "kMDItemContentTypeTree", tmp_path])
        if rc == 0 and out and out not in ("(null)", "null"):
            utis.extend(_parse_mdls_list(out))
    finally:
        try:
            os.remove(tmp_path)
        except OSError:
            pass

    # Keep a reasonably specific chain; drop generic UTI tail.
    filtered: List[str] = []
    for u in utis:
        if u in GENERIC_UTI_CUTOFF:
            break
        filtered.append(u)

    seen = set()
    out_list: List[str] = []
    for u in filtered:
        if u not in seen:
            out_list.append(u)
            seen.add(u)
    return out_list


def iter_app_paths(max_depth: int = 3) -> List[str]:
    """Find .app bundles in common locations (bounded depth, no Spotlight required)."""
    apps: List[str] = []
    seen = set()
    for base in APP_SEARCH_DIRS:
        if not base or not shutil.os.path.isdir(base):
            continue
        base = base.rstrip("/")
        for dirpath, dirnames, _filenames in shutil.os.walk(base):
            rel_depth = dirpath[len(base) :].count(shutil.os.sep)
            if rel_depth > max_depth:
                dirnames[:] = []
                continue
            if dirpath.lower().endswith(".app"):
                if dirpath not in seen:
                    apps.append(dirpath)
                    seen.add(dirpath)
                dirnames[:] = []
                continue
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
    return apps


def apps_supporting_extension(ext: str) -> List[Dict[str, object]]:
    """Return app infos that declare support for a filename extension in Info.plist."""
    e = normalize_ext(ext)
    if not e:
        return []
    ext_utis = extension_utis(e)
    ext_uti_set = set(ext_utis)
    out: List[Dict[str, object]] = []
    for app_path in iter_app_paths():
        info = app_info_from_app_path(app_path)
        if not info:
            continue
        utis: List[str] = []
        declared = False
        for dt in info["doc_types"]:  # type: ignore[index]
            if not isinstance(dt, dict):
                continue
            exts = dt.get("CFBundleTypeExtensions") or []
            if isinstance(exts, str):
                exts_norm = [exts.lower().lstrip(".")]
            elif isinstance(exts, list):
                exts_norm = [str(x).lower().lstrip(".") for x in exts]
            else:
                exts_norm = []

            it = dt.get("LSItemContentTypes") or []
            if isinstance(it, str):
                it_list = [it]
            elif isinstance(it, list):
                it_list = [str(x) for x in it if x]
            else:
                it_list = []

            match_by_ext = e in exts_norm
            match_by_uti = bool(ext_uti_set and set(it_list) & ext_uti_set)
            if match_by_ext or match_by_uti:
                declared = True
                if ext_uti_set:
                    matched = [u for u in it_list if u in ext_uti_set]
                    if matched:
                        utis.extend(matched)
                    elif match_by_ext:
                        # Filter out generic UTIs to avoid hijacking unrelated file types
                        utis.extend([u for u in it_list if u not in GENERIC_UTI_CUTOFF])
                else:
                    # Filter out generic UTIs to avoid hijacking unrelated file types
                    utis.extend([u for u in it_list if u not in GENERIC_UTI_CUTOFF])
        if declared:
            info2 = dict(info)
            info2["utis"] = sorted(set(utis))
            out.append(info2)

    out.sort(key=lambda x: (str(x.get("name", "")).lower(), str(x.get("bundle_id", "")).lower()))
    return out


def paths_for_bundle_id(bundle_id: str, limit: int = 3) -> List[str]:
    """Resolve up to N app paths for a bundle id via Spotlight (may be empty if not indexed)."""
    rc, out, err = _run(["/usr/bin/mdfind", f'kMDItemCFBundleIdentifier == "{bundle_id}"'])
    if rc != 0 or not out:
        return []
    paths = [p for p in out.splitlines() if p.endswith(".app")]
    seen = set()
    uniq = []
    for p in paths:
        if p not in seen:
            uniq.append(p)
            seen.add(p)
    return uniq[:limit]


def get_app_info(app_name: str) -> Dict[str, object]:
    """
    Return compact info:
      {
        "name": str,
        "installed": bool,
        "bundle_id": Optional[str],
        "paths": List[str]
      }
    """
    # Special-case WPS: name lookup can fail; use stable path first.
    if app_name == "WPS Office":
        if shutil.os.path.exists(WPS_APP_PATH):
            bid = bundle_id_from_app_path(WPS_APP_PATH)
            if bid:
                return {"name": app_name, "installed": True, "bundle_id": bid, "paths": [WPS_APP_PATH]}

    bid = bundle_id_of_app(app_name)
    if not bid:
        return {"name": app_name, "installed": False, "bundle_id": None, "paths": []}

    paths = paths_for_bundle_id(bid)
    return {"name": app_name, "installed": True, "bundle_id": bid, "paths": paths}


def _parse_duti_output(out: str) -> Tuple[List[str], Optional[str], Optional[str], Optional[str]]:
    lines = [l.strip() for l in out.splitlines() if l.strip()]
    name = None
    path = None
    bundle_id = None
    if "|" in out:
        parts = [p.strip() for p in out.split("|") if p.strip()]
        if len(parts) >= 3:
            name, path, bundle_id = parts[0], parts[1], parts[2]
    elif len(lines) >= 3:
        name, path, bundle_id = lines[0], lines[1], lines[2]
    return lines, name, path, bundle_id


def duti_default_info(duti: str, ext: str) -> Tuple[str, Optional[str]]:
    """Return (display_line, bundle_id) for `duti -x` output."""
    e = require_ext(ext)
    rc, out, err = _run([duti, "-x", e])
    if rc != 0:
        return f".{e}: (unable to query) {err or out}", None
    lines, _name, _path, bundle_id = _parse_duti_output(out)
    line = f".{e}: " + " | ".join(lines)
    return line, bundle_id


def duti_default_details(duti: str, ext: str) -> Tuple[str, Optional[Dict[str, str]]]:
    """Return (display_line, details) for `duti -x` output."""
    e = require_ext(ext)
    rc, out, err = _run([duti, "-x", e])
    if rc != 0:
        return f".{e}: (unable to query) {err or out}", None
    lines, name, path, bundle_id = _parse_duti_output(out)
    line = f".{e}: " + " | ".join(lines)
    if not bundle_id:
        return line, None
    if not name:
        name = bundle_id
    if not path:
        paths = paths_for_bundle_id(bundle_id, limit=1)
        path = paths[0] if paths else "(path unknown)"
    return line, {"name": name, "path": path, "bundle_id": bundle_id}


def show_default(duti: str, ext: str) -> str:
    """Return a single-line summary from `duti -x ext`."""
    line, _ = duti_default_info(duti, ext)
    return line


def _format_candidate_line(
    idx: int,
    app: Dict[str, object],
    current_bundle_id: Optional[str],
) -> str:
    utis = app.get("utis") or []
    uti_hint = f" | {utis[0]}" if utis else ""
    mark = "*" if current_bundle_id and app.get("bundle_id") == current_bundle_id else " "
    return f"{mark}{idx:2d}) {app['name']} | {app['path']} | {app['bundle_id']}{uti_hint}"


def _format_candidate_title(
    app: Dict[str, object],
    current_bundle_id: Optional[str],
) -> str:
    utis = app.get("utis") or []
    uti_hint = f" | {utis[0]}" if utis else ""
    mark = "*" if current_bundle_id and app.get("bundle_id") == current_bundle_id else " "
    return f"{mark} {app['name']} | {app['path']} | {app['bundle_id']}{uti_hint}"


def merge_default_candidate(
    apps: List[Dict[str, object]],
    default_info: Optional[Dict[str, str]],
) -> Tuple[List[Dict[str, object]], Optional[str]]:
    if not default_info:
        return apps, None
    default_bid = default_info["bundle_id"]
    for app in apps:
        if app.get("bundle_id") == default_bid:
            return apps, default_bid
    default_app: Dict[str, object] = dict(default_info)
    default_app.setdefault("utis", [])
    return [default_app] + apps, default_bid


def show_extension_default_and_options(duti: str, ext: str) -> None:
    e = require_ext(ext)

    click.secho(f"== Show Handlers for .{e} ==", bold=True, fg="cyan")
    click.secho("\n-- Current Default --", bold=True, fg="blue")
    line, default_info = duti_default_details(duti, e)
    click.echo(line)

    click.secho("\n-- Candidates (declared + UTI match + current default) --", bold=True, fg="blue")
    click.echo("Scanning installed apps (this may take a moment)...")
    apps = apps_supporting_extension(e)
    apps, current_bid = merge_default_candidate(apps, default_info)
    if not apps:
        click.echo("(none found)")
        return

    if current_bid:
        click.echo("(* = current default)")
    for idx, a in enumerate(apps, start=1):
        click.echo(_format_candidate_line(idx, a, current_bid))


def lsregister_force_register_app(app_path: str) -> Tuple[bool, str]:
    lsregister = (
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
        "LaunchServices.framework/Support/lsregister"
    )
    if not shutil.os.path.exists(lsregister):
        return False, "lsregister not found"
    rc, out, err = _run([lsregister, "-f", app_path])
    if rc != 0:
        return False, (err or out or "unknown error")
    return True, ""


def prompt_index_with_questionary(
    apps: List[Dict[str, object]],
    current_bundle_id: Optional[str],
) -> Optional[int]:
    """
    Read a selection interactively using questionary.
    - Up/Down arrows change selection (TTY only).
    - ESC/Ctrl+C cancels.
    """
    max_index = len(apps)
    if max_index < 1:
        return None

    selected_idx = 1
    if current_bundle_id:
        for idx, app in enumerate(apps, start=1):
            if app.get("bundle_id") == current_bundle_id:
                selected_idx = idx
                break

    choices: List[questionary.Choice] = []
    for idx, app in enumerate(apps, start=1):
        shortcut = str(idx) if idx <= 9 else None
        choices.append(
            questionary.Choice(
                title=_format_candidate_title(app, current_bundle_id),
                value=idx,
                shortcut_key=shortcut,
            )
        )
    choices.append(
        questionary.Choice(
            title="Cancel",
            value=None,
            shortcut_key="q",
        )
    )

    kb = KeyBindings()

    @kb.add("escape")
    @kb.add("c-c")
    @kb.add("c-d")
    def _cancel(_event) -> None:
        _event.app.exit(result=None)

    question = questionary.select(
        "Select an app",
        choices=choices,
        default=selected_idx,
        use_shortcuts=True,
    )

    def _coerce_choice(result: object) -> Optional[int]:
        if isinstance(result, int):
            return result
        if isinstance(result, str):
            s = result.strip()
            if s.isdigit():
                return int(s)
            return None
        return None

    try:
        return _coerce_choice(question.ask(kbi=kb))
    except TypeError:
        try:
            response = questionary.prompt(
                [
                    {
                        "type": "select",
                        "name": "choice",
                        "message": "Select an app",
                        "choices": choices,
                        "default": selected_idx,
                        "use_shortcuts": True,
                    }
                ],
                kbi=kb,
            )
            return _coerce_choice(response.get("choice") if response else None)
        except TypeError:
            return _coerce_choice(question.ask())
    except KeyboardInterrupt:
        return None


def prompt_index_with_esc(max_index: int) -> Optional[int]:
    """
    Read a numeric selection interactively.
    - ESC cancels (TTY only).
    - ENTER confirms.
    """
    if max_index < 1:
        return None

    if not sys.stdin.isatty():
        raw = click.prompt("Select number (or 'q' to cancel)", type=str).strip().lower()
        if raw in ("q", "quit", "exit", "esc", "cancel"):
            return None
        try:
            n = int(raw)
        except ValueError:
            raise click.ClickException("Invalid selection.")
        if not (1 <= n <= max_index):
            raise click.ClickException("Selection out of range.")
        return n

    click.echo("Select number (ESC to cancel): ", nl=False)
    buf = ""
    while True:
        ch = click.getchar()
        if ch == "\x1b":  # ESC
            click.echo()
            return None
        if ch in ("\r", "\n"):
            click.echo()
            if not buf:
                click.echo("Enter a number, or ESC to cancel.")
                click.echo("Select number (ESC to cancel): ", nl=False)
                continue
            n = int(buf)
            if not (1 <= n <= max_index):
                buf = ""
                click.echo(f"Out of range (1-{max_index}).")
                click.echo("Select number (ESC to cancel): ", nl=False)
                continue
            return n
        if ch.isdigit():
            buf += ch
            click.echo(ch, nl=False)
            continue
        if ch in ("\b", "\x7f"):  # backspace / delete
            if buf:
                buf = buf[:-1]
                click.echo("\b \b", nl=False)
            continue


def interactive_set_default_for_extension(duti: str, ext: str, dry_run: bool) -> None:
    e = require_ext(ext)

    click.secho(f"== Choose Default App for .{e} ==", bold=True, fg="cyan")
    click.secho("\n-- Current Default --", bold=True, fg="blue")
    line, default_info = duti_default_details(duti, e)
    click.echo(line)

    click.secho("\n-- Candidates (declared + UTI match) --", bold=True, fg="blue")
    click.echo("Scanning installed apps (this may take a moment)...")
    apps = apps_supporting_extension(e)
    apps, current_bid = merge_default_candidate(apps, default_info)
    if not apps:
        raise click.ClickException(
            f"No applications found that declare support for .{e} in Info.plist.\n"
            "Tip: In Finder, right-click a file -> Open With -> Other..., then 'Change All...'."
        )

    use_tty_selector = sys.stdin.isatty() and sys.stdout.isatty()
    if use_tty_selector:
        if current_bid:
            click.echo("(* = current default)")
        click.echo("Use Up/Down arrows to select, Enter to confirm, or press q to cancel.")
        click.echo("Tip: Press 1-9 for quick select.")
        choice = prompt_index_with_questionary(apps, current_bid)
    else:
        if current_bid:
            click.echo("(* = current default)")
        for idx, a in enumerate(apps, start=1):
            click.echo(_format_candidate_line(idx, a, current_bid))
        choice = prompt_index_with_esc(len(apps))
    if choice is None:
        click.secho("Cancelled.", fg="yellow")
        return
    selected = apps[choice - 1]
    click.secho("\n-- Selected --", bold=True, fg="green")
    click.secho(f"Selected: {selected['name']} ({selected['bundle_id']})", fg="green", bold=True)

    if not dry_run:
        path = str(selected["path"])
        # Only call lsregister if we have a valid .app path
        if path and path != "(path unknown)" and shutil.os.path.exists(path) and path.endswith(".app"):
            ok, err = lsregister_force_register_app(path)
            if not ok:
                click.secho(f"(!) lsregister failed: {err}", fg="yellow")
        elif path == "(path unknown)":
            click.secho(f"(!) Skipping lsregister: app path could not be determined", fg="yellow")

    keys: List[str] = [f".{e}"]
    for k in (selected.get("utis") or []):
        # Skip generic UTIs that would hijack unrelated file types
        if str(k) not in GENERIC_UTI_CUTOFF:
            keys.append(str(k))

    seen = set()
    keys_uniq: List[str] = []
    for k in keys:
        if k not in seen:
            keys_uniq.append(k)
            seen.add(k)

    click.secho("\n-- Applying Settings --", bold=True, fg="cyan")
    for k in keys_uniq:
        ok, msg = set_default(duti, str(selected["bundle_id"]), k, dry_run=dry_run)
        if ok:
            click.secho(f"✓ {k}", fg="green")
        else:
            click.secho(f"✗ {k}: {msg}", fg="yellow")

    if not dry_run:
        _run(["/usr/bin/killall", "Finder"])

    click.secho("\n-- Verification --", bold=True, fg="magenta")
    click.echo(show_default(duti, e))


# --------------------------- ASCII table output ---------------------------

def _dwidth(s: str) -> int:
    # display width in terminal cells
    w = wcswidth(s)
    return w if w >= 0 else len(s)


def _ljust_vis(s: str, width: int) -> str:
    pad = width - _dwidth(s)
    return s + (" " * max(0, pad))


def _center_vis(s: str, width: int) -> str:
    pad = width - _dwidth(s)
    if pad <= 0:
        return s
    left = pad // 2
    right = pad - left
    return (" " * left) + s + (" " * right)


def _fmt_row(cols: List[str], widths: List[int]) -> str:
    out = []
    for i, (c, w) in enumerate(zip(cols, widths)):
        if i == 0:
            out.append(_center_vis(c, w))  # status col
        else:
            out.append(_ljust_vis(c, w))
    return "| " + " | ".join(out) + " |"

def _fmt_sep(widths: List[int]) -> str:
    return "+-" + "-+-".join("-" * w for w in widths) + "-+"


def print_suite_summary_table() -> None:
    """Pretty grouped suite summary, short and useful."""
    click.secho("== Bundles (Suite Summary) ==", bold=True)

    for suite, apps in SUITE_APPS.items():
        click.secho(f"\n[{suite}]", bold=True)
        header = ["S", "App", "Bundle ID", "Path"]
        rows: List[List[str]] = [header]

        for app in apps:
            info = get_app_info(app)
            if not info["installed"]:
                rows.append(["❌", app, "(unresolved)", "(not resolvable via LaunchServices / path)"])
                continue

            bid = str(info["bundle_id"])
            paths = info["paths"]
            main_path = paths[0] if paths else "(path not found by Spotlight)"
            rows.append(["✅", app, bid, main_path])

            # Show additional paths (alt installs) as extra rows
            for alt in paths[1:]:
                rows.append(["", "", "", alt])

        # Optional: clamp Path column width to avoid ultra-wide tables
        MAX_PATH = 60  # tweak to taste
        PATH_COL = 3

        def clamp(text: str, max_len: int) -> str:
            if len(text) <= max_len:
                return text
            if max_len <= 1:
                return "…"
            return text[: max_len - 1] + "…"

        for r in rows:
            r[PATH_COL] = clamp(r[PATH_COL], MAX_PATH)

        # Column widths
        widths = [0, 0, 0, 0]
        for r in rows:
            for i, c in enumerate(r):
                widths[i] = max(widths[i], _dwidth(c))

        sep = _fmt_sep(widths)
        click.echo(sep)
        click.echo(_fmt_row(rows[0], widths))
        click.echo(sep)

        for r in rows[1:]:
            line = _fmt_row(r, widths)
            if r[0] == "✅":
                click.secho(line, fg="green")
            elif r[0] == "❌":
                click.secho(line, fg="red")
            else:
                click.echo(line)

        click.echo(sep)


def doctor_output(duti: str) -> None:
    print_suite_summary_table()
    click.secho("\n== Current Defaults (duti -x) ==", bold=True)
    for ext in ALL_EXTS:
        click.echo(show_default(duti, ext))


# --------------------------- suite mapping + switching ---------------------------

def suite_mapping(suite: str) -> Dict[str, str]:
    """Return ext -> bundle_id mapping for a given suite."""
    if suite == "microsoft":
        bid_word = bundle_id_of_app("Microsoft Word")
        bid_excel = bundle_id_of_app("Microsoft Excel")
        bid_ppt = bundle_id_of_app("Microsoft PowerPoint")
        if not (bid_word and bid_excel and bid_ppt):
            raise click.ClickException("Microsoft Office apps not fully resolvable (Word/Excel/PowerPoint).")

        m: Dict[str, str] = {}
        for e in EXTS_WORD:
            m[e] = bid_word
        for e in EXTS_EXCEL:
            m[e] = bid_excel
        for e in EXTS_PPT:
            m[e] = bid_ppt

        # Practical defaults for "other"
        m["rtf"] = bid_word
        m["csv"] = bid_excel
        return m

    if suite == "wps":
        bid_wps = None
        if shutil.os.path.exists(WPS_APP_PATH):
            bid_wps = bundle_id_from_app_path(WPS_APP_PATH)
        bid_wps = bid_wps or bundle_id_of_app("WPS Office")

        if not bid_wps:
            raise click.ClickException(
                "WPS Office not resolvable.\n"
                f"Checked {WPS_APP_PATH} and LaunchServices name lookup."
            )
        return {e: bid_wps for e in ALL_EXTS}

    if suite == "apple":
        bid_pages = bundle_id_of_app("Pages")
        bid_numbers = bundle_id_of_app("Numbers")
        bid_keynote = bundle_id_of_app("Keynote")
        bid_textedit = bundle_id_of_app("TextEdit")
        if not (bid_pages and bid_numbers and bid_keynote and bid_textedit):
            raise click.ClickException("Apple iWork apps not fully resolvable (Pages/Numbers/Keynote/TextEdit).")

        m: Dict[str, str] = {}
        for e in EXTS_WORD:
            m[e] = bid_pages
        for e in EXTS_EXCEL:
            m[e] = bid_numbers
        for e in EXTS_PPT:
            m[e] = bid_keynote

        m["rtf"] = bid_textedit
        m["csv"] = bid_numbers
        return m

    raise click.ClickException(f"Unknown suite: {suite}")


def set_default(duti: str, bundle_id: str, key: str, dry_run: bool) -> Tuple[bool, str]:
    cmd = [duti, "-s", bundle_id, key, "all"]
    if dry_run:
        return True, f"[dry-run] {' '.join(cmd)}"

    rc, out, err = _run(cmd)
    if rc != 0:
        return False, (err or out or "unknown error")
    return True, ""


def validate_mapping(mapping: Dict[str, str]) -> None:
    missing = [e for e in ALL_EXTS if e not in mapping]
    if missing:
        raise click.ClickException(f"Internal error: mapping missing extensions: {missing}")


def apply_mapping(
    duti: str,
    mapping: Dict[str, str],
    dry_run: bool,
    fail_fast: bool,
) -> List[Tuple[str, str]]:
    failures: List[Tuple[str, str]] = []
    with click.progressbar(ALL_EXTS, label="Applying settings") as bar:
        for ext in bar:
            bid = mapping[ext]
            ok, msg = set_default(duti, bid, f".{ext}", dry_run=dry_run)

            if dry_run and msg:
                click.secho(msg, fg="yellow")

            if not ok:
                failures.append((ext, msg))
                click.secho(f"✗ Failed: .{ext} -> {bid}: {msg}", fg="red")
                if fail_fast:
                    raise click.ClickException(f"Aborting due to error on .{ext}")
    return failures


def resolve_word_app_path(word_bundle_id: str) -> Optional[str]:
    word_paths = paths_for_bundle_id(word_bundle_id, limit=1)
    if word_paths:
        return word_paths[0]
    if shutil.os.path.exists("/Applications/Microsoft Word.app"):
        return "/Applications/Microsoft Word.app"
    return None


def repair_doc_default(duti: str, word_bundle_id: str) -> bool:
    word_path = resolve_word_app_path(word_bundle_id)
    if not word_path:
        click.secho(
            "✗ Unable to locate Microsoft Word.app for LaunchServices repair.",
            fg="red",
        )
        return False

    click.secho(
        "\n--- Repair: LaunchServices registration (Word) ---",
        bold=True,
        fg="yellow",
    )
    ok, err = lsregister_force_register_app(word_path)
    if not ok:
        click.secho(f"✗ lsregister failed: {err}", fg="red")
        return False

    keys = [
        "com.microsoft.word.doc",  # Word's declared UTI
        "public.ms-word",          # common legacy UTI on some macOS versions
        "application/msword",      # MIME type fallback
        ".doc",                    # extension
    ]
    for key in keys:
        ok2, msg2 = set_default(duti, word_bundle_id, key, dry_run=False)
        if not ok2:
            click.secho(f"(!) duti failed for {key}: {msg2}", fg="yellow")

    _run(["/usr/bin/killall", "Finder"])
    click.echo(show_default(duti, "doc"))
    return True


def collect_mismatches(
    duti: str,
    mapping: Dict[str, str],
) -> List[Tuple[str, str, Optional[str]]]:
    mismatches: List[Tuple[str, str, Optional[str]]] = []
    for ext in ALL_EXTS:
        _, current = duti_default_info(duti, ext)
        expected = mapping[ext]
        # Treat query failures (None) as mismatches to avoid masking failures
        if current != expected:
            mismatches.append((ext, expected, current))
    return mismatches


def verify_mapping(
    duti: str,
    mapping: Dict[str, str],
    suite_name: str,
    dry_run: bool,
) -> None:
    click.secho("\n--- Verification ---", bold=True)
    mismatches: List[Tuple[str, str, Optional[str]]] = []
    for ext in ALL_EXTS:
        line, current = duti_default_info(duti, ext)
        click.echo(line)
        expected = mapping[ext]
        # Treat query failures (None) as mismatches to avoid masking failures
        if current != expected:
            mismatches.append((ext, expected, current))

    if not dry_run and suite_name == "microsoft":
        needs_doc_repair = any(ext == "doc" for ext, _, _ in mismatches)
        if needs_doc_repair and repair_doc_default(duti, mapping["doc"]):
            mismatches = collect_mismatches(duti, mapping)

    if mismatches:
        click.secho("\n--- Verification Mismatches ---", bold=True, fg="red")
        for ext, expected, current in mismatches:
            click.echo(f".{ext}: expected {expected}, got {current}")
        sys.exit(1)


# --------------------------- CLI ---------------------------

@click.command(context_settings=dict(help_option_names=["-h", "--help"]))
@click.option("--microsoft", "--office", "suite_ms", is_flag=True, help="Switch to Microsoft Office suite.")
@click.option("--wps", "--kingsoft", "suite_wps", is_flag=True, help="Switch to WPS Office suite.")
@click.option("--apple", "suite_apple", is_flag=True, help="Switch to Apple iWork suite.")
@click.option("--ext", "choose_ext", metavar="EXT", help="Interactively choose default app for one extension (e.g. --ext doc).")
@click.option("--show", "show_only", is_flag=True, help="With --ext, only show current default + candidates; do not change anything.")
@click.option("--dry-run", is_flag=True, help="Print commands without changing anything.")
@click.option("--verify/--no-verify", default=True, show_default=True, help="Print current defaults after applying.")
@click.option("--fail-fast/--no-fail-fast", default=False, show_default=True, help="Exit immediately on the first error.")
@click.option("--print-bundle-ids", "print_bundle_ids", is_flag=True,
              help="Print grouped suite bundle IDs + paths as tables (short).")
@click.option("--doctor", "doctor_flag", is_flag=True,
              help="Print suite tables + current defaults (short, useful for debugging).")
def main(
    suite_ms: bool,
    suite_wps: bool,
    suite_apple: bool,
    choose_ext: Optional[str],
    show_only: bool,
    dry_run: bool,
    verify: bool,
    fail_fast: bool,
    print_bundle_ids: bool,
    doctor_flag: bool,
):
    require_macos()
    duti = find_duti()

    if show_only and not choose_ext:
        raise click.UsageError("--show requires --ext.")

    # Diagnostics mode: no suite selection required
    if print_bundle_ids:
        print_suite_summary_table()
        return

    if doctor_flag:
        doctor_output(duti)
        return

    if choose_ext:
        if suite_ms or suite_wps or suite_apple:
            raise click.UsageError("--ext cannot be combined with --office/--wps/--apple.")
        if show_only:
            show_extension_default_and_options(duti, choose_ext)
        else:
            interactive_set_default_for_extension(duti, choose_ext, dry_run=dry_run)
        return

    # Normal switch mode
    if sum([suite_ms, suite_wps, suite_apple]) != 1:
        raise click.UsageError("Select exactly one suite: --microsoft/--office OR --wps/--kingsoft OR --apple")

    suite_name = "microsoft" if suite_ms else ("wps" if suite_wps else "apple")
    click.secho(f"Target suite: {suite_name.upper()}", bold=True, fg="green")

    mapping = suite_mapping(suite_name)
    validate_mapping(mapping)

    click.echo("Extensions: " + ", ".join(ALL_EXTS) + "\n")

    failures = apply_mapping(duti, mapping, dry_run=dry_run, fail_fast=fail_fast)

    # Refresh Finder (safe if it returns non-zero)
    if not dry_run:
        _run(["/usr/bin/killall", "Finder"])

    if verify:
        verify_mapping(duti, mapping, suite_name=suite_name, dry_run=dry_run)

    if failures:
        click.secho("\n--- Errors ---", bold=True, fg="red")
        for ext, err in failures:
            click.echo(f".{ext}: {err}")
        sys.exit(1)


if __name__ == "__main__":
    main()
