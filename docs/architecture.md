# Architecture

## Boundaries

`MacDefaultCore` contains value types and an application service. It imports Foundation,
not AppKit, UniformTypeIdentifiers, or ArgumentParser. Its `AssociationSystem` protocol
is the only way the service reaches the operating system. An in-memory implementation
drives execution tests, including failures that are difficult to reproduce reliably on
a user's Mac.

`MacDefaultSystem` translates between core value types and Apple frameworks. It reads
bundle metadata directly, avoiding subprocesses, Spotlight output parsing, AppleScript,
temporary sample files, and hard-coded Word repair commands. Application scanning is
bounded, excludes hidden paths, stops at app bundles, and is cached per invocation.

`MacDefaultCLI` owns command validation, rendering, and terminal I/O. Inspired by the
local haul CLI, the presentation uses compact blocks, an accent on the selected row,
and muted secondary details. `Console` centralizes styling, terminal dimensions, and
Unicode column handling. `Output` builds renderable lines without modifying core data.
Human output groups by extension; verbose and JSON output retain every content type.

The picker has a pure selection/filtering state machine and a bounded viewport.
It redraws on resize, supports search by app name/bundle ID, and falls back to a numbered
prompt for plain/dumb/tiny terminals. Terminal settings and cursor visibility are
restored on completion, cancellation, error unwinding, SIGINT, and SIGTERM. SIGKILL
cannot run cleanup (`stty sane` restores settings if necessary).

`EntryPoint` catches parse and runtime failures before reporting them. `AgentDocument`
wraps each payload in one versioned JSON response with `ok` and structured errors.
Partial failures include the complete execution report. Help/version are informational
plain-text exceptions. The contract and exit codes are documented in `llms.txt`.

System-facing operations run on the main actor. The tool operates on small batches;
parallel writes would complicate ordering and failure reporting without a useful
throughput benefit. The native setter awaits NSWorkspace.setDefaultApplication,
Apple’s replacement for the deprecated LaunchServices setter. The OS can request
consent before completion. Verification then suspends between reads to let system
changes propagate; its five-second window does not cover the consent wait.

## Data flow

1. Validate the command and normalize the extension.
2. Resolve every target application and every directly matching content type.
3. Build a plan, deduplicating shared types and rejecting conflicting targets.
4. For dry-run, render the plan and stop.
5. Recheck each default, register each necessary target once, and apply sequentially.
6. Optionally verify each type, polling every 250 ms for up to five seconds of waiting.
7. Return explicit outcomes; the CLI returns a failing exit code if any failed or skipped.

No implicit rollback is attempted: restoring an old default can itself fail, and other
processes may have changed it in the meantime. Plans are snapshots, so execution checks
the current default again before deciding whether a write is necessary.

## Type scope

The unit of mutation is a UTI, not a filename string. Only direct extension tags are
eligible. Generic base types are rejected in both the planner and native adapter.
All matching registered types are included because applications can declare different
types for the same extension. Shared extension aliases are exposed in the preview.

For office suites, the same planner and executor are used as for a single extension.
There is no separate repair pipeline. The WPS preset tries its known installation path
and two bundle IDs, through the same application resolver used by explicit `--app`.

## Tests and release checks

- Core tests exercise real planning and execution code through a fake system boundary.
- Bundle tests create temporary XML/binary plists and app directory trees.
- Native tests resolve real content types and TextEdit without writing to LaunchServices.
- CLI tests parse actual commands, exercise dry-run dispatch, and test selection behavior.
- Executable tests check real process exit codes, JSON output and non-interactive errors.
- CI runs tests with coverage and compiles the optimized executable on macOS.

Native mutation is deliberately outside the regular test suite. Before releasing,
use the opt-in live harness to set, open, and restore text defaults; also check Office
types and supported OS/CPU combinations in a disposable account.
The five-second verification window is bounded; a slower system can report a mismatch even
if its UI eventually catches up. A later `list` reports the current system state.
