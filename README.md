# Screenshot Organizer

A lightweight macOS tool that watches a directory for new screenshots, copies them to the clipboard, and renames them — all within about a second.

Uses `fswatch` and macOS's native FSEvents for near-instant file detection instead of polling.

## What It Does

When a new screenshot or GIF appears in your watch directory:

1. **Copies it to the clipboard** — PNGs are copied as image data, GIFs are copied as file references (preserving animation). Optional; can be disabled at setup.
2. **Renames it** to `YYYYMMDD-HHMMSS.png/gif` based on creation date
3. **Archives old files** — keeps the most recent images in the root folder and moves the rest to `_archive/`
4. **Uploads to a NAS** (optional) — copies every screenshot to a network folder, verifying each copy byte for byte

## Uploading to a NAS

Set an upload folder at setup (for example `/Volumes/common/Screenshots/personal`; give each Mac its own folder so you can tell where a screenshot came from). Screenshots always save locally first, so taking one never depends on the network:

- Each renamed screenshot is copied into a `YYYY/MM` folder inside the upload folder (from its name, `20261011-…` → `2026/10/`) and checked byte for byte before it counts as uploaded.
- Recent screenshots stay in the watch directory. Older ones in `_archive/` are deleted locally only after their upload is verified, so the NAS holds the full history.
- Nothing on the NAS is ever overwritten or deleted. If a file with the same name but different content exists (say, from another Mac), the upload is saved as `name-1.png`.
- When the folder isn't reachable (away from home, share unmounted), screenshots wait locally. The script retries every 5 minutes and after every new screenshot, and the log notes when the folder goes away and comes back.

**One required permission:** macOS silently blocks background jobs from network volumes. Grant Full Disk Access to `/bin/zsh` (System Settings → Privacy & Security → Full Disk Access → +, then ⇧⌘G and `/bin/zsh`). The LaunchAgent runs the script through `/bin/zsh` so that this grant applies. Without it the log shows the upload folder as not reachable.

Saving screenshots *directly* to a network folder fails on current macOS ("Your screenshot can't be saved"): the screenshot is written on behalf of SystemUIServer, which has no network-volume permission. Saving locally and uploading avoids that.

Supports macOS screenshot naming (`Screenshot ...` and `Screen Shot ...`) and GIFs from tools like [Gifox](https://gifox.app/).

## Requirements

- macOS
- [Homebrew](https://brew.sh/)
- `fswatch` (`brew install fswatch`)

## Install

```sh
git clone https://github.com/dancormier/screenshot-organizer.git
cd screenshot-organizer
./install.sh
```

On first run, you'll be prompted for:

- **Watch directory** — defaults to your macOS screenshot location
- **Rename** — whether to rename files to `YYYYMMDD-HHMMSS` format
- **Clipboard** — whether to copy each screenshot to the clipboard automatically (on by default)
- **Archive** — whether to auto-archive old files, and how many to keep (default: 20)
- **Screenshot thumbnail** — option to disable the macOS thumbnail preview for faster processing

Config is saved to `~/.config/screenshot-organizer/config`. The script runs automatically on login via a LaunchAgent.

## Usage

Once installed, it runs in the background. Take a screenshot and it's on your clipboard and renamed within about a second.

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
| `screenshot-organizer.sh` | Core script — watches, copies to clipboard, renames, archives, uploads |
| `install.sh` | Interactive setup — prompts for config, installs LaunchAgent |
| `uninstall.sh` | Stops the agent and removes the LaunchAgent |
| `test-organizer.sh` | Creates a test file to verify the script works |
| `test-upload.sh` | Automated tests for the NAS upload step (temp folders only) |

## License

MIT
