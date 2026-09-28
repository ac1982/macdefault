import Foundation
import MacDefaultCore

enum Output {
  static func json<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    Console.write(String(decoding: try encoder.encode(value), as: UTF8.self) + "\n")
  }

  static func title(_ title: String, subtitle: String, style: TerminalStyle) -> [String] {
    ["", "  " + style.bold(title), "  " + style.muted(subtitle), ""]
  }

  static func names(_ apps: [Application?]) -> String {
    var seen = Set<String>()
    let names = apps.filter { seen.insert($0?.bundleID ?? "").inserted }
      .map { TerminalText.clean($0?.name ?? "No default") }
    if names.count <= 2 { return names.joined(separator: " / ") }
    return "\(names[0]) + \(names.count - 1) others"
  }

  static func statusLines(_ status: ExtensionStatus, display: DisplayOptions) -> [String] {
    let s = display.style
    let current = Set(status.defaults.compactMap { $0.application?.bundleID })
    let width = max(20, Console.size.width - 4)
    var lines = title(
      "\(status.ext)  ·  Default application", subtitle: names(status.defaults.map(\.application)),
      style: s)
    if current.count > 1 {
      lines.append("  " + s.warning("Different file variants have different defaults"))
    }
    if display.verbose {
      for item in status.defaults {
        lines.append(
          "  " + s.muted("\(item.type.identifier) → \(item.application?.bundleID ?? "none")"))
      }
      lines.append("")
    }
    lines.append("  " + s.muted("APPLICATIONS"))
    for app in status.candidates {
      let marker = current.contains(app.bundleID) ? "●" : "·"
      let badge = current.contains(app.bundleID) ? "  current" : ""
      lines.append(
        "  " + (current.contains(app.bundleID) ? s.good(marker) : s.muted(marker))
          + " " + TerminalText.fit(app.name, width: width - badge.count - 2) + s.muted(badge))
      if display.verbose {
        lines.append("    " + s.muted(TerminalText.clean(app.bundleID)))
        lines.append("    " + s.muted(TerminalText.clean(app.url.path)))
      }
    }
    if status.candidates.isEmpty { lines.append("    No applications found") }
    lines += [
      "", "  " + s.muted("macdefault set \(status.ext.value)  ·  choose an application"), "",
    ]
    return lines
  }

  static func status(_ status: ExtensionStatus, display: DisplayOptions) {
    Console.lines(statusLines(status, display: display))
  }

  static func extensions(in changes: [AssociationChange]) -> [FileExtension] {
    var seen = Set<FileExtension>()
    return changes.flatMap(\.extensions).filter { seen.insert($0).inserted }
  }

  static func planLines(_ plan: AssociationPlan, display: DisplayOptions) -> [String] {
    let s = display.style
    let extensions = extensions(in: plan.changes)
    var lines = title(
      "Preview",
      subtitle:
        "\(extensions.count) extension\(extensions.count == 1 ? "" : "s") · no changes will be made",
      style: s)
    let column = max(8, extensions.map { $0.description.count }.max() ?? 8)
    let width = max(16, (Console.size.width - column - 12) / 2)
    for ext in extensions {
      let changes = plan.changes.filter { $0.extensions.contains(ext) }
      let before = names(changes.map(\.previous))
      let after = names(changes.map { $0.target })
      let unchanged = changes.allSatisfy { !$0.needsChange }
      if Console.size.width < 64 {
        lines += [
          "  " + s.bold(ext.description),
          "    " + s.muted(TerminalText.fit(before, width: Console.size.width - 5)),
          "    " + s.accent(unchanged ? "= " : "→ ")
            + TerminalText.fit(after, width: Console.size.width - 7),
        ]
      } else {
        lines.append(
          "  " + s.bold(TerminalText.pad(ext.description, to: column)) + "  "
            + s.muted(TerminalText.pad(before, to: width)) + "  "
            + (unchanged ? s.muted("=") : s.accent("→"))
            + "  " + TerminalText.fit(after, width: width))
      }
      if display.verbose {
        for change in changes {
          lines.append(
            "    "
              + s.muted(
                "\(change.type.identifier): \(change.previous?.bundleID ?? "none") → \(change.target.bundleID)"
              ))
        }
      }
    }
    let requested = Set(extensions.map(\.value))
    let aliases = Set(plan.changes.flatMap(\.type.extensions)).subtracting(requested).sorted()
    if !aliases.isEmpty {
      lines += [
        "",
        "  "
          + s.warning(
            "Also affects " + aliases.map { ".\($0)" }.joined(separator: ", ")
              + " (shared file type)"),
      ]
    }
    if !display.verbose && plan.changes.count > extensions.count {
      lines += [
        "",
        "  " + s.muted("\(plan.changes.count) file variants · --verbose shows each content type"),
      ]
    }
    lines += ["", "  " + s.muted("Dry run: no changes made"), ""]
    return lines
  }

  static func plan(_ plan: AssociationPlan, display: DisplayOptions) {
    Console.lines(planLines(plan, display: display))
  }

  static func reportLines(_ report: ExecutionReport, display: DisplayOptions) -> [String] {
    let s = display.style
    let extensions = extensions(in: report.outcomes.map(\.change))
    let unchanged = report.outcomes.allSatisfy { $0.state == .unchanged }
    var lines = title(
      report.succeeded
        ? (unchanged ? "Already set" : "Defaults updated") : "Some changes could not be applied",
      subtitle: "\(extensions.count) extension\(extensions.count == 1 ? "" : "s")", style: s)
    for ext in extensions {
      let outcomes = report.outcomes.filter { $0.change.extensions.contains(ext) }
      let failed = outcomes.contains { $0.state == .failed }
      let skipped = outcomes.contains { $0.state == .skipped }
      let unchanged = outcomes.allSatisfy { $0.state == .unchanged }
      let badge = failed ? "failed" : skipped ? "skipped" : unchanged ? "already set" : "updated"
      let marker = failed ? s.bad("✗") : skipped ? s.warning("–") : s.good("✓")
      lines.append(
        "  \(marker) \(TerminalText.pad(ext.description, to: 8))  \(names(outcomes.map { $0.change.target }))  "
          + s.muted(badge))
      for outcome in outcomes {
        if let error = outcome.error {
          lines.append(
            "    " + s.bad(TerminalText.clean("\(outcome.change.type.identifier): \(error)")))
        } else if display.verbose {
          lines.append(
            "    "
              + s.muted("\(outcome.change.type.identifier) → \(outcome.change.target.bundleID)"))
        }
      }
    }
    let allVerified = report.outcomes.allSatisfy { $0.verified }
    lines += [
      "",
      "  "
        + s.muted(
          allVerified
            ? "Verified with macOS" : "Check individual results · not all changes were verified"),
      "",
    ]
    return lines
  }

  static func report(_ report: ExecutionReport, display: DisplayOptions) {
    Console.lines(reportLines(report, display: display))
  }

  static func doctor(_ report: DiagnosticReport, display: DisplayOptions) {
    let s = display.style
    var lines = title(
      "System check", subtitle: "Office applications & default associations", style: s)
    for app in report.applications {
      let marker = app.application == nil ? s.muted("–") : s.good("✓")
      lines.append(
        "  \(marker) \(TerminalText.pad(app.name, to: 24)) "
          + s.muted(app.application == nil ? "not installed" : "installed"))
      if display.verbose, let installed = app.application {
        lines += ["    " + s.muted(installed.bundleID), "    " + s.muted(installed.url.path)]
      }
    }
    lines += ["", "  " + s.muted("DEFAULTS")]
    for status in report.defaults {
      lines.append(
        "  \(TerminalText.pad(status.ext.description, to: 8))  \(names(status.defaults.map(\.application)))"
      )
      if display.verbose {
        for item in status.defaults {
          lines.append(
            "    " + s.muted("\(item.type.identifier) → \(item.application?.bundleID ?? "none")"))
        }
      }
    }
    lines += report.errors.map { "  " + s.bad($0) }
    Console.lines(lines + [""])
  }
}
