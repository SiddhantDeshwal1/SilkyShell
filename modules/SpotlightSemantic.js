.pragma library

// Semantic concept knowledge base
const CONCEPTS = [
    {
        id: "video_editing",
        triggers: ["video edit", "video editor", "video editing", "movie editor", "edit video", "render video", "cut video", "montage", "clip cutter", "video cut"],
        tags: ["video", "movie", "film", "clip", "timeline", "montage", "vfx", "render", "color grading", "color correction", "visual effects", "post production", "audiovideoediting", "video editor", "video editing"],
        apps: ["kdenlive", "davinciresolve", "resolve", "obs", "studio", "com.obsproject.studio", "shotcut", "openshot", "pitivi", "blender", "flowblade", "cinelerra"]
    },
    {
        id: "video_general",
        triggers: ["video", "movie", "movies", "film", "films", "cinema"],
        tags: ["video", "movie", "film", "player", "tv", "audiovideo", "recorder", "playback"],
        apps: ["kdenlive", "davinciresolve", "obs", "vlc", "mpv", "jellyfin"]
    },
    {
        id: "screen_recording",
        triggers: ["screen record", "screen recording", "record screen", "recording", "recorder", "stream", "streaming", "broadcast", "screencast"],
        tags: ["recorder", "recording", "stream", "streaming", "broadcast", "capture", "screencast", "screen", "audiovideo"],
        apps: ["obs", "studio", "scrcpy", "qvidcap", "satty", "swappy", "wf-recorder"]
    },
    {
        id: "photo_editing",
        triggers: ["photo", "photo editor", "photo editing", "image editor", "photoshop", "picture edit", "raw editor", "paint", "drawing", "illustration", "vector", "raster"],
        tags: ["photo", "image", "picture", "raster", "vector", "drawing", "paint", "raw", "graphics", "photo editor", "image editor", "darkroom", "lighttable", "filters"],
        apps: ["darktable", "gimp", "krita", "imv", "waypaper", "gmic", "gmic_qt", "inkscape", "draw"]
    },
    {
        id: "browser",
        triggers: ["browser", "web", "internet", "surf", "chrome", "web browser", "google", "online"],
        tags: ["browser", "web", "internet", "surf", "html", "webbrowser", "network"],
        apps: ["google-chrome", "brave-browser", "brave", "firefox", "zen", "librewolf", "tor-browser", "vivaldi", "chromium", "edge"]
    },
    {
        id: "music",
        triggers: ["music", "songs", "song", "audio player", "listen music", "spotify", "playlist", "track", "tunes"],
        tags: ["music", "song", "songs", "audio", "sound", "track", "tunes", "listen", "playlist", "playback", "player"],
        apps: ["spotify", "sidra", "sh.cider.cider", "cider", "mpv", "vlc", "blanket", "jellyfin", "rhythmbox"]
    },
    {
        id: "audio_control",
        triggers: ["volume", "sound", "audio", "mic", "microphone", "speaker", "equalizer", "mixer", "dsp", "effects"],
        tags: ["volume", "mixer", "sound", "audio", "equalizer", "mic", "microphone", "speaker", "pipewire", "pulseaudio", "effects"],
        apps: ["easyeffects", "pwvucontrol", "pavucontrol", "blueman", "alsamixer"]
    },
    {
        id: "terminal",
        triggers: ["terminal", "shell", "console", "cli", "command prompt", "bash", "zsh"],
        tags: ["terminal", "shell", "console", "cli", "command", "bash", "zsh", "prompt"],
        apps: ["kitty", "foot", "footclient", "alacritty", "wezterm", "gnome-terminal", "konsole"]
    },
    {
        id: "code",
        triggers: ["code", "coding", "editor", "ide", "programming", "developer", "development", "syntax", "git"],
        tags: ["code", "coding", "editor", "ide", "programming", "developer", "development", "syntax", "text", "git"],
        apps: ["nvim", "vim", "micro", "antigravity", "vscode", "code", "sublime", "kate", "emacs"]
    },
    {
        id: "notes",
        triggers: ["notes", "note", "notebook", "memo", "markdown", "journal", "todo", "tasks", "task"],
        tags: ["notes", "notebook", "memo", "markdown", "journal", "todo", "task", "tasks", "wiki"],
        apps: ["obsidian", "todoist", "notion", "logseq", "joplin"]
    },
    {
        id: "office",
        triggers: ["office", "document", "documents", "docs", "word", "excel", "sheet", "spreadsheet", "presentation", "slides", "powerpoint", "pdf", "reader"],
        tags: ["office", "document", "docs", "word", "excel", "sheet", "spreadsheet", "presentation", "slides", "pdf", "reader", "formula", "math"],
        apps: ["libreoffice", "writer", "calc", "impress", "math", "foliate", "calibre", "evince", "okular"]
    },
    {
        id: "files",
        triggers: ["file", "files", "folder", "folders", "explorer", "directory", "storage"],
        tags: ["files", "file", "folder", "folders", "explorer", "directory", "storage"],
        apps: ["thunar", "pcmanfm", "yazi", "dolphin", "nautilus"]
    },
    {
        id: "settings",
        triggers: ["settings", "preferences", "config", "configuration", "control panel", "system settings"],
        tags: ["settings", "preferences", "config", "configuration", "control", "system", "appearance", "display", "bluetooth", "network"],
        apps: ["kcm_", "systemsettings", "tweaks", "lxappearance", "nwg-look", "btrfs-assistant", "blueman"]
    },
    {
        id: "chat",
        triggers: ["chat", "messenger", "message", "messaging", "social", "communication", "call", "voice", "video call"],
        tags: ["chat", "messenger", "message", "messaging", "social", "communication", "call", "voice", "telephony"],
        apps: ["telegram", "equibop", "discord", "zoom", "slack", "signal", "element", "kdeconnect"]
    },
    {
        id: "games",
        triggers: ["game", "games", "gaming", "play", "steam", "gamer"],
        tags: ["game", "gaming", "play", "gamer", "games", "steam", "launcher"],
        apps: ["steam", "combat master", "kuboom", "night-runners", "super sus", "the sims", "sunshine"]
    }
];

function getStem(word) {
    if (!word || word.length <= 3) return word;
    if (word.endsWith("ing") && word.length > 5) return word.slice(0, -3);
    if (word.endsWith("ed") && word.length > 4) return word.slice(0, -2);
    if (word.endsWith("es") && word.length > 4) return word.slice(0, -2);
    if (word.endsWith("s") && word.length > 3) return word.slice(0, -1);
    if (word.endsWith("er") && word.length > 4) return word.slice(0, -2);
    if (word.endsWith("or") && word.length > 4) return word.slice(0, -2);
    return word;
}

function matchTarget(target, appId, appName) {
    let aid = String(appId || "").toLowerCase();
    let name = String(appName || "").toLowerCase();
    let t = target.toLowerCase().replace(/[\s\-_]/g, "");
    if (t === aid.replace(/[\s\-_]/g, "") || t === name.replace(/[\s\-_]/g, "")) return true;
    let parts = aid.split(/[\.\-_]/);
    if (parts.indexOf(target.toLowerCase()) !== -1) return true;
    let nameWords = name.split(/[\s\-_]/);
    if (nameWords.indexOf(target.toLowerCase()) !== -1) return true;
    return false;
}

function triggerMatches(query, trigger) {
    if (!query || !trigger) return false;
    let q = query.toLowerCase();
    let tr = trigger.toLowerCase();
    if (tr.length <= 4) {
        let re = new RegExp("(^|\\s)" + tr.replace(/[.*+?^${}()|[\\]\\\\]/g, "\\\\$&") + "($|\\s)");
        return re.test(q);
    }
    return q.indexOf(tr) !== -1;
}

function checkNameMatch(q, name, aid) {
    if (!q || !name) return 0;
    let nameClean = String(name).toLowerCase().trim();
    let qClean = String(q).toLowerCase().trim();
    let aidClean = String(aid || "").toLowerCase().trim();

    if (nameClean === qClean) return 3000;
    if (nameClean.startsWith(qClean)) return 2500;

    let reWord = new RegExp("(^|[\\s\\-_])" + qClean.replace(/[.*+?^${}()|[\\]\\\\]/g, "\\\\$&"), "i");
    if (reWord.test(nameClean)) return 2000;
    if (nameClean.indexOf(qClean) !== -1) return 1500;

    let tokens = qClean.split(/\s+/).filter(function(t) { return t.length > 0; });
    if (tokens.length > 1) {
        let allInName = true;
        for (let i = 0; i < tokens.length; i++) {
            if (nameClean.indexOf(tokens[i]) === -1) {
                allInName = false;
                break;
            }
        }
        if (allInName) return 1400;
    }

    if (aidClean === qClean || aidClean.startsWith(qClean)) return 1200;
    if (aidClean.indexOf("." + qClean) !== -1 || aidClean.indexOf("-" + qClean) !== -1) return 1000;

    return 0;
}

function searchApps(query, appsList, maxNameResults, maxSemanticResults) {
    if (!query || query.trim() === "" || !appsList || appsList.length === 0) {
        return [];
    }
    let limitName = maxNameResults !== undefined ? maxNameResults : 4;
    let limitSemantic = maxSemanticResults !== undefined ? maxSemanticResults : 4;

    let q = query.trim().toLowerCase();
    let tokens = q.split(/\s+/).filter(function(t) { return t.length > 0; });
    if (tokens.length === 0) return [];

    let nameMatches = [];
    let seenAppIds = {};

    // 1. FIRST: Check direct name matches
    for (let i = 0; i < appsList.length; i++) {
        let app = appsList[i];
        if (!app || !app.name || app.noDisplay) continue;

        let nameScore = checkNameMatch(q, app.name, app.id);
        if (nameScore > 0) {
            seenAppIds[app.id] = true;
            let desc = app.genericName;
            if (!desc || desc === app.name) {
                desc = app.comment;
            } else if (app.comment && app.comment.length > 0 && app.comment !== app.genericName) {
                desc = app.genericName + " • " + app.comment;
            }
            if (!desc || desc.trim() === "") desc = "Application";

            nameMatches.push({
                matchType: "name",
                priority: 1,
                badge: "App",
                score: nameScore,
                app: app,
                description: desc
            });
        }
    }

    nameMatches.sort(function(a, b) {
        if (b.score !== a.score) return b.score - a.score;
        return (a.app.name || "").localeCompare(b.app.name || "");
    });

    let topNameMatches = nameMatches.slice(0, limitName);

    // 2. SECOND: Semantic matches
    let matchedConcepts = [];
    for (let c = 0; c < CONCEPTS.length; c++) {
        let concept = CONCEPTS[c];
        let hasTrigger = false;
        for (let tr = 0; tr < concept.triggers.length; tr++) {
            if (triggerMatches(q, concept.triggers[tr])) {
                hasTrigger = true;
                break;
            }
        }
        if (hasTrigger) {
            matchedConcepts.push(concept);
        }
    }

    let semanticMatches = [];

    for (let j = 0; j < appsList.length; j++) {
        let app = appsList[j];
        if (!app || !app.name || app.noDisplay) continue;
        if (seenAppIds[app.id]) continue; // Already in direct name matches!

        let name = String(app.name || "").toLowerCase();
        let generic = String(app.genericName || "").toLowerCase();
        let comment = String(app.comment || "").toLowerCase();
        let aid = String(app.id || "").toLowerCase();
        let catStr = (Array.isArray(app.categories) ? app.categories.join(" ") : String(app.categories || "")).toLowerCase();
        let kwStr = (Array.isArray(app.keywords) ? app.keywords.join(" ") : String(app.keywords || "")).toLowerCase();
        let execStr = String(app.command || app.execString || "").toLowerCase();

        let score = 0;

        // Concept boost
        let isConceptMatch = false;
        for (let c = 0; c < matchedConcepts.length; c++) {
            let concept = matchedConcepts[c];
            let hasAppTargetMatch = false;
            for (let tg = 0; tg < concept.apps.length; tg++) {
                if (!hasAppTargetMatch && matchTarget(concept.apps[tg], app.id, app.name)) {
                    score += 1500;
                    hasAppTargetMatch = true;
                    isConceptMatch = true;
                }
            }
            for (let tagIdx = 0; tagIdx < concept.tags.length; tagIdx++) {
                let tag = concept.tags[tagIdx];
                if (generic.indexOf(tag) !== -1) {
                    score += 220;
                    isConceptMatch = true;
                } else if (comment.indexOf(tag) !== -1) {
                    score += 140;
                    isConceptMatch = true;
                } else if (catStr.indexOf(tag) !== -1 || kwStr.indexOf(tag) !== -1) {
                    score += 160;
                    isConceptMatch = true;
                }
            }
        }

        // Generic / Comment / Categories direct query matches
        if (generic.indexOf(q) !== -1) { score += 800; isConceptMatch = true; }
        if (comment.indexOf(q) !== -1) { score += 500; isConceptMatch = true; }
        if (catStr.indexOf(q) !== -1 || kwStr.indexOf(q) !== -1) { score += 500; isConceptMatch = true; }

        // Token matches across fields
        let tokensMatched = 0;
        for (let tIdx = 0; tIdx < tokens.length; tIdx++) {
            let t = tokens[tIdx];
            let stem = getStem(t);
            let matchedToken = false;

            if (generic.indexOf(t) !== -1 || (stem.length >= 3 && generic.indexOf(stem) !== -1)) {
                score += 250;
                matchedToken = true;
            }
            if (kwStr.indexOf(t) !== -1 || (stem.length >= 3 && kwStr.indexOf(stem) !== -1) || catStr.indexOf(t) !== -1) {
                score += 200;
                matchedToken = true;
            }
            if (comment.indexOf(t) !== -1 || (stem.length >= 3 && comment.indexOf(stem) !== -1)) {
                score += 160;
                matchedToken = true;
            }
            if (aid.indexOf(t) !== -1 || execStr.indexOf(t) !== -1) {
                score += 100;
                matchedToken = true;
            }

            if (matchedToken) tokensMatched++;
        }

        // Multi-word filtering
        if (tokens.length > 1) {
            if (tokensMatched === tokens.length) {
                score += 600;
            } else if (!isConceptMatch) {
                continue;
            }
        }

        if (score > 200) {
            let desc = app.genericName;
            if (!desc || desc === app.name) {
                desc = app.comment;
            } else if (app.comment && app.comment.length > 0 && app.comment !== app.genericName) {
                desc = app.genericName + " • " + app.comment;
            }
            if (!desc || desc.trim() === "") desc = "Related Application";

            semanticMatches.push({
                matchType: "semantic",
                priority: 2,
                badge: "Related",
                score: score,
                app: app,
                description: desc
            });
        }
    }

    semanticMatches.sort(function(a, b) {
        if (b.score !== a.score) return b.score - a.score;
        return (a.app.name || "").localeCompare(b.app.name || "");
    });

    let topSemanticMatches = semanticMatches.slice(0, limitSemantic);

    return topNameMatches.concat(topSemanticMatches);
}
