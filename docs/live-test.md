# Real-system association test — 2026-09-28

Environment: macOS 27.0, Apple Silicon; macdefault 2.1.0 development builds.
The first two sections record the investigation before the final backend change;
the final section records validation of the shipped implementation.

| Stage | Expected application | Actual application returned by macOS | Result |
| --- | --- | --- | --- |
| Open baseline-a.txt | com.microsoft.VSCode | com.microsoft.VSCode, PID 81212 | Pass |
| Set the default to B | com.apple.TextEdit | CLI returned changed, verified=true | Pass |
| Open switched-b.txt | com.apple.TextEdit | com.apple.TextEdit, PID 82445 | Pass |
| Restore A | com.microsoft.VSCode | CLI returned changed, verified=true | Pass |
| Open restored-a.txt | com.microsoft.VSCode | com.microsoft.VSCode, PID 81212 | Pass |

Files were opened using `NSWorkspace.open(file, configuration:)` without supplying
an application URL. The returned `NSRunningApplication` identifies the app that
actually handled the open request; this is not merely a default-handler query.
The TextEdit window was also inspected: it displayed `switched-b.txt` and the test
content. Code displayed `restored-a.txt` after restoration.

The complete `.txt` and `.text` default records before and after the round trip were
equal. A final fresh query confirmed `com.microsoft.VSCode` was restored.

The user observed the native macOS confirmation asking whether `.txt` and `.text`
should open in TextEdit or remain in Code. This confirms that the native write API
can require human consent on this machine. It is not an unattended test, and terminal
`--no-input` does not suppress macOS consent dialogs.

No functional association failure was observed in this round trip. This result is
specific to plain-text associations on this machine; it does not establish that every
Office type or macOS version behaves identically.

Evidence directory for this run:

```text
/var/folders/4f/2v_4g8ds5tg_7x760026wb_c0000gn/T/macdefault-live-3723DE8D-0D2D-4207-BAE8-1B11111CCE4C
```

It contains before/after JSON snapshots, switch/restore reports, three open receipts,
and the three temporary text files. The opt-in reproducer is
[`scripts/live-association-test.swift`](../scripts/live-association-test.swift).

## Comparison with the 1.0.2 write path

The original Python `set_default` invokes `duti -s <bundle-id> .txt all`.
The installed duti 1.5.4_1 imports and calls
`LSSetDefaultRoleHandlerForContentType`; the Swift application currently calls
`NSWorkspace.setDefaultApplication(at:toOpen:)`, whose documented behavior
includes requesting user consent when necessary.

A temporary diagnostic variant of the live-test harness used the exact old duti
command for writes, retaining fresh macdefault queries and actual file-open
receipts. The harness did not automate any confirmation clicks; it also did not
monitor dialogs or human interaction, so absence of a prompt is not established.
Both writes returned in milliseconds
(about 14 ms and 7 ms). Actual opens verified Code → TextEdit → Code, and the
final `.txt` and `.text` mappings matched the original Code mappings.

An initial immediate-query attempt failed because queries still returned the old
association after duti had returned success. Subsequent reads showed the change
had propagated. The successful diagnostic waited two seconds after switching and
three seconds after restoration. These waits demonstrate propagation delay on
this machine, not a guaranteed convergence deadline. A production implementation
using this interface would need bounded polling and post-write verification.

Evidence for the successful legacy-path run:

```text
/var/folders/4f/2v_4g8ds5tg_7x760026wb_c0000gn/T/macdefault-live-F36AE7A1-4BDD-4087-B702-6C4EB70E542A
```

This compares the 1.0.2 write path, not a reinstallation of its Python CLI. It
does not establish that all file types or OS versions avoid consent. At this stage,
the product backend and installed binary had not yet been changed.

## Final Swift backend validation

The Swift adapter now calls `LSSetDefaultRoleHandlerForContentType` directly with
all roles. The service polls the effective default every 250 ms, allowing five
seconds of waiting before reporting a verification timeout. No duti subprocess
is used. The regular suite passed all 71 tests, including delayed propagation,
timeout, and cancellation during verification.

The unmodified live-test harness ran against the universal release binary at
approximately 10:59 on 2026-09-28. Actual file opens returned:

| Stage | Actual application | Result |
| --- | --- | --- |
| baseline-a.txt | com.microsoft.VSCode, PID 91274 | Pass |
| switched-b.txt | com.apple.TextEdit, PID 92169 | Pass |
| restored-a.txt | com.microsoft.VSCode, PID 91274 | Pass |

Both writes returned successful verified reports; `.txt` and `.text` were restored
to their saved Code defaults. Evidence:

```text
/var/folders/4f/2v_4g8ds5tg_7x760026wb_c0000gn/T/macdefault-live-D272740C-5014-4DB9-B44E-167238A4F846
```

## Correction: confirmation behavior remains unresolved

After the final run, the user reported that a confirmation dialog appeared again.
The harness records write results and actual open handlers, but does not record
dialogs or user clicks. Therefore its PASS result cannot support the earlier claim
that no confirmation was required. The installed binary imports the legacy
LaunchServices setter; changing to that API alone has not established unattended
operation. Dialog origin and whether human input affected the run remain unverified.

## Observed repeat: confirmation still required

The installed binary was tested again with the unmodified harness. The user
explicitly confirmed seeing and clicking the confirmation dialog. The harness
then reported PASS and restored Code. This is an attended success, not evidence
of unattended execution.

Evidence directory:

```text
/var/folders/4f/2v_4g8ds5tg_7x760026wb_c0000gn/T/macdefault-live-2F86587B-0DD9-4A3E-A9C3-AA67BFD95F33
```

The earlier 10:59 run also has system-log evidence: CoreServicesUIAgent received
`CSUIChangeDefaultHandlerHandler` requests at 10:59:47.691 and 10:59:52.222.
Thus importing and calling the same public function as duti does not establish
identical consent behavior for these binaries. The cause of that difference has
not yet been determined. The earlier no-confirmation claims are withdrawn.
