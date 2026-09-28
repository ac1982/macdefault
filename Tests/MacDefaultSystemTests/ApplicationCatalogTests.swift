import Foundation
import MacDefaultCore
import Testing

@testable import MacDefaultSystem

struct TemporaryDirectory {
  let url: URL
  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }
  func remove() { try? FileManager.default.removeItem(at: url) }

  func app(
    _ name: String, plist: [String: Any],
    format: PropertyListSerialization.PropertyListFormat = .xml
  ) throws -> URL {
    let app = url.appendingPathComponent(name)
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(
      fromPropertyList: plist, format: format, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return app
  }
}

@Suite struct ApplicationRecordTests {
  @Test(arguments: [false, true])
  func readsXMLAndBinaryPlists(binary: Bool) throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let url = try directory.app(
      "Editor.app",
      plist: [
        "CFBundleIdentifier": "test.editor", "CFBundleDisplayName": "编辑器",
        "CFBundleDocumentTypes": [
          ["CFBundleTypeExtensions": ["TXT", ".md"], "LSItemContentTypes": "public.plain-text"],
          [
            "CFBundleTypeExtensions": "csv",
            "LSItemContentTypes": ["public.comma-separated-values-text"],
          ],
        ],
      ], format: binary ? .binary : .xml)
    let record = try #require(ApplicationRecord.read(at: url))
    #expect(record.application.name == "编辑器")
    #expect(record.application.bundleID == "test.editor")
    #expect(record.extensions == ["txt", "md", "csv"])
    #expect(record.contentTypes == ["public.plain-text", "public.comma-separated-values-text"])
  }

  @Test func nameFallbackAndMalformedDeclarations() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let url = try directory.app(
      "Fallback.app",
      plist: [
        "CFBundleIdentifier": "test.fallback",
        "CFBundleDocumentTypes": [
          ["CFBundleTypeExtensions": 42, "LSItemContentTypes": [1, "test.valid"]]
        ],
      ])
    let record = try #require(ApplicationRecord.read(at: url))
    #expect(record.application.name == "Fallback")
    #expect(record.extensions.isEmpty)
    #expect(record.contentTypes == ["test.valid"])
  }

  @Test func rejectsInvalidBundle() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let missingID = try directory.app("Missing.app", plist: ["CFBundleName": "Missing"])
    let wrongSuffix = try directory.app("Wrong.folder", plist: ["CFBundleIdentifier": "test.wrong"])
    #expect(ApplicationRecord.read(at: missingID) == nil)
    #expect(ApplicationRecord.read(at: wrongSuffix) == nil)
    #expect(ApplicationRecord.read(at: directory.url.appendingPathComponent("Absent.app")) == nil)
  }

  @Test func rejectsCorruptPlist() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let app = try directory.app("Corrupt.app", plist: [:])
    try Data("not a plist".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
    #expect(ApplicationRecord.read(at: app) == nil)
  }
}

@Suite @MainActor struct ApplicationCatalogTests {
  @Test func boundsScanSkipsNestedAppsAndDeduplicatesRoots() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let plist = ["CFBundleIdentifier": "test.app"]
    _ = try directory.app("Top.app", plist: plist)
    _ = try directory.app("Top.app/Contents/Hidden.app", plist: plist)
    _ = try directory.app("Folder/Nested.app", plist: ["CFBundleIdentifier": "test.nested"])
    _ = try directory.app("One/Two/TooDeep.app", plist: plist)
    _ = try directory.app(".Hidden.app", plist: plist)
    let catalog = ApplicationCatalog(roots: [directory.url, directory.url], maxDepth: 2)
    #expect(catalog.records().map(\.application.name) == ["Nested", "Top"])
  }

  @Test func cachesOneScanPerInvocation() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let catalog = ApplicationCatalog(roots: [directory.url])
    #expect(catalog.records().isEmpty)
    _ = try directory.app("Later.app", plist: ["CFBundleIdentifier": "test.later"])
    #expect(catalog.records().isEmpty)
  }

  @Test func missingRootIsHarmless() {
    let catalog = ApplicationCatalog(roots: [URL(fileURLWithPath: "/nonexistent-macdefault-tests")])
    #expect(catalog.records().isEmpty)
  }
}

/// Read-only integration with the host's real UTType and LaunchServices databases.
@Suite @MainActor struct NativeReadTests {
  @Test(arguments: [
    "txt", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf", "csv",
    "macdefault-test-unknown-extension",
  ])
  func resolvesSpecificContentTypes(ext: String) throws {
    let system = NativeAssociationSystem()
    let ext = try FileExtension(ext)
    let types = try system.contentTypes(for: ext)
    #expect(!types.isEmpty)
    #expect(types.allSatisfy { $0.isSpecific(to: ext) })
  }

  @Test func resolvesTextEditByBundleIDAndPath() throws {
    let system = NativeAssociationSystem()
    let app = try system.application(matching: "com.apple.TextEdit")
    #expect(app.bundleID == "com.apple.TextEdit")
    #expect(try system.application(matching: app.url.path) == app)
  }

  @Test func bundleIdentifierEndingInAppStillResolves() throws {
    let directory = try TemporaryDirectory()
    defer { directory.remove() }
    let identifier = "test.macdefault.\(UUID().uuidString).app"
    let url = try directory.app("Editor.app", plist: ["CFBundleIdentifier": identifier])
    let system = NativeAssociationSystem(catalog: ApplicationCatalog(roots: [directory.url]))
    #expect(try system.application(matching: identifier).url.path == url.standardizedFileURL.path)
    #expect(try system.application(matching: url.path).url.path == url.standardizedFileURL.path)
  }

  @Test func unknownAppFailsClearly() {
    #expect(throws: UserError.self) {
      try NativeAssociationSystem().application(matching: "test.macdefault.not-installed")
    }
  }

  @Test func genericTypeCannotReachNativeQuery() {
    #expect(throws: UserError.self) {
      try NativeAssociationSystem().defaultApplication(
        for: ContentType(identifier: "public.data", extensions: []))
    }
  }
}
