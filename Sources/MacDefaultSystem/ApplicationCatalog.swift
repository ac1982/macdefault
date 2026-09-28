import Foundation
import MacDefaultCore

struct ApplicationRecord {
  let application: Application
  let extensions: Set<String>
  let contentTypes: Set<String>

  static func read(at url: URL) -> ApplicationRecord? {
    guard url.pathExtension.lowercased() == "app",
      let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty
    else { return nil }
    let name =
      (plist["CFBundleDisplayName"] as? String)
      ?? (plist["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
    var extensions = Set<String>()
    var types = Set<String>()
    for declaration in plist["CFBundleDocumentTypes"] as? [[String: Any]] ?? [] {
      extensions.formUnion(
        strings(declaration["CFBundleTypeExtensions"]).map {
          $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        })
      types.formUnion(strings(declaration["LSItemContentTypes"]))
    }
    return ApplicationRecord(
      application: Application(name: name, bundleID: bundleID, url: url),
      extensions: extensions, contentTypes: types
    )
  }

  private static func strings(_ value: Any?) -> [String] {
    if let value = value as? String { return [value] }
    return (value as? [Any] ?? []).compactMap { $0 as? String }
  }
}

/// One bounded scan per invocation, only when LaunchServices needs a discovery fallback.
@MainActor
final class ApplicationCatalog {
  private let roots: [URL]
  private let maxDepth: Int
  private var cached: [ApplicationRecord]?

  init(
    roots: [URL] = [
      URL(fileURLWithPath: "/Applications"),
      URL(fileURLWithPath: "/System/Applications"),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ], maxDepth: Int = 3
  ) {
    self.roots = roots
    self.maxDepth = maxDepth
  }

  func records() -> [ApplicationRecord] {
    if let cached { return cached }
    var records: [ApplicationRecord] = []
    var seen = Set<URL>()
    for root in roots {
      guard
        let enumerator = FileManager.default.enumerator(
          at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
      else { continue }
      for case let url as URL in enumerator {
        if enumerator.level > maxDepth {
          enumerator.skipDescendants()
          continue
        }
        if url.pathExtension.lowercased() == "app" {
          enumerator.skipDescendants()
          if seen.insert(url.standardizedFileURL).inserted,
            let record = ApplicationRecord.read(at: url)
          {
            records.append(record)
          }
        }
      }
    }
    records.sort {
      ($0.application.name.lowercased(), $0.application.url.path)
        < ($1.application.name.lowercased(), $1.application.url.path)
    }
    cached = records
    return records
  }
}
