import Foundation
import Testing

@testable import MacDefaultCore

@Suite struct ModelTests {
  @Test(arguments: ["txt", ".TXT", "  .TxT\n"])
  func normalizesExtensions(input: String) throws {
    #expect(try FileExtension(input).value == "txt")
  }

  @Test(arguments: [
    "", ".", "..txt", "tar.gz", "/txt", "a\\b", "a b", "*", "a\u{0}b",
    String(repeating: "a", count: 256),
  ])
  func rejectsInvalidExtensions(input: String) {
    #expect(throws: UserError.self) { try FileExtension(input) }
  }

  @Test func decoderEnforcesValidation() {
    #expect(throws: UserError.self) {
      try JSONDecoder().decode(FileExtension.self, from: Data("\"../txt\"".utf8))
    }
  }

  @Test(arguments: Array(ContentType.genericIdentifiers))
  func rejectsGenericTypes(identifier: String) throws {
    #expect(
      try !ContentType(identifier: identifier, extensions: ["txt"]).isSpecific(
        to: FileExtension("txt")))
  }

  @Test func exactTagMatchIsCaseInsensitive() throws {
    #expect(
      try ContentType(identifier: "test.txt", extensions: ["TXT"]).isSpecific(
        to: FileExtension("txt")))
  }
}

@Suite @MainActor struct SuiteTests {
  @Test(arguments: OfficeSuite.allCases)
  func mapsEveryOfficeExtension(suite: OfficeSuite) throws {
    #expect(suite.assignments.map(\.extension) == OfficeSuite.extensions)
    let system = FakeSystem()
    for descriptor in SuiteApplication.allCases {
      system.apps[descriptor.selectors[0]] = Application(
        name: descriptor.name, bundleID: descriptor.rawValue,
        url: URL(fileURLWithPath: "/Applications/\(descriptor.name).app")
      )
    }
    let requests = try suite.requests(using: AssociationService(system: system))
    #expect(requests.map(\.application.bundleID) == suite.assignments.map { $0.app.rawValue })
    #expect(system.resolutions.count == Set(suite.assignments.map(\.app)).count)
  }

  @Test func specialOfficeMappings() {
    #expect(OfficeSuite.apple.assignments.first { $0.extension == "rtf" }?.app == .textEdit)
    #expect(OfficeSuite.apple.assignments.first { $0.extension == "csv" }?.app == .numbers)
    #expect(OfficeSuite.microsoft.assignments.first { $0.extension == "rtf" }?.app == .word)
    #expect(OfficeSuite.microsoft.assignments.first { $0.extension == "csv" }?.app == .excel)
  }

  @Test func missingSuiteAppFailsBeforeWrites() {
    let system = FakeSystem()
    system.apps[SuiteApplication.word.selectors[0]] = editor
    #expect(throws: UserError.self) {
      try OfficeSuite.microsoft.requests(using: AssociationService(system: system))
    }
    #expect(system.writes.isEmpty)
    #expect(system.registrations.isEmpty)
  }

  @Test func wpsFallsBackFromPathToBundleID() throws {
    let system = FakeSystem()
    system.apps["com.kingsoft.wpsoffice.mac"] = editor
    let app = try SuiteApplication.wps.resolve(using: AssociationService(system: system))
    #expect(app == editor)
    #expect(system.resolutions == ["/Applications/wpsoffice.app", "com.kingsoft.wpsoffice.mac"])
  }
}
