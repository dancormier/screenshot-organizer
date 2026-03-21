#!/bin/zsh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$HOME/.config/screenshot-organizer"
CONFIG_FILE="$CONFIG_DIR/config"
PLIST_NAME="com.screenshot-organizer.plist"
LABEL="com.screenshot-organizer"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"
DOMAIN_TARGET="gui/$(id -u)"
SERVICE_TARGET="$DOMAIN_TARGET/$LABEL"

# Check for fswatch
if ! command -v fswatch &>/dev/null; then
    echo "fswatch is required but not installed."
    echo "Install it with: brew install fswatch"
    exit 1
fi

# Interactive config setup (first run or reconfigure)
if [[ ! -f "$CONFIG_FILE" || "$1" == "--reconfigure" ]]; then
    echo "Screenshot Organizer Setup"
    echo "=========================="
    echo ""

    # Watch directory
    default_watch_dir="$HOME/Desktop"
    # Try to detect macOS screenshot location
    custom_loc="$(defaults read com.apple.screencapture location 2>/dev/null)"
    if [[ -n "$custom_loc" && -d "$custom_loc" ]]; then
        default_watch_dir="$custom_loc"
    fi
    echo "Which directory should be watched for screenshots?"
    printf "  [%s]: " "$default_watch_dir"
    read watch_dir
    watch_dir="${watch_dir:-$default_watch_dir}"
    # Expand ~ if used
    watch_dir="${watch_dir/#\~/$HOME}"

    if [[ ! -d "$watch_dir" ]]; then
        echo "ERROR: Directory not found: $watch_dir"
        exit 1
    fi

    # Rename files
    printf "Rename screenshots to YYYYMMDD-HHMMSS format? [Y/n]: "
    read rename_enabled
    case "$rename_enabled" in
        [nN]*) rename_enabled=false ;;
        *) rename_enabled=true ;;
    esac

    # Keep count
    printf "How many recent images to keep in the root folder? [20]: "
    read keep_count
    keep_count="${keep_count:-20}"

    # Settle delay
    printf "Settle delay in seconds before processing (0.5 is usually fine)? [0.5]: "
    read settle_delay
    settle_delay="${settle_delay:-0.5}"

    # Save config
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
WATCH_DIR="$watch_dir"
RENAME_ENABLED=$rename_enabled
KEEP_COUNT=$keep_count
SETTLE_DELAY=$settle_delay
EOF

    echo ""
    echo "Config saved to $CONFIG_FILE"
else
    echo "Using existing config at $CONFIG_FILE"
    echo "  (run with --reconfigure to change settings)"
fi

echo ""

# Generate plist with correct paths
cat > "$SCRIPT_DIR/$PLIST_NAME" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SCRIPT_DIR/screenshot-organizer.sh</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/screenshot-organizer.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/screenshot-organizer.log</string>
</dict>
</plist>
EOF

# Symlink plist
if [[ -L "$PLIST_DST" || -f "$PLIST_DST" ]]; then
    echo "Plist already exists at $PLIST_DST — updating symlink."
    rm "$PLIST_DST"
fi
ln -s "$SCRIPT_DIR/$PLIST_NAME" "$PLIST_DST"
echo "Symlinked plist to $PLIST_DST"

# Load agent (bootout first if already loaded, ignore errors)
launchctl bootout "$SERVICE_TARGET" 2>/dev/null
launchctl bootstrap "$DOMAIN_TARGET" "$PLIST_DST"
echo "Agent loaded. Screenshot organizer is running."
echo ""
echo "Logs: tail -f ~/Library/Logs/screenshot-organizer.log"
