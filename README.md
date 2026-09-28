# macdefault

A native Swift command-line tool for managing default applications on macOS.
No Python, `duti`, shell commands, or background service required at runtime.

## Build and install

Prebuilt universal binaries are available in [GitHub Releases](https://github.com/ac1982/macdefault/releases).
The release workflow signs with Developer ID and requires Apple notarization before
publishing. The `.pkg` includes a stapled ticket and installs to `/usr/local/bin`;
the archive contains the same signed executable for manual installation. Checksums
are included as `SHA256SUMS`. See [release configuration](docs/releasing.md).

Requires macOS 12 or later. Building requires a Swift 6 toolchain (Xcode 16 or later)
and an internet connection for the first dependency resolution.

```sh
swift build -c release
.build/release/macdefault --help

# Optional: install for your user
mkdir -p ~/.local/bin
install -m 755 .build/release/macdefault ~/.local/bin/macdefault
```

Add `~/.local/bin` to your `PATH` if needed. The executable uses the system's Apple
frameworks; users running a compatible prebuilt binary do not need Swift installed.

To build a universal binary for Apple Silicon and Intel:

```sh
swift build -c release --arch arm64 --arch x86_64
```

## Terminal interface

Run `macdefault` to open the interactive menu, or jump straight to `macdefault set txt`.
The picker highlights the current selection, scrolls within the terminal, and shows
only the selected application's path. Press `/` to filter by name or bundle ID.

```text
  Open .txt with
  Current  ·  Code

  › 1  Code  current
    2  Chromium
    3  Firefox
    4  Google Chrome
    5  Google Chrome for Testing
    6  Instruments
    7  Microsoft Edge
    8  Microsoft Excel

  /Applications/Visual Studio Code.app
  ↑↓ move  Enter choose  / filter  q cancel  · 1/19
```

TTY output uses a restrained cyan accent and muted secondary text. Piped output is
plain. `NO_COLOR` disables colors; `--plain` and `TERM=dumb` also disable cursor
control and use a numbered prompt instead. Narrow windows use shorter rows.

Default output groups content types by extension. `--verbose` expands bundle IDs,
paths, and every content type; it also exposes mixed defaults within an extension.

## Commands

```sh
# Inspect the current default and available applications
macdefault list txt
macdefault list docx --json

# Choose an application interactively
macdefault set txt

# Set a default explicitly by bundle identifier or application path
macdefault set txt --app com.apple.TextEdit
macdefault set docx --app '/Applications/Microsoft Word.app'

# Preview without changing anything
macdefault set txt --app com.apple.TextEdit --dry-run
macdefault suite microsoft --dry-run

# Switch office formats
macdefault suite microsoft
macdefault suite wps
macdefault suite apple

# Inspect office applications and current defaults
macdefault doctor
macdefault doctor --json
```

The interactive selector supports arrows (or j/k), Home/End, digits 1–9 to jump,
and Enter to choose. Press `/` to filter, Escape to clear a filter, and q/Escape or
Ctrl-C/Ctrl-D to cancel. Cancellation exits with code 130. Non-interactive use
requires `--app`; `--json` and `--no-input` never start a terminal prompt.

`set` and `suite` accept:

| Option | Behavior |
| --- | --- |
| `--dry-run` | Resolve and display the plan; never register apps or change defaults. |
| `--no-verify` | Skip verification after setting defaults. |
| `--fail-fast` | Stop on the first failed change; report remaining changes as skipped. |
| `--json` | Emit one versioned JSON document, including failures. `set` requires `--app`. |
| `--no-input` | Disable terminal prompts. `set` requires `--app`. |
| `--verbose` | Expand bundle IDs, paths, and content types. |
| `--plain` | Disable colors and cursor control. |

### For agents and scripts

```sh
macdefault list txt --json
macdefault set txt --app com.apple.TextEdit --dry-run --json
macdefault set txt --app com.apple.TextEdit --json
```

`--json` reserves stdout for **exactly one JSON document**, both on success and on
ordinary parse/runtime failure. Every response includes `schemaVersion: 1`, `ok`,
and `command`. `data` contains the status, plan, execution report, or diagnostic
report. `error` contains `kind`, `message`, and `exitCode` when `ok` is false.
Failures before a result is available omit `data`. Help/version remain plain text.

```json
{
  "schemaVersion": 1,
  "ok": false,
  "command": "set",
  "error": {
    "kind": "input",
    "message": "Supply --app when using --json or --no-input",
    "exitCode": 2
  }
}
```

| Exit code | Meaning |
| --- | --- |
| 0 | Success, including dry-run and already-correct defaults |
| 1 | Application resolution, system operation, or verification failed |
| 2 | A terminal prompt was required but disabled/unavailable |
| 64 | Invalid command syntax or argument value |
| 130 | Interactive selection cancelled |

Partial failures preserve `data.outcomes`, with per-type `changed`, `unchanged`,
`failed`, or `skipped` states. Check `ok` before using data; `--no-verify` yields
`verified: false` even when the write succeeded. JSON never contains ANSI escapes.
Writes use Apple’s NSWorkspace API. macOS may request confirmation before the
write completes; `--no-input` controls terminal prompts, not system consent.

See [llms.txt](llms.txt) for the complete agent contract and field descriptions.
The Swift release uses JSON schemaVersion 1; command payloads live under `data`.

### Office presets

| Extensions | Microsoft | WPS | Apple |
| --- | --- | --- | --- |
| doc, docx | Word | WPS Office | Pages |
| xls, xlsx | Excel | WPS Office | Numbers |
| ppt, pptx | PowerPoint | WPS Office | Keynote |
| rtf | Word | WPS Office | TextEdit |
| csv | Excel | WPS Office | Numbers |

All required applications and content types are resolved before any writes. Missing
applications or conflicting targets abort planning without making changes.

## How associations work

macOS associates applications with **content types (UTIs)**. The tool resolves types
whose filename-extension tags directly match the requested extension. It never walks
up the conformance tree and never writes generic types such as `public.data`.

A type can cover more than one extension: for example, `public.plain-text` covers
both `.txt` and `.text`. Changing that type affects its aliases too. Dry-run output
shows these aliases; JSON plans include them in `type.extensions`. If multiple
registered types declare the same extension, the plan includes each specific type.
Unknown extensions can resolve to a dynamic UTI created by the system.

Apps are discovered through `NSWorkspace`, supplemented by one bounded scan of
`/Applications`, `/System/Applications`, and `~/Applications`. Bundle IDs identify
associations; selecting an app path does not guarantee a particular copy will be
launched when multiple installed apps share that bundle ID.

Writes use `NSWorkspace.setDefaultApplication(at:toOpen:)`, Apple’s replacement
for the deprecated `LSSetDefaultRoleHandlerForContentType`.
A target app is registered with LaunchServices once per execution when needed.
Verification compares effective default bundle IDs every 250 ms, allowing five
seconds for propagation after the setter completes. This does not limit the time
spent awaiting system consent. A timeout is reported as failure, not success. Finder is
not restarted.

A batch is **not transactional**: successful changes remain applied if a later one
fails. The report identifies each result. Cancelling does not roll back completed
changes. No automatic Word-specific UTI aliases or MIME-type overrides are applied.

## Architecture

```text
Sources/
  MacDefaultCore/     Models, validation, office presets, planning and execution
  MacDefaultSystem/   NSWorkspace / UTType adapter and application bundle discovery
  MacDefaultCLI/      Argument parsing, terminal selection and text / JSON output
Tests/
  MacDefaultCoreTests/
  MacDefaultSystemTests/
  MacDefaultCLITests/
```

The core depends only on Foundation. `AssociationSystem` is the injected boundary
for all system reads and writes. Planning and execution are separate operations, so
dry-run does not enter the mutation path. The CLI depends on Apple's ArgumentParser;
there are no third-party terminal or macOS wrapper libraries.

See [architecture notes](docs/architecture.md) for design decisions and test boundaries.

## Development

```sh
swift test --enable-code-coverage
swift build -c release
```

Tests cover validation, exact type matching, shared-type conflicts, suite mappings,
read-only planning, stale plans, registration/write/query failures, fail-fast behavior,
verification retries, cancellation, JSON serialization, bundle scanning, CLI parsing,
selection/filtering state, Unicode column widths, narrow viewports, JSON errors,
and pseudo-terminal interaction/cancellation. Native integration checks only read the host's system database.
No regular-suite test changes real file associations.

### Opt-in real-system test

The regular suite above is read-only. The following separate test **does change real
defaults**: it saves the existing `.txt`/`.text` associations, opens a baseline file,
switches to TextEdit (or Code if TextEdit was already the default), opens another file
through macOS without specifying an app, restores the original default, and opens a
third file. The receipts record the actual application's bundle ID and process ID.
This is an opt-in local test, excluded from CI because it changes real preferences
and opens GUI apps. A passing result verifies association and opening behavior;
it does not detect dialogs or prove that no human interaction occurred.

```sh
swiftc -parse-as-library scripts/live-association-test.swift -o .build/live-association-test
.build/live-association-test "$HOME/.local/bin/macdefault"
```

Each application-open check has a 60-second deadline; a stalled launch proceeds
to restoration. The deadline does not cancel an already submitted macOS open request.
Run `.build/live-association-test --self-test-timeout` to check timeout handling
without opening apps or changing associations.

The test prints its temporary evidence directory and attempts restoration before
reporting an intermediate failure. Keep it running through restoration; forcibly
killing the test itself cannot guarantee cleanup. It requires a single pre-existing
`public.plain-text` default so that restoration is exact. See
[the recorded real-system test](docs/live-test.md).

A release should also be checked on the minimum supported macOS version and on Intel
and Apple Silicon. Real changes require an opt-in check in a
disposable macOS account; the mocked execution tests do not prove that every OS
version accepts every association.

## Migration from Python 1.x

Swift 1.0.0 starts a new implementation and command interface. There is no Python
package or compatibility wrapper in this source tree.

| Python 1.x | Swift 1.0.0 |
| --- | --- |
| `--ext txt --show` | `list txt` |
| `--ext txt` | `set txt` |
| `--microsoft` / `--office` | `suite microsoft` |
| `--wps` / `--kingsoft` | `suite wps` |
| `--apple` | `suite apple` |
| `--doctor` / `--print-bundle-ids` | `doctor` |

If the Python edition is installed, remove it using the package manager that installed
it (`uv tool uninstall macdefault` or `python -m pip uninstall macdefault`), then install
the Swift executable. Use `which -a macdefault` to check for older copies on `PATH`.

## License

[MIT](LICENSE)
