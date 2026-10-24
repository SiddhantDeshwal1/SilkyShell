#!/usr/bin/env python3
"""
Fast Internet Quick Search Backend for Quickshell Spotlight.
Provides instant answers, Wikipedia summaries, related web topics,
and Google suggestions with local caching and Chrome bookmarks integration.
Outputs line-delimited JSON for Quickshell SplitParser.
"""

import sys
import os
import json
import time
import urllib.request
import urllib.parse
import hashlib
import re
import html

CACHE_DIR = "/tmp/quickshell_web_cache"

def clean_text(text):
    if not text:
        return ""
    text = re.sub(r"\s+", " ", text).strip()
    return html.unescape(text)

def get_cached(cache_key, max_age_seconds=1800):
    try:
        cache_file = os.path.join(CACHE_DIR, f"{cache_key}.json")
        if os.path.exists(cache_file):
            with open(cache_file, "r", encoding="utf-8") as f:
                data = json.load(f)
                if time.time() - data.get("time", 0) < max_age_seconds:
                    return data.get("results", [])
    except Exception:
        pass
    return None

def save_cache(cache_key, results):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        cache_file = os.path.join(CACHE_DIR, f"{cache_key}.json")
        with open(cache_file, "w", encoding="utf-8") as f:
            json.dump({"time": time.time(), "results": results}, f)
    except Exception:
        pass

def get_bookmarks(query, max_results=1):
    path = os.path.expanduser("~/.config/google-chrome/Default/Bookmarks")
    if not os.path.exists(path):
        return []
    results = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        q = query.lower()
        def walk(node):
            if not isinstance(node, dict) or len(results) >= max_results:
                return
            if node.get("type") == "url":
                name = node.get("name", "")
                url = node.get("url", "")
                if q in name.lower() or q in url.lower():
                    domain = urllib.parse.urlparse(url).netloc.replace("www.", "")
                    desc = f"{domain} — Bookmark" if domain else url
                    results.append({
                        "action": "web",
                        "id": f"bm_{hashlib.md5(url.encode()).hexdigest()[:6]}",
                        "label": name or url,
                        "description": desc,
                        "query": url,
                        "icon": "󰃃",
                        "badge": "Bookmark",
                        "priority": 2
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

def get_ddg_instant(query, max_results=3):
    results = []
    try:
        api_url = f"https://api.duckduckgo.com/?q={urllib.parse.quote(query)}&format=json&no_html=1"
        req = urllib.request.Request(api_url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=1.4) as resp:
            data = json.loads(resp.read().decode("utf-8"))

        abstract_text = data.get("AbstractText", "").strip()
        abstract_url = data.get("AbstractURL", "").strip()
        heading = data.get("Heading", "").strip()

        if abstract_text and abstract_url:
            domain = urllib.parse.urlparse(abstract_url).netloc.replace("www.", "")
            snip = clean_text(abstract_text)
            if len(snip) > 85:
                snip = snip[:82] + "..."
            results.append({
                "action": "web",
                "id": f"web_instant_{hashlib.md5(abstract_url.encode()).hexdigest()[:6]}",
                "label": heading or query,
                "description": f"{domain} — {snip}",
                "query": abstract_url,
                "icon": "󰖟",
                "badge": "Web",
                "priority": 3
            })

        for rt in data.get("RelatedTopics", []):
            if len(results) >= max_results:
                break
            if isinstance(rt, dict) and "Text" in rt and "FirstURL" in rt:
                text = rt.get("Text", "")
                url = rt.get("FirstURL", "")
                if text and url:
                    parts = text.split(" - ", 1)
                    title = clean_text(parts[0]) if len(parts) > 1 else clean_text(text)
                    domain = urllib.parse.urlparse(url).netloc.replace("www.", "")
                    snip = clean_text(parts[1]) if len(parts) > 1 else domain
                    if len(snip) > 85:
                        snip = snip[:82] + "..."
                    results.append({
                        "action": "web",
                        "id": f"web_rt_{hashlib.md5(url.encode()).hexdigest()[:6]}",
                        "label": title,
                        "description": f"{domain} — {snip}",
                        "query": url,
                        "icon": "󰖟",
                        "badge": "Web",
                        "priority": 3
                    })
    except Exception:
        pass
    return results

def get_google_suggestions(query, max_results=3, existing_labels=None):
    results = []
    if existing_labels is None:
        existing_labels = set()
    try:
        url = f"https://suggestqueries.google.com/complete/search?client=chrome&q={urllib.parse.quote(query)}"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=1.1) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if len(data) >= 2 and isinstance(data[1], list):
                for item in data[1]:
                    if len(results) >= max_results:
                        break
                    clean_item = clean_text(item)
                    if clean_item.lower() == query.lower() or clean_item.lower() in existing_labels:
                        continue
                    results.append({
                        "action": "web",
                        "id": f"web_sug_{hashlib.md5(clean_item.encode()).hexdigest()[:6]}",
                        "label": clean_item,
                        "description": "Internet Suggestion",
                        "query": clean_item,
                        "icon": "󰍉",
                        "badge": "Web",
                        "priority": 3
                    })
    except Exception:
        pass
    return results

def main():
    if len(sys.argv) < 2:
        return
    query = ""
    max_res = 3

    if sys.argv[1] in ["search", "suggest"]:
        if len(sys.argv) > 2:
            query = sys.argv[2].strip()
        if len(sys.argv) > 3:
            try:
                max_res = int(sys.argv[3])
            except ValueError:
                pass
    else:
        query = sys.argv[1].strip()
        if len(sys.argv) > 2:
            try:
                max_res = int(sys.argv[2])
            except ValueError:
                pass

    if not query or len(query) < 2:
        return

    cache_key = hashlib.md5(f"quick_{query.lower()}_{max_res}".encode("utf-8")).hexdigest()
    cached = get_cached(cache_key)
    if cached is not None:
        for r in cached:
            print(json.dumps(r, ensure_ascii=False))
            sys.stdout.flush()
        return

    results = []
    seen_labels = set()

    # 1. Matching bookmarks (up to 1) — fast local lookup, do first
    for bm in get_bookmarks(query, max_results=1):
        bm["priority"] = 3
        results.append(bm)
        seen_labels.add(bm["label"].lower())

    # 2 + 3. DuckDuckGo Instant Answer and Google Suggestions — fetch concurrently
    import concurrent.futures
    remaining = max_res - len(results)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
        f_ddg = ex.submit(get_ddg_instant, query, 1)
        f_sug = ex.submit(get_google_suggestions, query, remaining, set(seen_labels))
        ddg_items = f_ddg.result()
        sug_items = f_sug.result()

    for item in ddg_items:
        if item["label"].lower() not in seen_labels:
            item["priority"] = 3
            results.append(item)
            seen_labels.add(item["label"].lower())
            break

    # Re-calculate remaining after DDG result
    remaining = max_res - len(results)
    for s in sug_items:
        if remaining <= 0:
            break
        if s["label"].lower() not in seen_labels:
            s["priority"] = 3
            results.append(s)
            seen_labels.add(s["label"].lower())
            remaining -= 1

    # Save to disk cache
    if results:
        save_cache(cache_key, results)

    for r in results:
        print(json.dumps(r, ensure_ascii=False))
        sys.stdout.flush()

if __name__ == "__main__":
    main()
