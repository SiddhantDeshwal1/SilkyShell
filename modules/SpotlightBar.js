function doSearch(query, apps) {
    if (!query || query.trim() === "") return [];
    
    let q = query.trim();
    let res = [];
    
    // Command
    if (q.startsWith(">")) {
        let cmd = q.substring(1).trim();
        if (cmd.length > 0) {
            res.push({
                id: "cmd",
                label: cmd,
                description: "Run Command",
                icon: "󰆍",
                action: "command",
                command: cmd
            });
        }
        return res;
    }
    
    // Math eval
    if (/^[\d\s\+\-\*\/\(\)\.]+$/.test(q) && q.match(/[\+\-\*\/]/)) {
        try {
            let result = eval(q);
            if (result !== undefined && !isNaN(result)) {
                res.push({
                    id: "math",
                    label: String(result),
                    description: "Calculator",
                    icon: "󰪚",
                    action: "none"
                });
            }
        } catch(e) {}
    }
    
    // Desktop Apps
    let lowerQ = q.toLowerCase();
    let matchedApps = []; console.log("Searching in apps:", apps.length);
    
    for (let i = 0; i < apps.length; i++) {
        let app = apps[i];
        if (app.name.toLowerCase().indexOf(lowerQ) !== -1 || (app.comment && app.comment.toLowerCase().indexOf(lowerQ) !== -1)) {
            matchedApps.push(app);
        }
    }
    
    matchedApps.sort((a, b) => {
        let aScore = a.name.toLowerCase().startsWith(lowerQ) ? 1 : 0;
        let bScore = b.name.toLowerCase().startsWith(lowerQ) ? 1 : 0;
        if (aScore !== bScore) return bScore - aScore;
        return a.name.localeCompare(b.name);
    });
    
    for (let i = 0; i < Math.min(matchedApps.length, 10); i++) {
        let app = matchedApps[i];
        res.push({
            id: app.id,
            label: app.name,
            description: app.comment || "Application",
            iconPath: Quickshell.iconPath(app.icon, true) || "",
            action: "app",
            appRef: app
        });
    }
    
    // Fallback Web Search
    if (res.length === 0) {
        res.push({
            id: "web",
            label: `Search Web for "${q}"`,
            description: "Browser",
            icon: "󰖟",
            action: "web",
            query: q
        });
    }
    
    return res;
}
