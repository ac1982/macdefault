import ArgumentParser
import Foundation
import MacDefaultCore
import MacDefaultSystem

struct MacDefault: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "macdefault",
    abstract: "Manage macOS default applications using native system APIs.",
    discussion: """
      INTERACTIVE
        macdefault                     Open the interactive menu
        macdefault set txt             Choose an application

      FOR AGENTS
        macdefault list txt --json
        macdefault set txt --app com.apple.TextEdit --dry-run --json
        macdefault set txt --app com.apple.TextEdit --json

      JSON uses schemaVersion, ok, command, data and error. No terminal prompts.
      Exit codes: 0 success, 1 failed, 2 input, 64 syntax, 130 cancelled.
      Use --verbose for bundle IDs and content types; --plain for plain text.
      """,
    version: "2.1.0",
    subcommands: [List.self, SetDefault.self, Suite.self, Doctor.self]
  )

  @MainActor mutating func run() async throws {
    guard Console.interactive else {
      Console.write(Self.helpMessage() + "\n")
      return
    }
    let display = try DisplayOptions.parse([])
    let choice = try TerminalPicker.choose(
      items: [
        PickerItem(
          title: "Choose a default application",
          detail: "Pick a file extension, then an application"),
        PickerItem(
          title: "Switch an office suite", detail: "Word, Excel, PowerPoint, RTF and CSV formats"),
        PickerItem(
          title: "Check current defaults",
          detail: "Inspect installed office apps and their associations"),
      ], title: "macdefault", subtitle: "Your files. Your applications.", display: display)
    switch choice {
    case 0:
      Console.write("\n  File extension (for example txt): ")
      guard let ext = readLine(), !ext.isEmpty else { throw CancellationError() }
      var command = try SetDefault.parse([ext])
      try await command.run()
    case 1:
      let suites = ["microsoft", "wps", "apple"]
      let selected = try TerminalPicker.choose(
        items: [
          PickerItem(title: "Microsoft Office", detail: "Word · Excel · PowerPoint"),
          PickerItem(title: "WPS Office", detail: "Use WPS for all office formats"),
          PickerItem(title: "Apple iWork", detail: "Pages · Numbers · Keynote · TextEdit"),
        ], title: "Office defaults", subtitle: "Choose a suite for 8 file extensions",
        display: display)
      var command = try Suite.parse([suites[selected]])
      try await command.run()
    default:
      var command = try Doctor.parse([])
      try await command.run()
    }
  }
}

struct WriteOptions: ParsableArguments {
  @Flag(help: "Preview the complete plan without registering apps or changing defaults.")
  var dryRun = false

  @Flag(help: "Skip checking defaults after applying changes.")
  var noVerify = false

  @Flag(help: "Stop applying changes after the first failure.")
  var failFast = false

  @Flag(help: "Disable terminal prompts; set requires --app. Implied by --json.")
  var noInput = false

  @OptionGroup var display: DisplayOptions

  @MainActor
  func apply(
    _ plan: AssociationPlan, using service: AssociationService, command: String = "set",
    input: String? = nil
  ) async throws {
    if dryRun {
      if display.json {
        try display.document(command: command, input: input, data: plan)
      } else {
        Output.plan(plan, display: display)
      }
      return
    }
    let report = try await service.execute(plan, verify: !noVerify, failFast: failFast)
    if display.json {
      let error =
        report.succeeded
        ? nil
        : AgentError(kind: "failed", message: "Some associations could not be updated", exitCode: 1)
      try display.document(command: command, input: input, data: report, error: error)
    } else {
      Output.report(report, display: display)
    }
    if !report.succeeded { throw ExitCode.failure }
  }
}

struct List: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Show defaults and available applications for an extension.")

  @Argument(help: "File extension, for example txt or .docx.") var ext: String
  @OptionGroup var display: DisplayOptions

  mutating func validate() throws {
    do { _ = try FileExtension(ext) } catch { throw ValidationError(error.localizedDescription) }
  }

  @MainActor
  mutating func run() async throws {
    let service = AssociationService(system: NativeAssociationSystem())
    let status = try service.inspect(FileExtension(ext))
    if display.json {
      try display.document(command: "list", input: ext, data: status)
    } else {
      Output.status(status, display: display)
    }
  }
}

struct SetDefault: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "set",
    abstract: "Set the default app for an extension; choose interactively if --app is omitted."
  )

  @Argument(help: "File extension, for example txt or .docx.") var ext: String
  @Option(help: "Installed application bundle ID or .app path.") var app: String?
  @OptionGroup var options: WriteOptions

  mutating func validate() throws {
    do { _ = try FileExtension(ext) } catch { throw ValidationError(error.localizedDescription) }
    if let app, app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw ValidationError("--app cannot be empty.")
    }
  }

  @MainActor
  mutating func run() async throws {
    if app == nil && (options.noInput || options.display.json) {
      throw InputError("Supply --app when using --json or --no-input")
    }
    let service = AssociationService(system: NativeAssociationSystem())
    let ext = try FileExtension(ext)
    let target: Application
    if let app {
      target = try service.resolve(app)
    } else {
      let status = try service.inspect(ext)
      target = try AppSelector.select(from: status, display: options.display)
    }
    let plan = try service.plan([AssociationRequest(ext: ext, application: target)])
    try await options.apply(plan, using: service, command: "set", input: ext.value)
  }
}

struct Suite: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Switch office formats to microsoft, wps, or apple.")

  @Argument(help: "Office suite: microsoft, wps, apple.") var name: String
  @OptionGroup var options: WriteOptions

  mutating func validate() throws {
    guard OfficeSuite(rawValue: name) != nil else {
      throw ValidationError("Unknown suite '\(name)'. Choose microsoft, wps, or apple.")
    }
  }

  @MainActor
  mutating func run() async throws {
    guard let suite = OfficeSuite(rawValue: name) else {
      throw ValidationError("Unknown suite: \(name)")
    }
    let service = AssociationService(system: NativeAssociationSystem())
    let plan = try service.plan(suite.requests(using: service))
    try await options.apply(plan, using: service, command: "suite", input: name)
  }
}

struct SuiteAppStatus: Encodable {
  let name: String
  let application: Application?
  let error: String?
}

struct DiagnosticReport: Encodable {
  let applications: [SuiteAppStatus]
  let defaults: [ExtensionStatus]
  let errors: [String]
}

struct Doctor: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Inspect installed office apps and current associations without making changes.")
  @OptionGroup var display: DisplayOptions

  @MainActor
  mutating func run() async throws {
    let service = AssociationService(system: NativeAssociationSystem())
    let apps = SuiteApplication.allCases.map { descriptor in
      do {
        return SuiteAppStatus(
          name: descriptor.name, application: try descriptor.resolve(using: service), error: nil)
      } catch {
        return SuiteAppStatus(
          name: descriptor.name, application: nil, error: error.localizedDescription)
      }
    }
    var defaults: [ExtensionStatus] = []
    var errors: [String] = []
    for ext in OfficeSuite.extensions {
      do {
        defaults.append(try service.inspect(FileExtension(ext), includeCandidates: false))
      } catch { errors.append(".\(ext): \(error.localizedDescription)") }
    }
    let report = DiagnosticReport(applications: apps, defaults: defaults, errors: errors)
    if display.json {
      let error =
        errors.isEmpty
        ? nil : AgentError(kind: "failed", message: "Some defaults could not be read", exitCode: 1)
      try display.document(command: "doctor", input: nil, data: report, error: error)
    } else {
      Output.doctor(report, display: display)
    }
    if !errors.isEmpty { throw ExitCode.failure }
  }
}
