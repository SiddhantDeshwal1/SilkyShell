#!/usr/bin/env python3
"""
High-performance File Search & Recent Documents backend for Quickshell Spotlight.
Provides fast drive-aware recent documents and asynchronous file search using fd.
"""

import sys
import os
import json
import urllib.parse
import xml.etree.ElementTree as ET
import subprocess

def get_username():
    return os.getenv("USER") or os.getenv("LOGNAME") or "banana"

def get_drives():
    user = get_username()
    drives = [
        {"id": "all", "label": "All", "path": ""},
        {"id": "os", "label": "OS", "path": os.path.expanduser("~")}
    ]
    media_dir = f"/run/media/{user}"
    if os.path.isdir(media_dir):
        try:
            for entry in sorted(os.listdir(media_dir)):
                p = os.path.join(media_dir, entry)
                if os.path.ismount(p) or os.path.isdir(p):
                    drives.append({"id": entry.lower(), "label": entry, "path": p})
        except Exception:
            pass
    return drives

def get_file_icon(path):
    if os.path.isdir(path):
        return "󰉋"
    ext = os.path.splitext(path)[1].lower()
    if ext in [".pdf", ".djvu"]:
        return "󰈦"
    if ext in [".doc", ".docx", ".odt", ".rtf", ".txt", ".md", ".csv", ".tsv"]:
        return "󰈙"
    if ext in [".png", ".jpg", ".jpeg", ".webp", ".gif", ".svg", ".bmp", ".ico", ".tiff"]:
        return "󰈟"
    if ext in [".mp4", ".mkv", ".webm", ".avi", ".mov", ".flv", ".wmv"]:
        return "󰕼"
    if ext in [".mp3", ".flac", ".wav", ".aac", ".ogg", ".m4a", ".opus", ".aiff"]:
        return "󰎆"
    if ext in [".zip", ".tar", ".gz", ".xz", ".7z", ".rar", ".bz2", ".tgz"]:
        return "󰛫"
    if ext in [".py", ".js", ".ts", ".jsx", ".tsx", ".html", ".css", ".json", ".qml", ".sh", ".c", ".cpp", ".rs", ".go", ".java"]:
        return "󰅩"
    return "󰈔"

def get_drive_tag(path):
    if "/run/media/" in path:
        parts = path.split("/run/media/")
        if len(parts) > 1:
            sub = parts[1].split("/")
            if len(sub) > 1:
                return sub[1]
        return "External"
    return "OS"

def get_recent(drive_id="all", max_results=10):
    user = get_username()
    home = os.path.expanduser("~")
    drives_map = {d["id"]: d["path"] for d in get_drives()}
    target_path = drives_map.get(drive_id.lower(), "")
    
    results = []
    seen = set()
    
    # 1. Check Freedesktop recently-used.xbel
    xbel = os.path.join(home, ".local/share/recently-used.xbel")
    if os.path.exists(xbel):
        try:
            tree = ET.parse(xbel)
            root = tree.getroot()
            items = []
            for bm in root.findall("bookmark"):
                href = bm.get("href", "")
                mod = bm.get("modified", "")
                if href.startswith("file://"):
                    p = urllib.parse.unquote(href[7:])
                    if p not in seen:
                        items.append((mod, p))
            items.sort(reverse=True)
            for _, p in items:
                if not os.path.exists(p):
                    continue
                seen.add(p)
                if target_path and not p.startswith(target_path):
                    continue
                results.append({
                    "action": "file",
                    "id": f"file_{p}",
                    "label": os.path.basename(p),
                    "description": p,
                    "drive": get_drive_tag(p),
                    "icon": get_file_icon(p),
                    "path": p
                })
                if len(results) >= max_results:
                    break
        except Exception:
            pass

    # 2. If fewer results, supplement with recently modified files from standard locations
    if len(results) < max_results:
        candidate_dirs = []
        if drive_id in ["all", "os"]:
            candidate_dirs.extend([
                os.path.join(home, "Downloads"),
                os.path.join(home, "Documents")
            ])
        if drive_id in ["all", "alpha"]:
            alpha_dl = f"/run/media/{user}/Alpha/Downloads"
            if os.path.isdir(alpha_dl):
                candidate_dirs.append(alpha_dl)

        recent_files = []
        for cdir in candidate_dirs:
            if not os.path.isdir(cdir):
                continue
            try:
                for fname in os.listdir(cdir):
                    fpath = os.path.join(cdir, fname)
                    if fpath in seen or fname.startswith("."):
                        continue
                    try:
                        mtime = os.path.getmtime(fpath)
                        recent_files.append((mtime, fpath))
                    except OSError:
                        pass
            except OSError:
                pass

        recent_files.sort(reverse=True)
        for _, p in recent_files:
            seen.add(p)
            results.append({
                "action": "file",
                "id": f"file_{p}",
                "label": os.path.basename(p),
                "description": p,
                "drive": get_drive_tag(p),
                "icon": get_file_icon(p),
                "path": p
            })
            if len(results) >= max_results:
                break

    for r in results:
        print(json.dumps(r, ensure_ascii=False))

def search_files(query, drive_id="all", max_results=10):
    user = get_username()
    home = os.path.expanduser("~")
    drives_map = {
        "all": [home, f"/run/media/{user}/Alpha"],
        "os": [home],
        "alpha": [f"/run/media/{user}/Alpha"]
    }
    
    # If dynamic external drive is specified
    if drive_id not in drives_map:
        media_path = f"/run/media/{user}/{drive_id}"
        targets = [media_path] if os.path.exists(media_path) else [home]
    else:
        targets = [p for p in drives_map[drive_id] if os.path.exists(p)]

    if not targets or not query.strip():
        return

    cmd = [
        "fd",
        "--max-results", str(max_results),
        "-i",
        "-E", ".cache",
        "-E", ".git",
        "-E", "node_modules",
        "-E", ".cargo",
        "-E", ".npm",
        "-E", ".local",
        "-E", "__pycache__",
        "-E", ".rustup",
        "--type", "f",
        "--type", "d",
        query.strip()
    ] + targets

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=3.0)
        lines = [l.strip() for l in proc.stdout.splitlines() if l.strip()]
        for p in lines:
            item = {
                "action": "file",
                "id": f"file_{p}",
                "label": os.path.basename(p),
                "description": p,
                "drive": get_drive_tag(p),
                "icon": get_file_icon(p),
                "path": p
            }
            print(json.dumps(item, ensure_ascii=False))
    except Exception:
        pass

def main():
    if len(sys.argv) < 2:
        print("Usage: file-search.py [drives|recent|search] [options]")
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "drives":
        print(json.dumps(get_drives()))
    elif cmd == "recent":
        drive = sys.argv[2] if len(sys.argv) > 2 else "all"
        max_r = int(sys.argv[3]) if len(sys.argv) > 3 else 10
        get_recent(drive, max_r)
    elif cmd == "search":
        drive = sys.argv[2] if len(sys.argv) > 2 else "all"
        query = sys.argv[3] if len(sys.argv) > 3 else ""
        max_r = int(sys.argv[4]) if len(sys.argv) > 4 else 10
        search_files(query, drive, max_r)

if __name__ == "__main__":
    main()
