import Foundation
import Testing

@testable import MacDefaultCore

let editor = Application(
  name: "Editor", bundleID: "test.editor", url: URL(fileURLWithPath: "/Applications/Editor.app"))
let other = Application(
  name: "Other", bundleID: "test.other", url: URL(fileURLWithPath: "/Applications/Other.app"))

@MainActor
final class FakeSystem: AssociationSystem {
  var types: [String: [ContentType]] = [:]
  var defaults: [String: Application] = [:]
  var candidates: [Application] = []
  var apps: [String: Application] = [:]
  var writes: [String] = []
  var registrations: [Application] = []
  var resolutions: [String] = []
  var reads = 0
  var candidateQueries = 0
  var failures = Set<String>()
  var registrationFails = false
  var readFails = false
  var persist = true
  var cancelWrite = false
  var scriptedReads: [Application?] = []

  func contentTypes(for ext: FileExtension) throws -> [ContentType] {
    types[ext.value] ?? [ContentType(identifier: "test.\(ext.value)", extensions: [ext.value])]
  }
  func defaultApplication(for type: ContentType) throws -> Application? {
    reads += 1
    if readFails { throw UserError("query failed") }
    if !scriptedReads.isEmpty { return scriptedReads.removeFirst() }
    return defaults[type.identifier]
  }
  func applications(for ext: FileExtension, types: [ContentType]) throws -> [Application] {
    candidateQueries += 1
    return candidates
  }
  func application(matching selector: String) throws -> Application {
    resolutions.append(selector)
    guard let app = apps[selector] else { throw UserError("not installed") }
    return app
  }
  func register(_ application: Application) throws {
    registrations.append(application)
    if registrationFails { throw UserError("registration failed") }
  }
  func setDefault(_ application: Application, for type: ContentType) async throws {
    if cancelWrite { throw CancellationError() }
    writes.append(type.identifier)
    if failures.contains(type.identifier) { throw UserError("write failed") }
    if persist { defaults[type.identifier] = application }
  }
}

@Suite @MainActor
struct AssociationServiceTests {
  func request(_ ext: String, _ app: Application = editor) throws -> AssociationRequest {
    AssociationRequest(ext: try FileExtension(ext), application: app)
  }

  @Test func planningIsReadOnly() throws {
    let system = FakeSystem()
    system.defaults["test.txt"] = other
    let service = AssociationService(system: system)
    let plan = try service.plan([request("txt")])
    #expect(plan.changes.count == 1)
    #expect(plan.changes[0].previous == other)
    #expect(plan.changes[0].needsChange)
    #expect(system.writes.isEmpty)
    #expect(system.registrations.isEmpty)
  }

  @Test func excludesUnrelatedAndGenericTypes() throws {
    let system = FakeSystem()
    system.types["txt"] = [
      ContentType(identifier: "public.data", extensions: ["txt"]),
      ContentType(identifier: "test.other", extensions: ["other"]),
      ContentType(identifier: "test.txt", extensions: ["txt"]),
      ContentType(identifier: "test.txt", extensions: ["txt"]),
    ]
    let plan = try AssociationService(system: system).plan([request("txt")])
    #expect(plan.changes.map(\.type.identifier) == ["test.txt"])
  }

  @Test func rejectsUnresolvableExtensionBeforeAnyWrites() throws {
    let system = FakeSystem()
    system.types["bad"] = []
    #expect(throws: UserError.self) {
      try AssociationService(system: system).plan([request("txt"), request("bad")])
    }
    #expect(system.writes.isEmpty)
    #expect(system.registrations.isEmpty)
  }

  @Test func mergesSharedTypesAndRepeatedRequests() throws {
    let system = FakeSystem()
    let type = ContentType(identifier: "test.shared", extensions: ["txt", "text"])
    system.types = ["txt": [type], "text": [type]]
    let plan = try AssociationService(system: system).plan([
      request("txt"), request("text"), request("txt"),
    ])
    #expect(plan.changes.count == 1)
    #expect(plan.changes[0].extensions.map(\.value) == ["txt", "text"])
  }

  @Test func rejectsSharedTypeConflicts() throws {
    let system = FakeSystem()
    let type = ContentType(identifier: "test.shared", extensions: ["txt", "text"])
    system.types = ["txt": [type], "text": [type]]
    #expect(throws: UserError.self) {
      try AssociationService(system: system).plan([request("txt"), request("text", other)])
    }
    #expect(system.writes.isEmpty)
  }

  @Test func rejectsEmptyPlan() {
    #expect(throws: UserError.self) { try AssociationService(system: FakeSystem()).plan([]) }
  }

  @Test func currentDefaultIsRetainedAndCandidatesDeduplicated() throws {
    let system = FakeSystem()
    system.defaults["test.txt"] = other
    system.candidates = [editor, editor, other]
    let status = try AssociationService(system: system).inspect(FileExtension("txt"))
    #expect(status.candidates == [other, editor])
    #expect(status.defaults[0].application == other)
  }

  @Test func queryFailureIsNotHidden() {
    let system = FakeSystem()
    system.readFails = true
    #expect(throws: UserError.self) {
      try AssociationService(system: system).inspect(FileExtension("txt"))
    }
  }

  @Test func inspectingDefaultsCanSkipCandidateDiscovery() throws {
    let system = FakeSystem()
    let status = try AssociationService(system: system).inspect(
      FileExtension("txt"), includeCandidates: false)
    #expect(status.defaults.count == 1)
    #expect(status.candidates.isEmpty)
    #expect(system.candidateQueries == 0)
  }

  @Test func appliesAllTypesAndRegistersOnce() async throws {
    let system = FakeSystem()
    let service = AssociationService(system: system)
    let report = try await service.execute(service.plan([request("txt"), request("md")]))
    #expect(report.succeeded)
    #expect(report.outcomes.map(\.state) == [.changed, .changed])
    #expect(report.outcomes.allSatisfy { $0.verified })
    #expect(system.writes == ["test.txt", "test.md"])
    #expect(system.registrations == [editor])
  }

  @Test func unchangedDefaultsDoNotWriteOrRegister() async throws {
    let system = FakeSystem()
    system.defaults["test.txt"] = editor
    let service = AssociationService(system: system)
    let report = try await service.execute(service.plan([request("txt")]))
    #expect(report.outcomes[0].state == .unchanged)
    #expect(report.outcomes[0].verified)
    #expect(system.writes.isEmpty)
    #expect(system.registrations.isEmpty)
  }

  @Test func rechecksStalePlan() async throws {
    let system = FakeSystem()
    system.defaults["test.txt"] = editor
    let service = AssociationService(system: system)
    let plan = try service.plan([request("txt")])
    system.defaults["test.txt"] = other
    let report = try await service.execute(plan)
    #expect(report.outcomes[0].state == .changed)
    #expect(system.defaults["test.txt"] == editor)
  }

  @Test func continuesAfterFailureByDefault() async throws {
    let system = FakeSystem()
    system.failures = ["test.txt"]
    let service = AssociationService(system: system)
    let report = try await service.execute(service.plan([request("txt"), request("md")]))
    #expect(!report.succeeded)
    #expect(report.outcomes.map(\.state) == [.failed, .changed])
    #expect(report.outcomes[0].error == "write failed")
  }

  @Test func failFastReportsRemainingAsSkipped() async throws {
    let system = FakeSystem()
    system.failures = ["test.txt"]
    let service = AssociationService(system: system)
    let report = try await service.execute(
      service.plan([request("txt"), request("md")]), failFast: true)
    #expect(report.outcomes.map(\.state) == [.failed, .skipped])
    #expect(system.writes == ["test.txt"])
  }

  @Test func registrationFailurePreventsWritesAndIsCached() async throws {
    let system = FakeSystem()
    system.registrationFails = true
    let service = AssociationService(system: system)
    let report = try await service.execute(service.plan([request("txt"), request("md")]))
    #expect(report.outcomes.map(\.state) == [.failed, .failed])
    #expect(system.writes.isEmpty)
    #expect(system.registrations.count == 1)
  }

  @Test func failedVerificationIsAnErrorEvenWhenThereIsNoDefault() async throws {
    let system = FakeSystem()
    system.persist = false
    var waits: [UInt64] = []
    let service = AssociationService(system: system, wait: { waits.append($0) })
    let report = try await service.execute(service.plan([request("txt")]))
    #expect(!report.succeeded)
    #expect(report.outcomes[0].error?.contains("got no default") == true)
    #expect(waits.reduce(0, +) == 5_000_000_000)
    #expect(report.outcomes[0].error?.contains("timed out") == true)
  }

  @Test func verificationRetriesEventuallyConsistentRead() async throws {
    let system = FakeSystem()
    let service = AssociationService(system: system, wait: { _ in })
    let plan = try service.plan([request("txt")])
    system.scriptedReads = [nil, other, editor]
    let report = try await service.execute(plan)
    #expect(report.succeeded)
    #expect(report.outcomes[0].verified)
    #expect(system.scriptedReads.isEmpty)
  }

  @Test func propagationBeyondTheOldRetryWindowSucceeds() async throws {
    let system = FakeSystem()
    system.persist = false
    var elapsed: UInt64 = 0
    let service = AssociationService(
      system: system,
      wait: { delay in
        elapsed += delay
        if elapsed >= 2_000_000_000 { system.defaults["test.txt"] = editor }
      })
    let report = try await service.execute(service.plan([request("txt")]))
    #expect(report.succeeded)
    #expect(report.outcomes[0].verified)
    #expect(elapsed == 2_000_000_000)
    #expect(system.writes == ["test.txt"])
  }

  @Test func cancellationDuringPropagationStopsRemainingWrites() async throws {
    let system = FakeSystem()
    system.persist = false
    let service = AssociationService(system: system, wait: { _ in throw CancellationError() })
    let plan = try service.plan([request("txt"), request("md")])
    await #expect(throws: CancellationError.self) { try await service.execute(plan) }
    #expect(system.writes == ["test.txt"])
  }

  @Test func noVerifySkipsPostWriteRead() async throws {
    let system = FakeSystem()
    system.persist = false
    let service = AssociationService(system: system)
    let plan = try service.plan([request("txt")])
    let before = system.reads
    let report = try await service.execute(plan, verify: false)
    #expect(report.succeeded)
    #expect(!report.outcomes[0].verified)
    #expect(system.reads == before + 1)
  }

  @Test func cancellationStopsTheBatch() async throws {
    let system = FakeSystem()
    system.cancelWrite = true
    let service = AssociationService(system: system)
    let plan = try service.plan([request("txt"), request("md")])
    await #expect(throws: CancellationError.self) { try await service.execute(plan) }
    #expect(system.writes.isEmpty)
  }

  @Test func executionReadFailureProducesFailure() async throws {
    let system = FakeSystem()
    let service = AssociationService(system: system)
    let plan = try service.plan([request("txt")])
    system.readFails = true
    let report = try await service.execute(plan)
    #expect(!report.succeeded)
    #expect(system.writes.isEmpty)
    #expect(report.outcomes[0].error == "query failed")
  }

  @Test func reportRoundTripsJSON() async throws {
    let system = FakeSystem()
    let service = AssociationService(system: system)
    let report = try await service.execute(service.plan([request("txt")]))
    let data = try JSONEncoder().encode(report)
    let decoded = try JSONDecoder().decode(ExecutionReport.self, from: data)
    #expect(decoded.succeeded)
    #expect(decoded.outcomes[0].change.target == editor)
  }
}
