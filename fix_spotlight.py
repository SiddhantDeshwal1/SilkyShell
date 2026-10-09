import re

with open('/home/banana/.config/quickshell/modules/SpotlightBar.qml', 'r') as f:
    bar_code = f.read()

bar_code = bar_code.replace('import Qt5Compat.GraphicalEffects\nimport Quickshell', 'import Qt5Compat.GraphicalEffects\nimport Quickshell\nimport Quickshell.Io\nimport Quickshell.Wayland')

shortcuts_str = """
    property string activeFilter: ""
    property var shortcuts: [
        { id: "apps", icon: "󰕰", label: "Apps" },
        { id: "files", icon: "󰉋", label: "Files" },
        { id: "clipboard", icon: "󰈔", label: "Clipboard" },
        { id: "web", icon: "󰖟", label: "Web" }
    ]"""
bar_code = re.sub(r'property var shortcuts: \[\s*\{ id: "apps".*?\]', lambda m: shortcuts_str.strip(), bar_code, flags=re.DOTALL)

processes_str = r"""
    Timer {
        id: searchDebounce
        interval: 150
        onTriggered: root.doSearch()
    }
    
    Process {
        id: filesProcess
        stdout: SplitParser {
            onRead: function(line) {
                if (line.trim() !== "") {
                    let tmp = root.searchResults.slice();
                    let filename = line.split('/').pop();
                    tmp.push({ action: "command", id: "file_"+line, label: filename, description: line, icon: "󰈔", command: "xdg-open '" + line + "'" });
                    root.searchResults = tmp;
                }
            }
        }
    }
    
    Process {
        id: clipboardProcess
        stdout: SplitParser {
            onRead: function(line) {
                if (line.trim() !== "") {
                    let tmp = root.searchResults.slice();
                    let decoded = line.substring(line.indexOf('\t') + 1);
                    tmp.push({ action: "command", id: "clip_"+line, label: decoded, description: "Clipboard", icon: "󰅌", command: "echo -n '" + line.split('\t')[0] + "' | cliphist decode | wl-copy" });
                    root.searchResults = tmp;
                }
            }
        }
    }

    function doSearch() {
        let q = searchValue.trim();
        if (q === "") return;
        let res = [];
        if (q.startsWith(">")) {
            let cmd = q.substring(1).trim();
            if (cmd.length > 0) res.push({ action: "command", id: "cmd", label: cmd, description: "Run Command", icon: "󰆍", command: cmd });
            searchResults = res; return;
        }
        try {
            if (/^[\d\s\+\-\*\/\(\)\.]+$/.test(q) && q.match(/[\+\-\*\/]/)) {
                let result = eval(q);
                if (result !== undefined && !isNaN(result)) res.push({ action: "none", id: "math", label: String(result), description: "Calculator", icon: "󰪚" });
            }
        } catch(e) {}
        
        let lowerQ = q.toLowerCase();
        let filter = root.activeFilter;
        
        if (filter === "Apps" || filter === "") {
            let apps = DesktopEntries.applications.values;
            let matchedApps = [];
            for (let i = 0; i < apps.length; i++) {
                let app = apps[i];
                if (app.name.toLowerCase().indexOf(lowerQ) !== -1) {
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
                res.push({ action: "app", id: app.id, label: app.name, description: app.comment || "Application", iconPath: Quickshell.iconPath(app.icon, true) || "", appRef: app });
            }
        }
        
        if (filter === "Web" || (filter === "" && res.length === 0)) {
            res.push({ action: "web", id: "web", label: `Search Web for "${q}"`, description: "Browser", icon: "󰖟", query: q });
        }
        searchResults = res;
        
        if (filter === "Files" || filter === "") {
            filesProcess.running = false;
            let safeQ = q.replace(/"/g, '\\"');
            filesProcess.command = ["sh", "-c", 'fd -i "' + safeQ + '" /home/banana -m 10'];
            filesProcess.running = true;
        }
        
        if (filter === "Clipboard" || filter === "") {
            clipboardProcess.running = false;
            let safeQ = q.replace(/"/g, '\\"');
            clipboardProcess.command = ["sh", "-c", 'cliphist list | grep -i "' + safeQ + '" | head -n 10'];
            clipboardProcess.running = true;
        }
    }
"""

on_search_val_changed_str = """
    onSearchValueChanged: {
        if (!searchValue || searchValue.trim() === "") {
            searchResults = [];
            filesProcess.running = false;
            clipboardProcess.running = false;
            return;
        }
        searchDebounce.restart();
    }
"""

bar_code = re.sub(r'onSearchValueChanged: \{.*?\n    \}', lambda m: on_search_val_changed_str.strip() + '\n' + processes_str, bar_code, flags=re.DOTALL)


bar_code = bar_code.replace('width: root.width', 'width: root.contentWidth')
bar_code = bar_code.replace('width: root.width -', 'width: root.contentWidth -')
bar_code = bar_code.replace('property int contentWidth: 768\n    width: contentWidth + (padding * 2)', 'property int contentWidth: 768\n    width: contentWidth + (padding * 2)')
bar_code = bar_code.replace('height: searchBarContainer.height\n\n    opacity:', 'height: searchBarContainer.height + (padding * 2)\n\n    opacity:')
bar_code = bar_code.replace('width: parent.width + (padding * 2)\n        height: parent.height + (padding * 2)\n        x: -padding\n        y: -padding', 'width: parent.width\n        height: parent.height\n        x: 0\n        y: 0')


text_input_replace = r"""
                        Text {
                            id: placeholderText
                            anchors.verticalCenter: parent.verticalCenter
                            
                            text: {
                                if (root.hoveredShortcut >= 0) return "Search " + root.shortcuts[root.hoveredShortcut].label;
                                if (root.hoveredResult >= 0 && root.searchValue !== "") return "Open " + resultsContainer.results[root.hoveredResult].label;
                                return "Search";
                            }
                            
                            color: (root.hoveredResult >= 0 && root.searchValue !== "") ? "#000000" : "#6b7280"
                            font.family: "SF Pro Text"
                            font.pixelSize: 24
                            
                            opacity: (root.searchValue.length === 0 || root.hoveredResult >= 0 || root.hoveredShortcut >= 0) ? 1.0 : 0.0
                            
                            layer.enabled: true
                            layer.effect: Component {
                                FastBlur {
                                    radius: placeholderText.opacity < 1.0 ? 5 : 0
                                    transparentBorder: true
                                }
                            }

                            Behavior on text {
                                SequentialAnimation {
                                    ParallelAnimation {
                                        NumberAnimation { target: placeholderText; property: "y"; to: -10; duration: 200; easing.type: Easing.OutQuad }
                                        NumberAnimation { target: placeholderText; property: "opacity"; to: 0; duration: 200; easing.type: Easing.OutQuad }
                                    }
                                    PropertyAction { target: placeholderText; property: "y"; value: 10 }
                                    PropertyAction { target: placeholderText; property: "text" }
                                    ParallelAnimation {
                                        NumberAnimation { target: placeholderText; property: "y"; to: (searchInput.height - placeholderText.height)/2; duration: 200; easing.type: Easing.OutQuad }
                                        NumberAnimation { target: placeholderText; property: "opacity"; to: 1; duration: 200; easing.type: Easing.OutQuad }
                                    }
                                }
                            }
                        }

                        TextInput {
                            id: textInput
                            anchors.fill: parent
                            verticalAlignment: TextInput.AlignVCenter
                            font.family: "SF Pro Text"
                            font.pixelSize: 24
                            color: "#000000"
                            opacity: text.length > 0 && root.hoveredResult < 0 ? 1.0 : 0.0
                            onTextChanged: root.searchValue = text
                            Keys.onEscapePressed: root.closeRequested()
                            Keys.onUpPressed: {
                                if (root.searchResults.length > 0) {
                                    root.hoveredResult = root.hoveredResult <= 0 ? root.searchResults.length - 1 : root.hoveredResult - 1;
                                }
                            }
                            Keys.onDownPressed: {
                                if (root.searchResults.length > 0) {
                                    root.hoveredResult = root.hoveredResult >= root.searchResults.length - 1 ? 0 : root.hoveredResult + 1;
                                }
                            }
                            Keys.onReturnPressed: {
                                if (root.hoveredResult >= 0 && root.hoveredResult < root.searchResults.length) {
                                    resultsContainer.resultClicked(root.searchResults[root.hoveredResult]);
                                } else if (root.searchResults.length > 0) {
                                    resultsContainer.resultClicked(root.searchResults[0]);
                                }
                            }
                        }
"""
bar_code = re.sub(r'Text \{\n\s*id: placeholderText.*Keys\.onEscapePressed: root\.closeRequested\(\)\n\s*\}', lambda m: text_input_replace.strip(), bar_code, flags=re.DOTALL)

shortcut_clicked_replace = r"""
                            onClicked: {
                                if (root.activeFilter === modelData.label) {
                                    root.activeFilter = "";
                                } else {
                                    root.activeFilter = modelData.label;
                                }
                                root.doSearch();
                                focusTimer.start();
                            }
"""
bar_code = re.sub(r'onClicked: \{.*?root\.closeRequested\(\);\n\s*\}', lambda m: shortcut_clicked_replace.strip(), bar_code, flags=re.DOTALL)

bar_code = bar_code.replace('color: "transparent"\n                        \n                        property real startX:', 'color: root.activeFilter === modelData.label ? "#e5e5e5" : "transparent"\n                        \n                        property real startX:')

with open('/home/banana/.config/quickshell/modules/SpotlightBar.qml', 'w') as f:
    f.write(bar_code)

with open('/home/banana/.config/quickshell/modules/SpotlightResults.qml', 'r') as f:
    res_code = f.read()

res_code = res_code.replace('Layout.preferredWidth: 32 // size-8\n                            Layout.preferredHeight: 32\n                            radius: 8', 'Layout.preferredWidth: 48\n                            Layout.preferredHeight: 48\n                            radius: 12')

with open('/home/banana/.config/quickshell/modules/SpotlightResults.qml', 'w') as f:
    f.write(res_code)

