#!/bin/zsh

# Unmatched globs expand to nothing instead of erroring (needed when no GIFs exist)
setopt NULL_GLOB

# Ensure Homebrew binaries are in PATH (LaunchAgents have minimal PATH)
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

CONFIG_FILE="${SCREENSHOT_ORGANIZER_CONFIG:-$HOME/.config/screenshot-organizer/config}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config not found at $CONFIG_FILE"
    echo "Run install.sh to set up."
    exit 1
fi

source "$CONFIG_FILE"

# Defaults for any missing config values
KEEP_COUNT="${KEEP_COUNT:-20}"
ARCHIVE_ENABLED="${ARCHIVE_ENABLED:-true}"
RENAME_ENABLED="${RENAME_ENABLED:-true}"
CLIPBOARD_ENABLED="${CLIPBOARD_ENABLED:-true}"
SETTLE_DELAY="${SETTLE_DELAY:-0.5}"
UPLOAD_DIR="${UPLOAD_DIR:-}"
UPLOAD_INTERVAL="${UPLOAD_INTERVAL:-300}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/screenshot-organizer}"

ARCHIVE_DIR="$WATCH_DIR/_archive"
UPLOADED_LIST="$STATE_DIR/uploaded"
UPLOAD_LOCK="$STATE_DIR/upload.lock"
UPLOAD_STATUS="$STATE_DIR/upload-status"
TAB=$'\t'

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
    if [[ "$CLIPBOARD_ENABLED" == true ]]; then
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
    fi
}

archive_old_screenshots() {
    # List PNGs and GIFs in root of watch dir (not subdirs), sorted newest first
    local files=("${(@f)$(find "$WATCH_DIR" -maxdepth 1 \( -name '*.png' -o -name '*.gif' \) -exec ls -t {} + 2>/dev/null)}")
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

is_uploadable() {
    local name="${1:t}"
    [[ "$name" == .* ]] && return 1
    [[ "$name" == *.(png|gif) ]] || return 1
    # Unrenamed files are still being processed; upload them once they have their final name
    if [[ "$RENAME_ENABLED" == true ]]; then
        [[ "$name" =~ ^[0-9]{8}-[0-9]{6} ]] || return 1
    fi
    return 0
}

file_size() {
    stat -f '%z' "$1" 2>/dev/null
}

# Prints the name the file has in UPLOAD_DIR. Never overwrites: an existing
# file with different content pushes the upload to name-1, name-2, ...
upload_one() {
    local src="$1"
    local name="${src:t}"
    local base="${name:r}" ext="${name:e}"
    local dest_name="$name"
    local i=0

    while [[ -e "$UPLOAD_DIR/$dest_name" ]]; do
        if cmp -s "$src" "$UPLOAD_DIR/$dest_name"; then
            print -r -- "$dest_name"
            return 0
        fi
        ((i++))
        dest_name="$base-$i.$ext"
    done

    local tmp="$UPLOAD_DIR/.$dest_name.partial"
    if ! cp "$src" "$tmp" 2>/dev/null || ! cmp -s "$src" "$tmp"; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    touch -r "$src" "$tmp" 2>/dev/null

    # -n: another Mac may have claimed the name since the check above
    mv -n "$tmp" "$UPLOAD_DIR/$dest_name" 2>/dev/null
    if [[ -e "$tmp" ]]; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    print -r -- "$dest_name"
}

recorded_dest() {
    [[ -f "$UPLOADED_LIST" ]] || return 1
    local line
    line="$(grep -F -m1 -- "$1${TAB}" "$UPLOADED_LIST")" || return 1
    [[ "${line%%${TAB}*}" == "$1" ]] || return 1
    print -r -- "${line#*${TAB}}"
}

set_upload_status() {
    local previous=""
    [[ -f "$UPLOAD_STATUS" ]] && previous="$(<"$UPLOAD_STATUS")"
    [[ "$previous" == "$1" ]] && return
    print -r -- "$1" > "$UPLOAD_STATUS"
    case "$1" in
        offline) log "UPLOAD: $UPLOAD_DIR not reachable (unmounted, or /bin/zsh lacks Full Disk Access); screenshots stay local" ;;
        online) log "UPLOAD: $UPLOAD_DIR available" ;;
    esac
}

# Copies every renamed screenshot that isn't on UPLOAD_DIR yet, verifying each
# copy byte for byte. Local files in _archive are deleted only after their
# upload is verified; recent files in the watch dir stay local.
flush_uploads() {
    [[ -n "$UPLOAD_DIR" ]] || return 0
    mkdir -p "$STATE_DIR"

    # Never create UPLOAD_DIR: when the share is unmounted its path is missing,
    # and creating it would write to the local disk under /Volumes.
    if [[ ! -d "$UPLOAD_DIR" || ! -w "$UPLOAD_DIR" ]]; then
        set_upload_status offline
        return 0
    fi
    set_upload_status online

    # A run that hung on a dead SMB mount must not block uploads forever
    if [[ -d "$UPLOAD_LOCK" && -n "$(find "$UPLOAD_LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]]; then
        rm -rf "$UPLOAD_LOCK"
    fi
    mkdir "$UPLOAD_LOCK" 2>/dev/null || return 0

    {
        touch "$UPLOADED_LIST"
        local f dest local_size
        for f in "$WATCH_DIR"/*(.N) "$ARCHIVE_DIR"/*(.N); do
            is_uploadable "$f" || continue

            dest="$(recorded_dest "${f:t}")"
            local_size="$(file_size "$f")"
            if [[ -z "$dest" || "$(file_size "$UPLOAD_DIR/$dest")" != "$local_size" ]]; then
                if ! dest="$(upload_one "$f")"; then
                    log "ERROR: Failed to upload ${f:t}; will retry"
                    continue
                fi
                grep -v -F -- "${f:t}${TAB}" "$UPLOADED_LIST" > "$UPLOADED_LIST.tmp"
                print -r -- "${f:t}${TAB}$dest" >> "$UPLOADED_LIST.tmp"
                mv "$UPLOADED_LIST.tmp" "$UPLOADED_LIST"
                log "UPLOAD: ${f:t} -> $dest"
            fi

            if [[ "${f:h}" == "$ARCHIVE_DIR" && "$(file_size "$UPLOAD_DIR/$dest")" == "$local_size" ]]; then
                rm -f "$f" && log "CLEANUP: ${f:t} (on $UPLOAD_DIR as $dest)"
            fi
        done

        # Forget entries whose local file is gone, so the list stays small
        local name kept=()
        while IFS= read -r name; do
            [[ -f "$WATCH_DIR/${name%%${TAB}*}" || -f "$ARCHIVE_DIR/${name%%${TAB}*}" ]] && kept+=("$name")
        done < "$UPLOADED_LIST"
        if (( ${#kept} )); then
            print -rl -- "${kept[@]}" > "$UPLOADED_LIST.tmp"
        else
            : > "$UPLOADED_LIST.tmp"
        fi
        mv "$UPLOADED_LIST.tmp" "$UPLOADED_LIST"
    } always {
        rm -rf "$UPLOAD_LOCK"
    }
}

# Sourced by test-upload.sh for its function definitions; only run as a script
[[ "$ZSH_EVAL_CONTEXT" == toplevel ]] || return 0

# Validate prerequisites
if ! command -v fswatch &>/dev/null; then
    log "ERROR: fswatch not found. Install with: brew install fswatch"
    exit 1
fi

if [[ ! -d "$WATCH_DIR" ]]; then
    log "ERROR: Watch directory not found: $WATCH_DIR"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")"

log "Screenshot Organizer v$VERSION"
log "Watching $WATCH_DIR for screenshots..."

if [[ -n "$UPLOAD_DIR" ]]; then
    log "Uploading to $UPLOAD_DIR (retry every ${UPLOAD_INTERVAL}s)"
    # Catches up the backlog after time away from the network
    while true; do
        flush_uploads
        sleep "$UPLOAD_INTERVAL"
    done &!
fi

fswatch --event Created --event Updated --event Renamed -0 "$WATCH_DIR" | while IFS= read -r -d '' file; do
    # Skip dotfiles (macOS writes screenshots to a temp dotfile first, then renames)
    [[ "${file:t}" == .* ]] && continue
    # Process PNGs matching screenshot naming patterns, and all GIFs (from Gifox etc.)
    # Skip files already in our renamed format (YYYYMMDD-HHMMSS)
    [[ "${file:t}" =~ ^[0-9]{8}-[0-9]{6} ]] && continue
    if [[ "${file:t}" == (*"Screen Shot"*|*"Screenshot"*).png || "${file:t}" == *.gif ]]; then
        process_screenshot "$file"
        [[ "$ARCHIVE_ENABLED" == true ]] && archive_old_screenshots
        # Background: a slow or hung network mount must not delay the next screenshot
        flush_uploads &!
    fi
done
