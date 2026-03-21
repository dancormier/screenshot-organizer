#!/bin/zsh

# Ensure Homebrew binaries are in PATH (LaunchAgents have minimal PATH)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

CONFIG_FILE="$HOME/.config/screenshot-organizer/config"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config not found at $CONFIG_FILE"
    echo "Run install.sh to set up."
    exit 1
fi

source "$CONFIG_FILE"

ARCHIVE_DIR="$WATCH_DIR/_archive"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

process_screenshot() {
    local file="$1"

    # Wait for the file to be fully written
    sleep "$SETTLE_DELAY"

    # Verify file still exists (it may have been moved/deleted)
    if [[ ! -f "$file" ]]; then
        log "SKIP: File no longer exists: $file"
        return
    fi

    # Determine file extension
    local ext="${file:e:l}"

    # Rename first (GIF clipboard uses file URL, so path must be final)
    if [[ "$RENAME_ENABLED" == true ]]; then
        local new_name
        new_name="$(stat -f '%SB' -t '%Y%m%d-%H%M%S' "$file").$ext"
        local dir
        dir="$(dirname "$file")"
        local target="$dir/$new_name"

        # Handle collision: append -1, -2, etc.
        if [[ -f "$target" && "$file" != "$target" ]]; then
            local i=1
            while [[ -f "$dir/${new_name%.$ext}-${i}.$ext" ]]; do
                ((i++))
            done
            target="$dir/${new_name%.$ext}-${i}.$ext"
        fi

        if [[ "$file" != "$target" ]]; then
            if mv "$file" "$target"; then
                log "RENAME: $(basename "$file") -> $(basename "$target")"
                file="$target"
            else
                log "ERROR: Failed to rename $file -> $target"
            fi
        fi
    fi

    # Copy image to clipboard
    local copy_ok=false
    case "$ext" in
        png)
            osascript \
                -e 'on run argv' \
                -e '  set the clipboard to (read POSIX file (item 1 of argv) as «class PNGf»)' \
                -e 'end run' \
                -- "$file" && copy_ok=true
            ;;
        gif)
            # Copy as file URL (preserves animation when pasting into Slack, Discord, etc.)
            osascript -l JavaScript \
                -e 'function run(argv) {
                    ObjC.import("AppKit");
                    ObjC.import("Foundation");
                    var url = $.NSURL.fileURLWithPath(argv[0]);
                    var pb = $.NSPasteboard.generalPasteboard;
                    pb.clearContents;
                    pb.writeObjects($.NSArray.arrayWithObject(url));
                }' \
                -- "$file" && copy_ok=true
            ;;
        *) log "ERROR: Unsupported format: $ext"; return ;;
    esac

    if [[ "$copy_ok" != true ]]; then
        log "ERROR: Failed to copy to clipboard: $file"
        return
    fi
    log "CLIPBOARD: $file"
}

archive_old_screenshots() {
    # List PNGs and GIFs in root of watch dir (not subdirs), sorted newest first
    local files=("${(@f)$(ls -t "$WATCH_DIR"/*.png "$WATCH_DIR"/*.gif 2>/dev/null)}")
    local count=${#files[@]}

    if (( count <= KEEP_COUNT )); then
        return
    fi

    mkdir -p "$ARCHIVE_DIR"

    # Move everything after the first KEEP_COUNT files
    local to_archive=("${files[@]:$KEEP_COUNT}")
    for f in "${to_archive[@]}"; do
        if mv "$f" "$ARCHIVE_DIR/"; then
            log "ARCHIVE: ${f:t}"
        else
            log "ERROR: Failed to archive ${f:t}"
        fi
    done
}

# Validate prerequisites
if ! command -v fswatch &>/dev/null; then
    log "ERROR: fswatch not found. Install with: brew install fswatch"
    exit 1
fi

if [[ ! -d "$WATCH_DIR" ]]; then
    log "ERROR: Watch directory not found: $WATCH_DIR"
    exit 1
fi

log "Watching $WATCH_DIR for screenshots..."

fswatch --event Created --event Updated --event Renamed -0 "$WATCH_DIR" | while IFS= read -r -d '' file; do
    # Skip dotfiles (macOS writes screenshots to a temp dotfile first, then renames)
    [[ "${file:t}" == .* ]] && continue
    # Process PNGs matching screenshot naming patterns, and all GIFs (from Gifox etc.)
    # Skip files already in our renamed format (YYYYMMDD-HHMMSS)
    [[ "${file:t}" =~ ^[0-9]{8}-[0-9]{6} ]] && continue
    if [[ "${file:t}" == (*"Screen Shot"*|*"Screenshot"*).png || "${file:t}" == *.gif ]]; then
        process_screenshot "$file"
        archive_old_screenshots
    fi
done
