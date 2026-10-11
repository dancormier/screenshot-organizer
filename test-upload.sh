#!/bin/zsh

# Automated tests for the upload step (flush_uploads) in screenshot-organizer.sh.
# Uses throwaway temp directories; never touches your real config or folders.
# Usage: ./test-upload.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0

check() {
    if eval "$2"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $1"
    fi
}

setup() {
    ROOT="$(mktemp -d)"
    mkdir -p "$ROOT/watch/_archive" "$ROOT/nas" "$ROOT/state"
    cat > "$ROOT/config" <<EOF
WATCH_DIR="$ROOT/watch"
RENAME_ENABLED=true
CLIPBOARD_ENABLED=false
ARCHIVE_ENABLED=true
KEEP_COUNT=20
UPLOAD_DIR="$ROOT/nas"
STATE_DIR="$ROOT/state"
EOF
    SCREENSHOT_ORGANIZER_CONFIG="$ROOT/config" source "$SCRIPT_DIR/screenshot-organizer.sh" > /dev/null
}

teardown() {
    chmod -R u+w "$ROOT" 2>/dev/null
    rm -rf "$ROOT"
}

run_flush() {
    flush_uploads > "$ROOT/log" 2>&1
}

# ---- recent file is copied and stays local ----
setup
print -r "png-a" > "$ROOT/watch/20261010-120000.png"
run_flush
check "recent file copied to NAS" '[[ "$(<$ROOT/nas/20261010-120000.png)" == png-a ]]'
check "recent file kept locally" '[[ -f $ROOT/watch/20261010-120000.png ]]'
check "no partial file left" '[[ -z "$(ls -A $ROOT/nas | grep partial)" ]]'
check "upload recorded" 'grep -q "^20261010-120000.png" $ROOT/state/uploaded'
teardown

# ---- archived file is uploaded, verified, then removed locally ----
setup
print -r "png-b" > "$ROOT/watch/_archive/20261001-090000.png"
run_flush
check "archived file on NAS" '[[ "$(<$ROOT/nas/20261001-090000.png)" == png-b ]]'
check "archived file removed locally" '[[ ! -e $ROOT/watch/_archive/20261001-090000.png ]]'
teardown

# ---- NAS unmounted: nothing created, nothing deleted ----
setup
print -r "png-c" > "$ROOT/watch/_archive/20261001-090001.png"
rmdir "$ROOT/nas"
run_flush
check "upload dir not created" '[[ ! -e $ROOT/nas ]]'
check "local archive file kept while offline" '[[ -f $ROOT/watch/_archive/20261001-090001.png ]]'
check "offline logged" 'grep -q "not reachable" $ROOT/log'
mkdir "$ROOT/nas"
run_flush
check "uploaded after NAS returns" '[[ -f $ROOT/nas/20261001-090001.png ]]'
check "local removed after NAS returns" '[[ ! -e $ROOT/watch/_archive/20261001-090001.png ]]'
teardown

# ---- identical file already on NAS: no duplicate ----
setup
print -r "same" > "$ROOT/watch/_archive/20261002-100000.png"
print -r "same" > "$ROOT/nas/20261002-100000.png"
run_flush
check "no duplicate for identical file" '[[ $(ls $ROOT/nas | wc -l) -eq 1 ]]'
check "local removed when NAS already has it" '[[ ! -e $ROOT/watch/_archive/20261002-100000.png ]]'
teardown

# ---- same name, different content (other Mac): never overwrite ----
setup
print -r "mine" > "$ROOT/watch/_archive/20261003-110000.png"
print -r "theirs" > "$ROOT/nas/20261003-110000.png"
run_flush
check "existing NAS file untouched" '[[ "$(<$ROOT/nas/20261003-110000.png)" == theirs ]]'
check "upload saved under -1 name" '[[ "$(<$ROOT/nas/20261003-110000-1.png)" == mine ]]'
check "local removed after suffixed upload" '[[ ! -e $ROOT/watch/_archive/20261003-110000.png ]]'
teardown

# ---- recent file uploaded under -1 is not re-uploaded on the next run ----
setup
print -r "mine" > "$ROOT/watch/20261003-110001.png"
print -r "theirs" > "$ROOT/nas/20261003-110001.png"
run_flush
run_flush
check "second run adds no -2 copy" '[[ ! -e $ROOT/nas/20261003-110001-2.png ]]'
check "second run logs no upload" '! grep -q UPLOAD: $ROOT/log'
teardown

# ---- unrenamed and dotfiles are skipped ----
setup
print -r "raw" > "$ROOT/watch/Screenshot 2026-10-10 at 9.00.00 PM.png"
print -r "tmp" > "$ROOT/watch/.20261010-130000.png"
run_flush
check "unrenamed screenshot not uploaded" '[[ -z "$(ls -A $ROOT/nas)" ]]'
teardown

# ---- read-only share counts as offline: local file kept, retried later ----
setup
print -r "png-d" > "$ROOT/watch/_archive/20261004-120000.png"
chmod a-w "$ROOT/nas"
run_flush
check "local kept when NAS is read-only" '[[ -f $ROOT/watch/_archive/20261004-120000.png ]]'
check "read-only share logged as not reachable" 'grep -q "not reachable" $ROOT/log'
chmod u+w "$ROOT/nas"
run_flush
check "uploaded once writable again" '[[ -f $ROOT/nas/20261004-120000.png ]]'
teardown

# ---- copy fails on a writable NAS: local file kept ----
setup
print -r "png-h" > "$ROOT/watch/_archive/20261008-120000.png"
cp() { return 1 }
run_flush
unfunction cp
check "local kept when the copy fails" '[[ -f $ROOT/watch/_archive/20261008-120000.png ]]'
check "nothing left on NAS after failed copy" '[[ -z "$(ls -A $ROOT/nas)" ]]'
check "failed copy logged" 'grep -q "Failed to upload" $ROOT/log'
teardown

# ---- copy arrives corrupted: rejected, local file kept ----
setup
print -r "png-i" > "$ROOT/watch/_archive/20261008-120001.png"
cp() { command cp "$@" && print -r "garbage" >> "${@[-1]}" }
run_flush
unfunction cp
check "local kept when the copy is corrupted" '[[ -f $ROOT/watch/_archive/20261008-120001.png ]]'
check "corrupted copy not published" '[[ -z "$(ls -A $ROOT/nas)" ]]'
run_flush
check "clean retry uploads it" '[[ "$(<$ROOT/nas/20261008-120001.png)" == png-i ]]'
teardown

# ---- recorded upload replaced by same-size different content: never delete ----
setup
print -r "mine" > "$ROOT/watch/_archive/20261009-120000.png"
print -r "evil" > "$ROOT/nas/20261009-120000.png"
print -r "20261009-120000.png${TAB}20261009-120000.png" > "$ROOT/state/uploaded"
run_flush
check "share copy with other content left untouched" '[[ "$(<$ROOT/nas/20261009-120000.png)" == evil ]]'
check "own content re-uploaded under -1" '[[ "$(<$ROOT/nas/20261009-120000-1.png)" == mine ]]'
check "local removed only after its own content is on the share" '[[ ! -e $ROOT/watch/_archive/20261009-120000.png ]]'
teardown

# ---- temp name differs between processes ----
setup
print -r "png-j" > "$ROOT/watch/20261009-130000.png"
cp() { print -r -- "${@[-1]}" > "$ROOT/tmpname"; return 1 }
run_flush
unfunction cp
check "temp file name carries host and pid" '[[ "$(<$ROOT/tmpname)" == *".${HOST%%.*}."<->".partial" ]]'
teardown

# ---- lock taken over mid-run by another run is not removed ----
setup
print -r "png-k" > "$ROOT/watch/20261009-140000.png"
cp() { print -r "otherhost.1" > "$ROOT/state/upload.lock/owner"; command cp "$@" }
run_flush
unfunction cp
check "foreign lock left in place" '[[ "$(<$ROOT/state/upload.lock/owner)" == otherhost.1 ]]'
teardown

# ---- _archive symlinked into the upload folder: refuse, touch nothing ----
setup
rmdir "$ROOT/watch/_archive"
mkdir "$ROOT/nas/_archive"
ln -s "$ROOT/nas/_archive" "$ROOT/watch/_archive"
print -r "png-l" > "$ROOT/nas/_archive/20261009-150000.png"
run_flush
check "archive file on the share left in place" '[[ -f $ROOT/nas/_archive/20261009-150000.png ]]'
check "nothing copied to the share root" '[[ ! -e $ROOT/nas/20261009-150000.png ]]'
check "overlap logged" 'grep -q "overlaps" $ROOT/log'
teardown

# ---- held lock: run skips, nothing deleted ----
setup
print -r "png-e" > "$ROOT/watch/_archive/20261005-120000.png"
mkdir "$ROOT/state/upload.lock"
run_flush
check "skips while another upload runs" '[[ -f $ROOT/watch/_archive/20261005-120000.png && -z "$(ls -A $ROOT/nas)" ]]'
teardown

# ---- stale lock (>60 min) is cleared ----
setup
print -r "png-f" > "$ROOT/watch/_archive/20261006-120000.png"
mkdir "$ROOT/state/upload.lock"
touch -t "$(date -v-2H +%Y%m%d%H%M)" "$ROOT/state/upload.lock"
run_flush
check "stale lock cleared and upload done" '[[ -f $ROOT/nas/20261006-120000.png && ! -e $ROOT/state/upload.lock ]]'
teardown

# ---- uploads disabled: nothing happens ----
setup
UPLOAD_DIR=""
print -r "png-g" > "$ROOT/watch/_archive/20261007-120000.png"
run_flush
check "no upload when UPLOAD_DIR is empty" '[[ -f $ROOT/watch/_archive/20261007-120000.png && -z "$(ls -A $ROOT/nas)" ]]'
teardown

echo ""
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
