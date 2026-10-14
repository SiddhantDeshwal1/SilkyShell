#!/usr/bin/env python3
"""
Quick Web Search Autocomplete & Chrome Bookmarks suggest backend.
Outputs line-delimited JSON objects for instant Spotlight integration.
"""

import sys
import os
import json
import urllib.request
import urllib.parse

def get_bookmarks(query, max_results=3):
    path = os.path.expanduser("~/.config/google-chrome/Default/Bookmarks")
    if not os.path.exists(path):
        return []
    results = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        q = query.lower()
        def walk(node):
            if not isinstance(node, dict):
                return
            if node.get("type") == "url":
                name = node.get("name", "")
                url = node.get("url", "")
                if q in name.lower() or q in url.lower():
                    results.append({
                        "action": "web",
                        "id": f"bm_{url}",
                        "label": name or url,
                        "description": url,
                        "query": url,
                        "icon": "󰃃"
                    })
            for k in ["children", "roots"]:
                if k in node:
                    val = node[k]
                    if isinstance(val, dict):
                        for child in val.values():
                            walk(child)
                    elif isinstance(val, list):
                        for child in val:
                            walk(child)
        walk(data)
    except Exception:
        pass
    return results[:max_results]

def get_suggestions(query, max_results=5):
    if not query.strip():
        return []
    url = f"https://suggestqueries.google.com/complete/search?client=chrome&q={urllib.parse.quote(query)}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=0.6) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if len(data) >= 2 and isinstance(data[1], list):
                return [{
                    "action": "web",
                    "id": f"web_{item}",
                    "label": item,
                    "description": "Google Suggestion",
                    "query": item,
                    "icon": "󰖟"
                } for item in data[1][:max_results]]
    except Exception:
        pass
    return []

def main():
    if len(sys.argv) < 2:
        return
    query = sys.argv[1].strip()
    if not query:
        return

    # Always yield direct web query first
    print(json.dumps({
        "action": "web",
        "id": "web_direct",
        "label": f'Search Google for "{query}"',
        "description": "Open in Google Chrome",
        "query": query,
        "icon": "󰖟"
    }, ensure_ascii=False))

    # Chrome bookmarks matching query
    for bm in get_bookmarks(query, max_results=2):
        print(json.dumps(bm, ensure_ascii=False))

    # Google Autocomplete suggestions
    for sug in get_suggestions(query, max_results=4):
        print(json.dumps(sug, ensure_ascii=False))

if __name__ == "__main__":
    main()
