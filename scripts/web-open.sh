#!/usr/bin/env bash
# Web search and URL opener with Hyprland workspace focus for Google Chrome.
# Safely detaches from parent process and shifts Hyprland workspace to the opened tab.

TARGET="$1"
if [ -z "$TARGET" ]; then
    exit 0
fi

if [[ "$TARGET" =~ ^[a-zA-Z0-9+.-]+:// ]]; then
    URL="$TARGET"
elif [[ "$TARGET" =~ ^localhost(:[0-9]+)?(/.*)?$ ]] || [[ "$TARGET" =~ ^127\.0\.0\.1(:[0-9]+)?(/.*)?$ ]] || [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?(/.*)?$ ]]; then
    URL="http://$TARGET"
elif [[ "$TARGET" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(:[0-9]+)?(/.*)?$ ]]; then
    URL="https://$TARGET"
else
    ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$TARGET")
    URL="https://www.google.com/search?q=$ENCODED"
fi

# Launch or send URL to Chrome in detached session
setsid -f google-chrome-stable "$URL" >/dev/null 2>&1

# In background: allow Chrome to open the tab and Spotlight to dismiss layershell focus,
# then shift the active workspace to the window containing the opened tab.
(
    python3 -c '
import sys, json, subprocess, time

target = sys.argv[1].strip() if len(sys.argv) > 1 else ""
url = sys.argv[2].strip() if len(sys.argv) > 2 else ""

# Clean query words for title matching
clean_q = target.replace("https://", "").replace("http://", "").lower()
words = [w for w in clean_q.split() if len(w) > 2]
q_lua = json.dumps(clean_q)
first_word_lua = json.dumps(words[0]) if words else q_lua

# Initial small delay to let Spotlight layershell drop exclusive focus grab
time.sleep(0.05)

found = False
for attempt in range(25):
    # Method 1: Check urgent window (Chrome signals activation via Wayland urgent)
    lua_urgent = """
    local u = hl.get_urgent_window()
    if u and u.class == "google-chrome" then
        hl.dispatch(hl.dsp.focus({ workspace = u.workspace }))
        hl.dispatch(hl.dsp.focus({ window = u }))
        return "urgent"
    end
    return "none"
    """
    res = subprocess.run(["hyprctl", "repl", lua_urgent], capture_output=True, text=True)
    if "urgent" in res.stdout:
        found = True
        break

    # Method 2: Check window titles for query or keywords
    if clean_q and len(clean_q) > 2:
        lua_title = f"""
        local q = {q_lua}
        local w1 = {first_word_lua}
        for _, w in ipairs(hl.get_windows()) do
            if w.class == "google-chrome" then
                local t = string.lower(w.title)
                if string.find(t, q, 1, true) or string.find(t, w1, 1, true) then
                    hl.dispatch(hl.dsp.focus({{ workspace = w.workspace }}))
                    hl.dispatch(hl.dsp.focus({{ window = w }}))
                    return "title"
                end
            end
        end
        return "none"
        """
        res2 = subprocess.run(["hyprctl", "repl", lua_title], capture_output=True, text=True)
        if "title" in res2.stdout:
            found = True
            break

    time.sleep(0.06)

# Method 3 fallback: Focus most recently focused Chrome window
if not found:
    lua_fallback = """
    for _, w in ipairs(hl.get_windows()) do
        if w.class == "google-chrome" then
            hl.dispatch(hl.dsp.focus({ workspace = w.workspace }))
            hl.dispatch(hl.dsp.focus({ window = w }))
            return "fallback"
        end
    end
    return "none"
    """
    subprocess.run(["hyprctl", "repl", lua_fallback], capture_output=True)
' "$TARGET" "$URL"
) >/dev/null 2>&1 &
