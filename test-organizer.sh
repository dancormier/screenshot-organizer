#!/bin/zsh

# Manual integration test for screenshot-organizer.sh
# Usage: Run screenshot-organizer.sh in one terminal, then run this in another.

CONFIG_FILE="$HOME/.config/screenshot-organizer/config"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config not found. Run install.sh first."
    exit 1
fi

source "$CONFIG_FILE"

TEST_FILE="$WATCH_DIR/Screenshot test-$(date +%s).png"

echo "Creating test screenshot: $TEST_FILE"

# Create a minimal valid PNG using screencapture
screencapture -x -R0,0,1,1 "$TEST_FILE"

echo "Waiting 3 seconds for organizer to process..."
sleep 3

echo ""
echo "Checking clipboard (should contain image data):"
osascript -e 'clipboard info' | grep -q "«class PNGf»" && echo "  ✓ Clipboard contains PNG data" || echo "  ✗ Clipboard does NOT contain PNG data"

echo ""
echo "Checking if file was renamed:"
if [[ ! -f "$TEST_FILE" ]]; then
    echo "  ✓ Original file was renamed"
    echo "  Recent files in $WATCH_DIR:"
    ls -lt "$WATCH_DIR"/*.png 2>/dev/null | head -3
else
    echo "  ✗ Original file still exists (not renamed)"
fi
