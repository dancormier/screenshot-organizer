#!/bin/zsh

PLIST_NAME="com.screenshot-organizer.plist"
LABEL="com.screenshot-organizer"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"
SERVICE_TARGET="gui/$(id -u)/$LABEL"

# Unload agent
launchctl bootout "$SERVICE_TARGET" 2>/dev/null
echo "Agent unloaded."

# Remove symlink
if [[ -L "$PLIST_DST" || -f "$PLIST_DST" ]]; then
    rm "$PLIST_DST"
    echo "Removed $PLIST_DST"
else
    echo "No plist found at $PLIST_DST"
fi

echo "Screenshot organizer uninstalled."
echo ""
echo "Config preserved at ~/.config/screenshot-organizer/config"
echo "  (delete manually if no longer needed)"
