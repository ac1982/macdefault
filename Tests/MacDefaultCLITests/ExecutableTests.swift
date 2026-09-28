import Darwin
import Foundation
import MacDefaultCore
import Testing

private let executable = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent(".build/debug/macdefault")

private struct Envelope<T: Decodable>: Decodable {
  let schemaVersion: Int
  let ok: Bool
  let data: T
}

private struct CommandResult {
  let status: Int32
  let output: Data
  let errorOutput: Data
  var text: String { String(decoding: output + errorOutput, as: UTF8.self) }
}

private func run(_ arguments: [String]) throws -> CommandResult {
  let process = Process()
  process.executableURL = executable
  process.arguments = arguments
  process.standardInput = FileHandle.nullDevice
  let pipe = Pipe()
  process.standardOutput = pipe
  let errors = Pipe()
  process.standardError = errors
  try process.run()
  let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
  DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
  defer { timeout.cancel() }
  let output = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return CommandResult(
    status: process.terminationStatus, output: output,
    errorOutput: errors.fileHandleForReading.readDataToEndOfFile())
}

struct TerminalScenario: Sendable {
  var arguments = ["set", "txt", "--dry-run"]
  var keys: String
  var ready = "Enter"
  var exitCode: Int32 = 130
  var result: String? = "Cancelled"
  var noColor = false
  var term = "xterm-256color"
  var columns: UInt16 = 80
  var rows: UInt16 = 24
  var resize = false
  var signal: Int32?

  static let cases: [TerminalScenario] = [
    TerminalScenario(keys: "q"),
    TerminalScenario(keys: "\u{1B}"),
    TerminalScenario(keys: "\u{03}"),
    TerminalScenario(keys: "\u{1B}[B\r", exitCode: 0, result: "Dry run: no changes made"),
    TerminalScenario(keys: "/TextEdit\r", exitCode: 0, result: "Dry run: no changes made"),
    TerminalScenario(
      keys: "/TextEdit\r", exitCode: 0, result: "Dry run: no changes made", columns: 40, rows: 14,
      resize: true),
    TerminalScenario(keys: "q", noColor: true),
    TerminalScenario(arguments: [], keys: "q"),
    TerminalScenario(arguments: [], keys: "3\r", exitCode: 0, result: "System check"),
    TerminalScenario(
      arguments: ["set", "txt", "--dry-run", "--plain"], keys: "0\nq\n", ready: "Choose a number"),
    TerminalScenario(keys: "q\n", ready: "Choose a number", term: "dumb"),
    TerminalScenario(keys: "", exitCode: 143, result: nil, signal: SIGTERM),
  ]
}

@Suite(.serialized) struct ExecutableTests {
  @Test func helpAndVersion() throws {
    let version = try run(["--version"])
    #expect(version.status == 0)
    #expect(version.text.trimmingCharacters(in: .whitespacesAndNewlines) == "1.0.0")
    let help = try run(["--help"])
    #expect(help.status == 0)
    #expect(help.text.contains("SUBCOMMANDS:"))
    #expect(help.text.contains("doctor"))
  }

  @Test func dryRunJSONLeavesRealDefaultsUnchanged() throws {
    let before = try run(["list", "txt", "--json"])
    let preview = try run(["set", "txt", "--app", "com.apple.TextEdit", "--dry-run", "--json"])
    let after = try run(["list", "txt", "--json"])
    #expect(before.status == 0 && preview.status == 0 && after.status == 0)
    let plan = try JSONDecoder().decode(Envelope<AssociationPlan>.self, from: preview.output).data
    #expect(!plan.changes.isEmpty)
    #expect(plan.changes.allSatisfy { $0.target.bundleID == "com.apple.TextEdit" })
    let previous = try JSONDecoder().decode(Envelope<ExtensionStatus>.self, from: before.output)
      .data
    let current = try JSONDecoder().decode(Envelope<ExtensionStatus>.self, from: after.output).data
    #expect(previous.defaults.map(\.application) == current.defaults.map(\.application))
    #expect(previous.defaults.map(\.type) == current.defaults.map(\.type))
  }

  @Test func nonInteractiveSelectionRequiresExplicitApp() throws {
    let result = try run(["set", "txt", "--dry-run"])
    #expect(result.status == 2)
    #expect(result.text.contains("requires a terminal"))
  }

  @Test func syntaxErrorsHaveUsageExitCode() throws {
    let result = try run(["suite", "unknown"])
    #expect(result.status == 64)
    #expect(result.text.contains("Unknown suite"))
  }

  @Test func nonexistentAppFailsBeforeMutation() throws {
    let result = try run(["set", "txt", "--app", "/no-such-app-macdefault.app", "--dry-run"])
    #expect(result.status == 1)
    #expect(result.text.contains("Not a readable application bundle"))
  }

  @Test func doctorEmitsStructuredReadOnlyReport() throws {
    let result = try run(["doctor", "--json"])
    #expect(result.status == 0)
    let document = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    #expect(document["ok"] as? Bool == true)
    let report = try #require(document["data"] as? [String: Any])
    #expect((report["applications"] as? [Any])?.count == 8)
    #expect((report["defaults"] as? [Any])?.count == 8)
    #expect((report["errors"] as? [Any])?.isEmpty == true)
  }

  @Test(arguments: [
    (["list", "--json"], Int32(64)),
    (["list", "../txt", "--json"], Int32(64)),
    (["list", "txt", "--unknown", "--json"], Int32(64)),
    (["set", "txt", "--json"], Int32(2)),
    (["set", "txt", "--app", "/no-such-macdefault.app", "--json"], Int32(1)),
  ])
  func failuresAreOneJSONDocument(arguments: [String], expected: Int32) throws {
    let result = try run(arguments)
    #expect(result.status == expected)
    #expect(result.errorOutput.isEmpty)
    #expect(!result.text.contains("\u{1B}"))
    let doc = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    #expect(doc["schemaVersion"] as? Int == 1)
    #expect(doc["ok"] as? Bool == false)
    let error = try #require(doc["error"] as? [String: Any])
    #expect(error["exitCode"] as? Int == Int(expected))
    #expect(error["kind"] as? String == (expected == 1 ? "failed" : "input"))
  }

  @Test func noInputNeverWaitsForSelection() throws {
    let result = try run(["set", "txt", "--no-input"])
    #expect(result.status == 2)
    #expect(result.text.contains("Supply --app"))
  }

  @Test func pipedOutputIsPlainAndVerboseIsOptIn() throws {
    let compact = try run(["list", "txt"])
    let verbose = try run(["list", "txt", "--verbose"])
    #expect(!compact.text.contains("\u{1B}"))
    #expect(!compact.text.contains("public.plain-text"))
    #expect(verbose.text.contains("public.plain-text"))
    #expect(verbose.text.contains("com.apple.TextEdit"))
  }

  @Test(arguments: TerminalScenario.cases)
  func terminalSelectionRestoresSettings(scenario: TerminalScenario) throws {
    var master: Int32 = -1
    var slave: Int32 = -1
    var size = winsize(ws_row: scenario.rows, ws_col: scenario.columns, ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw UserError("openpty failed") }
    let input = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
    let output = FileHandle(fileDescriptor: master, closeOnDealloc: true)
    defer {
      try? input.close()
      try? output.close()
    }
    var original = termios()
    #expect(tcgetattr(slave, &original) == 0)
    let process = Process()
    process.executableURL = executable
    process.arguments = scenario.arguments
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = scenario.term
    environment["NO_COLOR"] = scenario.noColor ? "1" : nil
    process.environment = environment
    process.standardInput = input
    process.standardOutput = input
    process.standardError = input
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }
    var transcript = ""
    var sentKeys = false
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
      if poll(&descriptor, 1, 100) > 0 {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = read(master, &buffer, buffer.count)
        if count > 0 { transcript += String(decoding: buffer.prefix(count), as: UTF8.self) }
      }
      if !sentKeys && transcript.contains(scenario.ready) {
        if scenario.resize {
          size.ws_col = 36
          size.ws_row = 12
          #expect(ioctl(slave, TIOCSWINSZ, &size) == 0)
        }
        if let signal = scenario.signal {
          #expect(kill(process.processIdentifier, signal) == 0)
        } else {
          try output.write(contentsOf: Data(scenario.keys.utf8))
        }
        sentKeys = true
      }
      if !process.isRunning { break }
    }
    #expect(sentKeys)
    #expect(!process.isRunning)
    if !process.isRunning { #expect(process.terminationStatus == scenario.exitCode) }
    if let result = scenario.result { #expect(transcript.contains(result)) }
    if scenario.term == "dumb" || scenario.arguments.contains("--plain") {
      #expect(!transcript.contains("\u{1B}"))
    } else {
      #expect(transcript.contains("\u{1B}[?25h"))
      #expect(transcript.contains("\u{1B}[1;36m") == !scenario.noColor)
    }
    var restored = termios()
    #expect(tcgetattr(slave, &restored) == 0)
    // macOS sets PENDIN when tcsetattr asks the driver to reprocess pending input.
    // It is kernel-maintained; compare all the caller-controlled local flags.
    let flags = ~tcflag_t(PENDIN)
    #expect(restored.c_lflag & flags == original.c_lflag & flags)
    #expect(restored.c_oflag == original.c_oflag)
  }
}
