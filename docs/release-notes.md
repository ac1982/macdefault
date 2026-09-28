The first Swift release replaces the Python implementation with a native macOS CLI.

- Interactive terminal menu and searchable application picker.
- Versioned JSON output, explicit exit codes, previews, and post-write verification.
- Native NSWorkspace API; no Python or duti runtime dependency.
- Universal executable for Apple Silicon and Intel, macOS 12 or later.

Download the `.pkg` for a Developer ID signed and notarized installer with a stapled
ticket. It installs `macdefault` into `/usr/local/bin`. The `.tar.gz` contains the same
signed executable for manual installation, including `~/.local/bin`. Verify downloads
using `SHA256SUMS`. macOS may still request confirmation when changing default apps.

Swift starts at version `1.0.0`; the existing `v1.0.2` tag belongs to the Python edition.
The command interface changed: use `macdefault --help` and the migration table in README.
