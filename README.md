# Screenshot Organizer

A lightweight macOS tool that watches a directory for new screenshots, copies them to the clipboard, and renames them — all within about a second.

Uses `fswatch` and macOS's native FSEvents for near-instant file detection instead of polling.

## What It Does

When a new screenshot or GIF appears in your watch directory:

1. **Copies it to the clipboard** — PNGs are copied as image data, GIFs are copied as file references (preserving animation)
2. **Renames it** to `YYYYMMDD-HHMMSS.png/gif` based on creation date
3. **Archives old files** — keeps the most recent images in the root folder and moves the rest to `_archive/`

Supports macOS screenshot naming (`Screenshot ...` and `Screen Shot ...`) and GIFs from tools like [Gifox](https://gifox.app/).

## Requirements

- macOS
- [Homebrew](https://brew.sh/)
- `fswatch` (`brew install fswatch`)

## Install

```sh
git clone https://github.com/yourusername/screenshot-organizer.git
cd screenshot-organizer
./install.sh
```

On first run, you'll be prompted for:

- **Watch directory** — defaults to your macOS screenshot location
- **Keep count** — how many recent files to keep before archiving (default: 20)
- **Settle delay** — seconds to wait before processing, to ensure the file is fully written (default: 0.5)

Config is saved to `~/.config/screenshot-organizer/config`. The script runs automatically on login via a LaunchAgent.

## Usage

Once installed, it runs in the background. Take a screenshot and it's on your clipboard and renamed within about a second.

**Tip:** Disable the macOS floating thumbnail for instant processing:

```sh
defaults write com.apple.screencapture show-thumbnail -bool false
```

### Management

```sh
# Reconfigure
./install.sh --reconfigure

# View logs
tail -f ~/Library/Logs/screenshot-organizer.log

# Stop and remove
./uninstall.sh
```

### Manual Testing

```sh
# In one terminal, run the script in the foreground:
./screenshot-organizer.sh

# In another terminal, run the test:
./test-organizer.sh
```

## How It Works

- `fswatch` monitors the watch directory using macOS FSEvents (not polling)
- New files are detected via `Created`, `Updated`, and `Renamed` events
- macOS writes screenshots to a temporary dotfile first, then renames — the script skips dotfiles and catches the final rename
- Already-renamed files (matching `YYYYMMDD-HHMMSS`) are ignored to prevent reprocessing

## Files

| File | Purpose |
|------|---------|
| `screenshot-organizer.sh` | Core script — watches, copies to clipboard, renames, archives |
| `install.sh` | Interactive setup — prompts for config, installs LaunchAgent |
| `uninstall.sh` | Stops the agent and removes the LaunchAgent |
| `test-organizer.sh` | Creates a test file to verify the script works |

## License

MIT
