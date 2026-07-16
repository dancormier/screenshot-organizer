#!/bin/zsh

PLIST_NAME="com.screenshot-organizer.plist"
LABEL="com.screenshot-organizer"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"
SERVICE_TARGET="gui/$(id -u)/$LABEL"

# Unload agent
launchctl bootout "$SERVICE_TARGET" 2>/dev/null
echo "Agent unloaded."

# Remove plist (regular file; older installs used a symlink)
if [[ -L "$PLIST_DST" || -f "$PLIST_DST" ]]; then
    rm "$PLIST_DST"
    echo "Removed $PLIST_DST"
else
    echo "No plist found at $PLIST_DST"
fi

# Offer to re-enable screenshot thumbnail
current_thumbnail="$(defaults read com.apple.screencapture show-thumbnail 2>/dev/null)"
if [[ "$current_thumbnail" == "0" ]]; then
    echo ""
    printf "Re-enable macOS screenshot thumbnail preview? [Y/n]: "
    read -r response
    case "$response" in
        [nN]*)
            echo "  Screenshot thumbnail left disabled."
            ;;
        *)
            defaults write com.apple.screencapture show-thumbnail -bool true
            echo "  Screenshot thumbnail re-enabled."
            ;;
    esac
fi

echo ""
echo "Screenshot organizer uninstalled."
echo ""
echo "Config preserved at ~/.config/screenshot-organizer/config"
echo "  (delete manually if no longer needed)"
