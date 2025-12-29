# macdefault

A macOS command-line utility for switching default file associations by file extension.

## Overview

`macdefault` changes the default app for any file extension using macOS LaunchServices and `duti`. It also includes preset switches for common office suites.

What it does:
- Pick a default app for any extension interactively (`--ext=mp3`).
- Switch office presets in one command (`--microsoft`, `--wps`, `--apple`).
- Show current defaults and installed bundle IDs for troubleshooting.

Preset extensions (suite mode):
- `doc`, `docx`, `xls`, `xlsx`, `ppt`, `pptx`, `rtf`, `csv`

## Requirements

- macOS
- Python 3.10+
- duti (`brew install duti`)

## Quick Start with uv

```bash
brew install duti
uv tool install macdefault
macdefault --help
```

## Installation

### pip

```bash
python -m pip install macdefault
macdefault --help
```

### From source (development)

```bash
git clone https://github.com/ac1982/macdefault.git
cd macdefault
uv sync
uv run macdefault --help
```

## Usage

### Set any extension

Choose a default app for a specific extension:
```bash
macdefault --ext=mp3
```

Show candidates without making changes:
```bash
macdefault --ext=mp3 --show
```

Interactive selection:
- Up/Down arrows to move
- Enter to confirm
- 1-9 to quick select
- q to cancel

### Switch office suites

Switch all preset extensions to Microsoft Office:
```bash
macdefault --microsoft
# or
macdefault --office
```

Switch to WPS Office:
```bash
macdefault --wps
# or
macdefault --kingsoft
```

Switch to Apple iWork:
```bash
macdefault --apple
```

### Diagnostics

Print a summary of installed suites:
```bash
macdefault --print-bundle-ids
```

Full diagnostic output (bundle IDs + current defaults):
```bash
macdefault --doctor
```

### Additional options

Dry run (preview changes without applying):
```bash
macdefault --microsoft --dry-run
```

Disable verification (skip checking if changes succeeded):
```bash
macdefault --wps --no-verify
```

Fail fast (stop on first error):
```bash
macdefault --apple --fail-fast
```

## How It Works

1. Discovery: scans common application directories (`/Applications`, etc.)
2. UTI matching: uses macOS Uniform Type Identifiers to find apps that support each extension
3. LaunchServices: registers apps with `lsregister` when needed
4. duti: applies defaults via `duti -s <bundle-id> <extension> all`
5. Verification: checks that changes were applied correctly

### Special handling

- WPS Office: uses a stable path (`/Applications/wpsoffice.app`) since LaunchServices name lookup can be unreliable
- Microsoft Word `.doc`: includes repair logic if the default does not stick

## Troubleshooting

"duti not found"
- Install via: `brew install duti`

"Microsoft Office apps not fully resolvable"
- Ensure Word, Excel, and PowerPoint are installed in `/Applications`
- Try running `macdefault --print-bundle-ids` to see what is detected

Changes do not stick for `.doc`
- The script re-registers Word with LaunchServices and tries multiple UTI identifiers

App not appearing in `--ext` list
- The app must declare support for that file type in its Info.plist
- Workaround: Finder right-click file -> Open With -> Other -> Change All

## Project Structure

```
macdefault/
├── macdefault.py       # Main script
├── pyproject.toml      # Project metadata and dependencies
├── README.md           # This file
├── .python-version     # Python version specification
└── .gitignore          # Git ignore rules
```

## Development

### Running tests

```bash
# Add tests in the future
uv run pytest
```

### Code formatting

```bash
# Add formatters as dev dependencies if needed
uv add --dev ruff black
uv run black macdefault.py
uv run ruff check macdefault.py
```

## Technical Details

- Uses `mdls` for fast metadata queries when available
- Falls back to parsing `Info.plist` directly
- Filters out overly-generic UTIs (`public.data`, `public.item`, `public.content`)
- Supports wide Unicode characters in table output via `wcwidth`
- Interactive mode supports q to cancel

## License

MIT License - See LICENSE file for details.
