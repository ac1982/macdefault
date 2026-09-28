import AppKit
import CoreServices
import MacDefaultCore
import UniformTypeIdentifiers

@MainActor
public final class NativeAssociationSystem: AssociationSystem {
  private let workspace: NSWorkspace
  private let catalog: ApplicationCatalog

  public init() {
    workspace = .shared
    catalog = ApplicationCatalog()
  }

  public func contentTypes(for ext: FileExtension) throws -> [ContentType] {
    var native = UTType.types(tag: ext.value, tagClass: .filenameExtension, conformingTo: nil)
    if native.isEmpty, let dynamic = UTType(filenameExtension: ext.value) { native = [dynamic] }
    return native.map {
      ContentType(identifier: $0.identifier, extensions: $0.tags[.filenameExtension] ?? [])
    }
  }

  public func defaultApplication(for type: ContentType) throws -> Application? {
    guard let url = workspace.urlForApplication(toOpen: try nativeType(type)) else { return nil }
    guard let record = ApplicationRecord.read(at: url) else {
      throw UserError("Cannot read default application at \(url.path).")
    }
    return record.application
  }

  public func applications(for ext: FileExtension, types: [ContentType]) throws -> [Application] {
    var apps: [Application] = []
    for type in types {
      apps += try workspace.urlsForApplications(toOpen: nativeType(type))
        .compactMap { ApplicationRecord.read(at: $0)?.application }
    }
    let identifiers = Set(types.map(\.identifier))
    apps += catalog.records().filter {
      $0.extensions.contains(ext.value) || !$0.contentTypes.isDisjoint(with: identifiers)
    }.map(\.application)
    var seen = Set<String>()
    return apps.filter { seen.insert($0.bundleID).inserted }.sorted {
      ($0.name.lowercased(), $0.bundleID) < ($1.name.lowercased(), $1.bundleID)
    }
  }

  public func application(matching selector: String) throws -> Application {
    let isPath = selector.contains("/") || selector.hasSuffix(".app")
    if isPath {
      let expanded = (selector as NSString).expandingTildeInPath
      let url = URL(fileURLWithPath: expanded).standardizedFileURL
      guard let record = ApplicationRecord.read(at: url) else {
        throw UserError("Not a readable application bundle: \(url.path)")
      }
      return record.application
    }
    if let url = workspace.urlForApplication(withBundleIdentifier: selector),
      let record = ApplicationRecord.read(at: url)
    {
      return record.application
    }
    if let record = catalog.records().first(where: { $0.application.bundleID == selector }) {
      return record.application
    }
    throw UserError("Application not found: \(selector). Supply a bundle ID or an .app path.")
  }

  public func register(_ application: Application) throws {
    let status = LSRegisterURL(application.url as CFURL, true)
    guard status == noErr else {
      throw UserError(
        "Cannot register \(application.name) with LaunchServices (OSStatus \(status)).")
    }
  }

  public func setDefault(_ application: Application, for type: ContentType) async throws {
    let identifier = try nativeType(type).identifier
    // Use the same public LaunchServices API as duti, without an external process.
    // The service polls the effective default because propagation is asynchronous.
    let status = LSSetDefaultRoleHandlerForContentType(
      identifier as CFString, LSRolesMask.all, application.bundleID as CFString)
    guard status == noErr else {
      throw UserError(
        "Cannot set \(application.name) for \(identifier) (OSStatus \(status)).")
    }
  }

  private func nativeType(_ type: ContentType) throws -> UTType {
    guard !ContentType.genericIdentifiers.contains(type.identifier),
      let native = UTType(type.identifier)
    else {
      throw UserError("Unsupported or overly broad content type: \(type.identifier)")
    }
    return native
  }
}
