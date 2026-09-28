import ArgumentParser
import Foundation
import MacDefaultCore

struct AgentError: Codable, Equatable {
  let kind: String
  let message: String
  let exitCode: Int32

  static func classify(_ error: any Error) -> AgentError {
    if error is CancellationError {
      return AgentError(kind: "cancelled", message: "Cancelled", exitCode: 130)
    }
    if let error = error as? InputError {
      return AgentError(kind: "input", message: error.localizedDescription, exitCode: 2)
    }
    return AgentError(kind: "failed", message: error.localizedDescription, exitCode: 1)
  }
}

struct InputError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

struct AgentDocument<Payload: Encodable>: Encodable {
  let schemaVersion = 1
  let ok: Bool
  let command: String
  let input: String?
  let data: Payload?
  let error: AgentError?
}

struct DisplayOptions: ParsableArguments {
  @Flag(
    help: "Emit one versioned JSON document, including on failure; never prompt in the terminal.")
  var json = false
  @Flag(help: "Show bundle IDs, paths and individual content types.")
  var verbose = false
  @Flag(help: "Plain text without colors or cursor control.")
  var plain = false

  var style: TerminalStyle { Console.style(plain: plain) }

  func document<T: Encodable>(command: String, input: String?, data: T, error: AgentError? = nil)
    throws
  {
    try Output.json(
      AgentDocument(ok: error == nil, command: command, input: input, data: data, error: error))
  }
}

/// Parse-time and runtime errors share the same machine-readable envelope.
@main
enum EntryPoint {
  @MainActor static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let wantsJSON = arguments.prefix(while: { $0 != "--" }).contains("--json")
    var parsed = false
    do {
      var command = try MacDefault.parseAsRoot(arguments)
      parsed = true
      if var asyncCommand = command as? any AsyncParsableCommand {
        try await asyncCommand.run()
      } else {
        try command.run()
      }
    } catch {
      if error is ExitCode || MacDefault.exitCode(for: error).rawValue == 0 {
        MacDefault.exit(withError: error)
      }
      let failure: AgentError
      if parsed && MacDefault.exitCode(for: error).rawValue != 64 {
        failure = AgentError.classify(error)
      } else {
        let code = MacDefault.exitCode(for: error).rawValue
        if code == 0 || !wantsJSON { MacDefault.exit(withError: error) }
        failure = AgentError(kind: "input", message: MacDefault.message(for: error), exitCode: code)
      }
      if wantsJSON {
        let command =
          arguments.first(where: { ["list", "set", "suite", "doctor"].contains($0) })
          ?? "macdefault"
        do {
          try Output.json(
            AgentDocument<String>(
              ok: false, command: command, input: nil, data: nil, error: failure))
        } catch { Console.error("Could not encode error: \(error.localizedDescription)") }
      } else {
        Console.error(failure.message)
      }
      MacDefault.exit(withError: ExitCode(failure.exitCode))
    }
  }
}
