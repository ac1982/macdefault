# macdefault

A macOS command-line utility for switching default file associations by file extension.

## Overview

`macdefault` manages default application associations for common office document formats using macOS's `duti` utility. Switch entire office suites with a single command instead of manually changing file associations through Finder.

**Supported file extensions:**
- Word: `doc`, `docx`
- Excel: `xls`, `xlsx`
- PowerPoint: `ppt`, `pptx`
- Other: `rtf`, `csv`

**Supported application suites:**
- **Microsoft Office** - Word, Excel, PowerPoint
- **WPS Office** - Single application (Kingsoft)
- **Apple iWork** - Pages, Numbers, Keynote, TextEdit

## Requirements

- **macOS only** (uses LaunchServices and duti)
- **Python 3.10+**
- **duti** - Install via: `brew install duti`
- **uv** - Python package manager ([installation](https://github.com/astral-sh/uv))
- **Python deps** - Installed automatically by uv (click, questionary, wcwidth)

## Installation

### Quick Start with uv

```bash
# Install uv if you haven't already
curl -LsSf https://astral.sh/uv/install.sh | sh

# Install duti
brew install duti

# Run directly without installation
uv run macdefault --help
```

### Install as a Tool

```bash
# Install globally with uv
uv tool install .

# Now you can run it anywhere
macdefault --help
```

### Development Setup

```bash
# Clone the repository
git clone https://github.com/ac1982/macdefault.git
cd macdefault

# uv will automatically create a virtual environment and install dependencies
uv sync

# Run in development mode
uv run macdefault --help
```

## Usage

### Switch to a Suite

Switch all supported file types to Microsoft Office:
```bash
uv run macdefault --microsoft
# or
uv run macdefault --office
```

Switch to WPS Office:
```bash
uv run macdefault --wps
# or
uv run macdefault --kingsoft
```

Switch to Apple iWork suite:
```bash
uv run macdefault --apple
```

### Interactive Mode

Choose a default app for a specific extension:
```bash
uv run macdefault --ext=doc
```

This will:
1. Show the current default handler
2. List all installed apps that support `.doc` files
3. Let you select one from the list using Up/Down arrows or by typing a number (1-9), press q to cancel
4. Apply the changes

Show candidates without making changes:
```bash
uv run macdefault --ext=doc --show
```

### Diagnostics

Print a summary of installed office suites:
```bash
uv run macdefault --print-bundle-ids
```

Full diagnostic output (bundle IDs + current defaults):
```bash
uv run macdefault --doctor
```

This shows:
- Which office apps are installed
- Their bundle IDs and paths
- Current default handlers for all managed extensions

### Additional Options

**Dry run** (preview changes without applying):
```bash
uv run macdefault --microsoft --dry-run
```

**Disable verification** (skip checking if changes succeeded):
```bash
uv run macdefault --wps --no-verify
```

**Fail fast** (stop on first error):
```bash
uv run macdefault --apple --fail-fast
```

## How It Works

1. **Discovery**: Scans common application directories (`/Applications`, etc.) for installed apps
2. **UTI Matching**: Uses macOS Uniform Type Identifiers to find apps that support each file extension
3. **LaunchServices**: Registers apps with `lsregister` when needed
4. **duti**: Applies the default handler settings via `duti -s <bundle-id> <extension> all`
5. **Verification**: Checks that changes were applied correctly

### Special Handling

- **WPS Office**: Uses a stable path (`/Applications/wpsoffice.app`) since LaunchServices name lookup can be unreliable
- **Microsoft Word .doc files**: Includes automatic repair logic if the default doesn't stick, re-registering with LaunchServices and applying multiple UTI variants

## Examples

### Typical Workflow

Check what's currently set:
```bash
uv run macdefault --doctor
```

Switch to Microsoft Office:
```bash
uv run macdefault --microsoft
```

Verify the changes:
```bash
uv run macdefault --doctor
```

### Choose Custom Handler for One Extension

Set a different app for `.md` files:
```bash
uv run macdefault --ext=md
```

See what handles `.csv` without changing:
```bash
uv run macdefault --ext=csv --show
```

## Troubleshooting

**"duti not found"**
- Install via: `brew install duti`

**"Microsoft Office apps not fully resolvable"**
- Ensure Word, Excel, and PowerPoint are installed in `/Applications`
- Try running `uv run macdefault --print-bundle-ids` to see what's detected

**Changes don't stick for .doc files**
- The script includes automatic repair logic for this common issue
- It re-registers Word with LaunchServices and tries multiple UTI identifiers

**App not appearing in --ext list**
- The app must declare support for that file type in its Info.plist
- As a workaround, use Finder: right-click file → Open With → Other → Change All

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

### Running Tests

```bash
# Add tests in the future
uv run pytest
```

### Code Formatting

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
- Interactive mode supports ESC to cancel (when running in a TTY)

## License

MIT License - See LICENSE file for details.
