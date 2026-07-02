#!/bin/bash
# CaffBar.spoon Installer

set -e

SPOON_DIR="$HOME/.hammerspoon/Spoons"
INIT_FILE="$HOME/.hammerspoon/init.lua"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
START_MARKER="-- BEGIN CaffBar auto-start"
END_MARKER="-- END CaffBar auto-start"

echo "Installing CaffBar.spoon..."

# Create Hammerspoon directories if they don't exist
mkdir -p "$SPOON_DIR"
mkdir -p "$(dirname "$INIT_FILE")"

# Copy the Spoon
mkdir -p "$SPOON_DIR/CaffBar.spoon"
cp -R "$SCRIPT_DIR/CaffBar.spoon/" "$SPOON_DIR/CaffBar.spoon/"

echo "✅ Installed to $SPOON_DIR/CaffBar.spoon"
echo ""

touch "$INIT_FILE"
existing_max_prevention="$(
    awk '
        /^[[:space:]]*spoon\.(CaffBar|AntiSleep)\.maxPreventionMinutes[[:space:]]*=/ {
            gsub(/spoon\.AntiSleep\./, "spoon.CaffBar.")
            sub(/^[[:space:]]+/, "")
            print
            exit
        }
    ' "$INIT_FILE"
)"
tmp_file="$(mktemp)"
awk -v start="$START_MARKER" -v end="$END_MARKER" '
    /^-- ============================================$/ {
        pending_separator = $0
        next
    }
    pending_separator && /^-- AntiSleep Spoon$/ {
        skip_legacy_header = 1
        pending_separator = ""
        next
    }
    pending_separator {
        print pending_separator
        pending_separator = ""
    }
    skip_legacy_header && /^-- Toggle: Shift \+ Cmd \+ K$/ { next }
    skip_legacy_header && /^-- ============================================$/ {
        skip_legacy_header = 0
        next
    }
    $0 == start { skip = 1; next }
    $0 == end { skip = 0; next }
    /^hs\.loadSpoon\("CaffBar"\)$/ { next }
    /^spoon\.CaffBar\./ { next }
    /^spoon\.CaffBar:/ { next }
    /^hs\.loadSpoon\("AntiSleep"\)$/ { next }
    /^spoon\.AntiSleep\./ { next }
    /^spoon\.AntiSleep:/ { next }
    !skip { print }
    END {
        if (pending_separator) {
            print pending_separator
        }
    }
' "$INIT_FILE" > "$tmp_file"
mv "$tmp_file" "$INIT_FILE"

cat >> "$INIT_FILE" <<'LUA'

-- BEGIN CaffBar auto-start
hs.autoLaunch(true)
hs.loadSpoon("CaffBar")
spoon.CaffBar.showMenubar = true
LUA

if [ -n "$existing_max_prevention" ]; then
    printf '%s\n' "$existing_max_prevention" >> "$INIT_FILE"
fi

cat >> "$INIT_FILE" <<'LUA'
spoon.CaffBar:bindHotkeys({toggle = {{"shift", "cmd"}, "k"}})
spoon.CaffBar:startMode("smart")
-- END CaffBar auto-start
LUA

echo "Updated $INIT_FILE"
echo "CaffBar will launch with Hammerspoon at login and start in Smart Awake mode."
echo "Reload Hammerspoon to apply now (Shift+Cmd+R or click icon → Reload Config)."
