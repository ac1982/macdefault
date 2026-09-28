macdefault 1.0.1 fixes three issues found during review.

- Sanitize application metadata and errors before rendering terminal output, including parse failures and verbose previews.
- Resolve bundle identifiers ending in `.app` while retaining application-path selection.
- Limit live-test application-open checks to 60 seconds so a stalled launch can reach default restoration; ignore late callbacks safely.
- Add regression tests, including a read-only timeout self-test in CI.

The native NSWorkspace association API and JSON schemaVersion 1 remain unchanged.

Download the `.pkg` for a Developer ID signed and notarized installer with a stapled
ticket. It installs `macdefault` into `/usr/local/bin`. The `.tar.gz` contains the same
signed universal executable for manual installation, including `~/.local/bin`.
Verify downloads using `SHA256SUMS`. Requires macOS 12 or later. macOS may still
request confirmation when changing default apps.
