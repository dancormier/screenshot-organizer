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
zmodload zsh/system

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

# YYYY/MM from the renamed filename, falling back to the file's modified date
upload_subdir() {
    local name="${1:t}"
    if [[ "$name" =~ ^([0-9]{4})([0-9]{2})[0-9]{2}- ]]; then
        print -r -- "$match[1]/$match[2]"
    else
        stat -f '%Sm' -t '%Y/%m' "$1"
    fi
}

# Prints the path the file has under UPLOAD_DIR (YYYY/MM/name). Never
# overwrites: an existing file with different content pushes the upload to
# name-1, name-2, ...
upload_one() {
    local src="$1"
    local name="${src:t}"
    local base="${name:r}" ext="${name:e}"
    local sub dest_name i=0
    sub="$(upload_subdir "$src")" || return 1
    dest_name="$sub/$name"

    # One level at a time, no -p: if the share vanished mid-run, UPLOAD_DIR is
    # missing and this must fail instead of rebuilding it on the local disk
    [[ -d "$UPLOAD_DIR/${sub%%/*}" ]] || mkdir "$UPLOAD_DIR/${sub%%/*}" 2>/dev/null
    [[ -d "$UPLOAD_DIR/$sub" ]] || mkdir "$UPLOAD_DIR/$sub" 2>/dev/null || return 1

    while [[ -e "$UPLOAD_DIR/$dest_name" ]]; do
        if cmp -s "$src" "$UPLOAD_DIR/$dest_name"; then
            print -r -- "$dest_name"
            return 0
        fi
        ((i++))
        dest_name="$sub/$base-$i.$ext"
    done

    # Unique per Mac and process, so two uploaders never share a temp file
    local tmp="$UPLOAD_DIR/$sub/.${dest_name:t}.${HOST%%.*}.$sysparams[pid].partial"
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
        overlap) log "ERROR: $UPLOAD_DIR overlaps $WATCH_DIR or $ARCHIVE_DIR (check for symlinks); uploads paused" ;;
    esac
}

# True only when UPLOAD_DIR is on a mounted volume. A leftover folder under
# /Volumes after an unmount would otherwise take uploads onto the boot disk.
upload_dir_mounted() {
    [[ "$UPLOAD_DIR" == /Volumes/* ]] || return 0
    local mount_root="/Volumes/${${UPLOAD_DIR#/Volumes/}%%/*}"
    local root_dev volumes_dev
    root_dev="$(stat -f '%d' "$mount_root" 2>/dev/null)" || return 1
    volumes_dev="$(stat -f '%d' /Volumes 2>/dev/null)" || return 1
    [[ "$root_dev" != "$volumes_dev" ]]
}

# launchd runs one instance, so at startup any lock is left by a run killed
# mid-upload (logout, reboot, bootout). Forgetting the status makes the first
# run log whether UPLOAD_DIR is reachable.
reset_upload_state() {
    rm -rf "$UPLOAD_LOCK"
    rm -f "$UPLOAD_STATUS"
}

# A real write, because after the network drops macOS keeps the SMB mount
# listed and `-d`/`-w` still pass until the mount times out
upload_dir_writable() {
    local probe="$UPLOAD_DIR/.write-probe.${HOST%%.*}.$sysparams[pid]"
    { : > "$probe" } 2>/dev/null && rm -f "$probe"
}

paths_overlap() {
    [[ "$1" == "$2" || "$1" == "$2"/* || "$2" == "$1"/* ]]
}

# A symlinked _archive pointing into UPLOAD_DIR would turn "upload, then delete
# the local copy" into moving files around on the share itself
upload_dir_overlaps_local() {
    local upload_real="${UPLOAD_DIR:A}"
    paths_overlap "${WATCH_DIR:A}" "$upload_real" || paths_overlap "${ARCHIVE_DIR:A}" "$upload_real"
}

record_upload() {
    local tmp
    tmp="$(mktemp "$STATE_DIR/uploaded.XXXXXX")" || return 1
    grep -v -F -- "$1${TAB}" "$UPLOADED_LIST" > "$tmp"
    print -r -- "$1${TAB}$2" >> "$tmp"
    mv "$tmp" "$UPLOADED_LIST"
}

# Copies every renamed screenshot that isn't on UPLOAD_DIR yet, verifying each
# copy byte for byte. Local files in _archive are deleted only after the copy
# on UPLOAD_DIR matches byte for byte; recent files in the watch dir stay local.
flush_uploads() {
    [[ -n "$UPLOAD_DIR" ]] || return 0
    mkdir -p "$STATE_DIR"

    # Taken before touching UPLOAD_DIR, so a dead SMB mount hangs one run, not
    # one per screenshot. The lock is touched per file; an hour without a touch
    # means its run is stuck.
    if [[ -d "$UPLOAD_LOCK" && -n "$(find "$UPLOAD_LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]]; then
        rm -rf "$UPLOAD_LOCK"
    fi
    mkdir "$UPLOAD_LOCK" 2>/dev/null || return 0
    local owner="${HOST%%.*}.$sysparams[pid]"
    print -r -- "$owner" > "$UPLOAD_LOCK/owner"

    {
        # Never create UPLOAD_DIR: when the share is unmounted its path is
        # missing, and creating it would write to the local disk under /Volumes.
        if [[ ! -d "$UPLOAD_DIR" ]] || ! upload_dir_mounted || ! upload_dir_writable; then
            set_upload_status offline
            return 0
        fi
        if upload_dir_overlaps_local; then
            set_upload_status overlap
            return 0
        fi
        set_upload_status online

        touch "$UPLOADED_LIST"
        local f dest local_size archived
        for f in "$WATCH_DIR"/*(.N) "$ARCHIVE_DIR"/*(.N); do
            is_uploadable "$f" || continue
            touch "$UPLOAD_LOCK"
            [[ "${f:h}" == "$ARCHIVE_DIR" ]] && archived=true || archived=false

            dest="$(recorded_dest "${f:t}")"
            local_size="$(file_size "$f")"
            if [[ -z "$dest" || "$(file_size "$UPLOAD_DIR/$dest")" != "$local_size" ]] ||
               { $archived && ! cmp -s "$f" "$UPLOAD_DIR/$dest"; }; then
                if ! dest="$(upload_one "$f")"; then
                    # Network dropped mid-run: stop instead of timing out on every file
                    if ! upload_dir_writable; then
                        set_upload_status offline
                        break
                    fi
                    log "ERROR: Failed to upload ${f:t}; will retry"
                    continue
                fi
                record_upload "${f:t}" "$dest"
                log "UPLOAD: ${f:t} -> $dest"
            fi

            if $archived && cmp -s "$f" "$UPLOAD_DIR/$dest"; then
                rm -f "$f" && log "CLEANUP: ${f:t} (on $UPLOAD_DIR as $dest)"
            fi
        done

        # Forget entries whose local file is gone, so the list stays small
        local name tmp kept=()
        while IFS= read -r name; do
            [[ -f "$WATCH_DIR/${name%%${TAB}*}" || -f "$ARCHIVE_DIR/${name%%${TAB}*}" ]] && kept+=("$name")
        done < "$UPLOADED_LIST"
        tmp="$(mktemp "$STATE_DIR/uploaded.XXXXXX")" || return 0
        (( ${#kept} )) && print -rl -- "${kept[@]}" > "$tmp"
        mv "$tmp" "$UPLOADED_LIST"
    } always {
        # A run whose stale lock was cleared must not remove its successor's
        [[ "$(<"$UPLOAD_LOCK/owner" 2>/dev/null)" == "$owner" ]] && rm -rf "$UPLOAD_LOCK"
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
    reset_upload_state
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
