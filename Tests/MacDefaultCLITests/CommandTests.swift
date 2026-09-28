import ArgumentParser
import Foundation
import MacDefaultCore
import Testing

@testable import MacDefaultCLI

@Suite struct CommandParsingTests {
  @Test func parsesExplicitSet() throws {
    let command = try #require(
      MacDefault.parseAsRoot([
        "set", ".TXT", "--app", "com.apple.TextEdit", "--dry-run", "--no-verify", "--fail-fast",
        "--json",
      ]) as? SetDefault)
    #expect(command.ext == ".TXT")
    #expect(command.app == "com.apple.TextEdit")
    #expect(
      command.options.dryRun && command.options.noVerify && command.options.failFast
        && command.options.display.json)
  }

  @Test func parsesInteractiveSet() throws {
    let command = try #require(MacDefault.parseAsRoot(["set", "txt"]) as? SetDefault)
    #expect(command.app == nil)
    #expect(!command.options.noVerify)
  }

  @Test(arguments: [
    ["set"], ["set", "../txt"],
    ["set", "txt", "--app", ""], ["suite", "unknown"], ["list", "txt", "--dry-run"],
    ["--microsoft"], ["list", "txt", "--unknown"],
  ])
  func rejectsInvalidCommands(arguments: [String]) {
    #expect(throws: (any Error).self) { try MacDefault.parseAsRoot(arguments) }
  }

  @Test(arguments: OfficeSuite.allCases.map(\.rawValue))
  func parsesSuites(name: String) throws {
    let command = try #require(MacDefault.parseAsRoot(["suite", name, "--dry-run"]) as? Suite)
    #expect(command.name == name)
    #expect(command.options.dryRun)
  }

  @Test func parsesReadOnlyCommands() throws {
    #expect(
      try (MacDefault.parseAsRoot(["list", "docx", "--json"]) as? List)?.display.json == true)
    #expect(try (MacDefault.parseAsRoot(["doctor", "--json"]) as? Doctor)?.display.json == true)
  }
}

@Suite struct SelectionTests {
  func items(_ count: Int) -> [PickerItem] {
    (0..<count).map { PickerItem(title: "App \($0)", detail: "test.app\($0)") }
  }

  @Test func emptyListCannotSelect() {
    var state = SelectionState(items: [])
    #expect(state.handle(.confirm) == .pending)
    #expect(state.handle(.cancel) == .cancelled)
  }

  @Test func arrowsWrap() {
    var state = SelectionState(items: items(3))
    #expect(state.handle(.move(-1)) == .pending)
    #expect(state.index == 2)
    #expect(state.handle(.move(1)) == .pending)
    #expect(state.index == 0)
  }

  @Test func confirmsAndCancels() {
    var state = SelectionState(items: items(3), index: 1)
    #expect(state.handle(.confirm) == .selected(1))
    #expect(state.handle(.cancel) == .cancelled)
  }

  @Test func validatesQuickSelect() {
    var state = SelectionState(items: items(2))
    #expect(state.handle(.choose(8)) == .pending)
    #expect(state.handle(.choose(-1)) == .pending)
    #expect(state.handle(.choose(1)) == .pending)
    #expect(state.handle(.confirm) == .selected(1))
    #expect(state.handle(.ignore) == .pending)
  }
}

@MainActor final class CommandSystem: AssociationSystem {
  var writes = 0
  var current: Application?
  var failWrite = false
  func contentTypes(for ext: FileExtension) throws -> [ContentType] {
    [ContentType(identifier: "test.txt", extensions: ["txt"])]
  }
  func defaultApplication(for type: ContentType) throws -> Application? { current }
  func applications(for ext: FileExtension, types: [ContentType]) throws -> [Application] { [] }
  func application(matching selector: String) throws -> Application { throw UserError("unused") }
  func register(_ application: Application) throws { writes += 1 }
  func setDefault(_ application: Application, for type: ContentType) async throws {
    writes += 1
    if failWrite { throw UserError("write failed") }
    current = application
  }
}

@Suite @MainActor struct WriteOptionsTests {
  @Test func dryRunNeverCallsMutationBoundary() async throws {
    let system = CommandSystem()
    let service = AssociationService(system: system)
    let app = Application(
      name: "Editor", bundleID: "test.editor", url: URL(fileURLWithPath: "/Editor.app"))
    let plan = try service.plan([AssociationRequest(ext: FileExtension("txt"), application: app)])
    let command = try #require(
      MacDefault.parseAsRoot(["set", "txt", "--app", "test.editor", "--dry-run"]) as? SetDefault)
    try await command.options.apply(plan, using: service)
    #expect(system.writes == 0)
  }

  @Test(arguments: [false, true])
  func successfulExecutionUsesSharedExecutor(json: Bool) async throws {
    let system = CommandSystem()
    let service = AssociationService(system: system)
    let app = Application(
      name: "Editor", bundleID: "test.editor", url: URL(fileURLWithPath: "/Editor.app"))
    let plan = try service.plan([AssociationRequest(ext: FileExtension("txt"), application: app)])
    let arguments = ["set", "txt", "--app", "test.editor"] + (json ? ["--json"] : [])
    let command = try #require(MacDefault.parseAsRoot(arguments) as? SetDefault)
    try await command.options.apply(plan, using: service)
    #expect(system.current == app)
    #expect(system.writes == 2)
  }

  @Test(arguments: [false, true])
  func executionFailureReturnsFailingExitCode(json: Bool) async throws {
    let system = CommandSystem()
    system.failWrite = true
    let service = AssociationService(system: system)
    let app = Application(
      name: "Editor", bundleID: "test.editor", url: URL(fileURLWithPath: "/Editor.app"))
    let plan = try service.plan([AssociationRequest(ext: FileExtension("txt"), application: app)])
    let arguments = ["set", "txt", "--app", "test.editor"] + (json ? ["--json"] : [])
    let command = try #require(MacDefault.parseAsRoot(arguments) as? SetDefault)
    await #expect(throws: ExitCode.failure) {
      try await command.options.apply(plan, using: service)
    }
    #expect(system.current == nil)
  }
}
