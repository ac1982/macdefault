// Opt-in integration test. This changes real defaults, opens three temporary files,
// and restores the saved .txt association even when an intermediate check fails.
// Build: swiftc -parse-as-library scripts/live-association-test.swift -o .build/live-association-test
// Run:   .build/live-association-test /absolute/path/to/macdefault
import AppKit
import Foundation

struct CheckFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

struct Application: Codable, Equatable {
  let bundleID: String
  let url: URL
}
struct TypeStatus: Codable {
  struct ContentType: Codable { let identifier: String }
  let type: ContentType
  let application: Application?
}
struct Status: Codable { let defaults: [TypeStatus] }
struct Envelope: Codable {
  let ok: Bool
  let data: Status
}
struct OpenReceipt: Codable {
  let file: URL
  let expectedBundleID: String
  let openedBundleID: String
  let processID: Int32
}

/// A callback may never arrive, or arrive after the deadline. Resume only once.
@MainActor
final class OpenDeadline {
  private var continuation: CheckedContinuation<NSRunningApplication, any Error>?
  private var timer: Task<Void, Never>?

  init(_ continuation: CheckedContinuation<NSRunningApplication, any Error>) {
    self.continuation = continuation
  }

  func arm(nanoseconds: UInt64) {
    timer = Task { @MainActor in
      do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
      finish(.failure(CheckFailure(message: "Application launch timed out; restoring defaults")))
    }
  }

  func finish(_ result: Result<NSRunningApplication, any Error>) {
    guard let continuation else { return }
    self.continuation = nil
    timer?.cancel()
    timer = nil
    continuation.resume(with: result)
  }
}

@main
struct LiveAssociationTest {
  @MainActor static func main() async {
    do {
      if CommandLine.arguments.dropFirst() == ["--self-test-timeout"] {
        try await testOpenDeadline()
      } else {
        try await run()
      }
    } catch {
      FileHandle.standardError.write(Data("LIVE TEST FAILED: \(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }

  @MainActor static func testOpenDeadline() async throws {
    var pending: OpenDeadline?
    do {
      _ = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<NSRunningApplication, any Error>) in
        let deadline = OpenDeadline(continuation)
        pending = deadline
        deadline.arm(nanoseconds: 10_000_000)
        // Simulate an API that never invokes its completion handler.
      }
      throw CheckFailure(message: "Expected launch timeout")
    } catch let error as CheckFailure where error.message.contains("launch timed out") {
      // This is the same error path that proceeds to restoration in run().
    }
    // A late completion must not resume the continuation a second time.
    pending?.finish(.failure(CheckFailure(message: "late completion")))
    let expected = NSRunningApplication.current
    let application = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<NSRunningApplication, any Error>) in
      let deadline = OpenDeadline(continuation)
      deadline.arm(nanoseconds: 10_000_000)
      deadline.finish(.success(expected))
    }
    guard application === expected else {
      throw CheckFailure(message: "Launch success was not returned")
    }
    print("PASS: stalled launch reaches restoration; late completion is ignored")
  }

  @MainActor static func run() async throws {
    guard CommandLine.arguments.count == 2 else {
      throw CheckFailure(message: "Supply the absolute path to the macdefault executable")
    }
    let executable = URL(fileURLWithPath: CommandLine.arguments[1])
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("macdefault-live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    print("Evidence directory: \(directory.path)")
    fflush(stdout)

    func command(_ arguments: [String], log: String) throws -> Data {
      let output = directory.appendingPathComponent(log)
      FileManager.default.createFile(atPath: output.path, contents: nil)
      let handle = try FileHandle(forWritingTo: output)
      defer { try? handle.close() }
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = handle
      process.standardError = FileHandle.standardError
      try process.run()
      // Prevent a stuck child from indefinitely delaying restoration.
      let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
      DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
      process.waitUntilExit()
      watchdog.cancel()
      guard process.terminationStatus == 0 else {
        throw CheckFailure(
          message:
            "\(arguments.joined(separator: " ")) exited \(process.terminationStatus); see \(output.path)"
        )
      }
      return try Data(contentsOf: output)
    }

    func snapshot(_ ext: String, label: String) throws -> Envelope {
      let data = try command(["list", ext, "--json"], log: "\(label)-\(ext).json")
      let result = try JSONDecoder().decode(Envelope.self, from: data)
      guard result.ok else { throw CheckFailure(message: "Snapshot failed") }
      return result
    }
    func defaults(_ snapshot: Envelope) -> [String: String] {
      Dictionary(
        uniqueKeysWithValues: snapshot.data.defaults.map {
          ($0.type.identifier, $0.application?.bundleID ?? "")
        })
    }
    func set(_ bundleID: String, label: String) throws {
      _ = try command(["set", "txt", "--app", bundleID, "--json"], log: "\(label).json")
      print("\(label): \(bundleID)")
      fflush(stdout)
    }
    func open(_ name: String, expecting bundleID: String) async throws {
      let file = directory.appendingPathComponent("\(name).txt")
      try "macdefault live test: \(name)\nExpected application: \(bundleID)\n".write(
        to: file, atomically: true, encoding: .utf8)
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.addsToRecentItems = false
      // Deliberately do not supply an application URL: macOS must choose the default.
      let application = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<NSRunningApplication, any Error>) in
        let deadline = OpenDeadline(continuation)
        deadline.arm(nanoseconds: 60_000_000_000)
        NSWorkspace.shared.open(file, configuration: configuration) { application, error in
          Task { @MainActor in
            if let error {
              deadline.finish(.failure(error))
            } else if let application {
              deadline.finish(.success(application))
            } else {
              deadline.finish(.failure(CheckFailure(message: "Launch returned no application")))
            }
          }
        }
      }
      let receipt = OpenReceipt(
        file: file, expectedBundleID: bundleID,
        openedBundleID: application.bundleIdentifier ?? "", processID: application.processIdentifier
      )
      try JSONEncoder().encode(receipt).write(
        to: directory.appendingPathComponent("\(name)-open.json"))
      guard receipt.openedBundleID == bundleID else {
        throw CheckFailure(
          message: "\(name) opened in \(receipt.openedBundleID), expected \(bundleID)")
      }
      print("\(name): opened by \(receipt.openedBundleID), PID \(receipt.processID)")
      fflush(stdout)
    }

    let before = try snapshot("txt", label: "before")
    let aliasBefore = try snapshot("text", label: "before")
    let saved = defaults(before)
    guard saved.count == 1, saved["public.plain-text"]?.isEmpty == false,
      let original = before.data.defaults.first?.application
    else {
      throw CheckFailure(
        message: "This test requires one existing public.plain-text default so restoration is exact"
      )
    }
    let target =
      original.bundleID == "com.apple.TextEdit" ? "com.microsoft.VSCode" : "com.apple.TextEdit"
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) != nil else {
      throw CheckFailure(message: "Test target is not installed: \(target)")
    }
    try await open("baseline-a", expecting: original.bundleID)
    var failure: (any Error)?
    do {
      try set(target, label: "switch-to-b")
      let switched = try snapshot("txt", label: "switched")
      guard defaults(switched).values.allSatisfy({ $0 == target }) else {
        throw CheckFailure(message: "Query did not reflect the new default")
      }
      try await open("switched-b", expecting: target)
    } catch { failure = error }

    // Restoration happens before surfacing a failure in the B phase.
    try set(original.bundleID, label: "restore-a")
    let after = try snapshot("txt", label: "after")
    let aliasAfter = try snapshot("text", label: "after")
    guard defaults(after) == saved, defaults(aliasAfter) == defaults(aliasBefore) else {
      throw CheckFailure(
        message:
          "Restoration did not reproduce the saved txt/text defaults; evidence: \(directory.path)")
    }
    try await open("restored-a", expecting: original.bundleID)
    if let failure { throw failure }
    print("PASS: A → B → A, actual file opens verified, txt/text defaults restored")
  }
}
