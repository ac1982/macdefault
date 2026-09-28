import Foundation

public struct UserError: LocalizedError, Equatable, Sendable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

public struct FileExtension: Hashable, Codable, Sendable, CustomStringConvertible {
  public let value: String

  public init(_ input: String) throws {
    var value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.hasPrefix(".") { value.removeFirst() }
    guard !value.isEmpty, value.utf8.count <= 255,
      value.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.contains($0) || "_+-".unicodeScalars.contains($0)
      })
    else {
      throw UserError("Invalid extension '\(input)'. Use a single extension, such as txt or .docx.")
    }
    self.value = value
  }

  public var description: String { ".\(value)" }
  public init(from decoder: any Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

public struct Application: Hashable, Codable, Sendable {
  public let name: String
  public let bundleID: String
  public let url: URL

  public init(name: String, bundleID: String, url: URL) {
    self.name = name
    self.bundleID = bundleID
    self.url = url.standardizedFileURL
  }
}

public struct ContentType: Hashable, Codable, Sendable {
  public let identifier: String
  public let extensions: [String]

  public init(identifier: String, extensions: [String]) {
    self.identifier = identifier
    self.extensions = extensions
  }

  // Never walk up the conformance tree when changing a file association.
  public func isSpecific(to ext: FileExtension) -> Bool {
    !Self.genericIdentifiers.contains(identifier)
      && extensions.contains { $0.lowercased() == ext.value }
  }

  public static let genericIdentifiers: Set<String> = [
    "public.item", "public.content", "public.data", "public.directory",
    "public.folder", "public.volume", "public.composite-content",
  ]
}

public struct AssociationRequest: Sendable {
  public let ext: FileExtension
  public let application: Application
  public init(ext: FileExtension, application: Application) {
    self.ext = ext
    self.application = application
  }
}

public struct AssociationChange: Codable, Sendable {
  public let extensions: [FileExtension]
  public let type: ContentType
  public let previous: Application?
  public let target: Application
  public var needsChange: Bool { previous?.bundleID != target.bundleID }
}

public struct AssociationPlan: Codable, Sendable {
  public let changes: [AssociationChange]
}

public struct TypeStatus: Codable, Sendable {
  public let type: ContentType
  public let application: Application?
}

public struct ExtensionStatus: Codable, Sendable {
  public let ext: FileExtension
  public let defaults: [TypeStatus]
  public let candidates: [Application]
}

public enum OutcomeState: String, Codable, Sendable {
  case changed, unchanged, failed, skipped
}

public struct ChangeOutcome: Codable, Sendable {
  public let change: AssociationChange
  public let state: OutcomeState
  public let verified: Bool
  public let error: String?
}

public struct ExecutionReport: Codable, Sendable {
  public let outcomes: [ChangeOutcome]
  public var succeeded: Bool { outcomes.allSatisfy { $0.state != .failed && $0.state != .skipped } }
}
