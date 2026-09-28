import Foundation

public enum OfficeSuite: String, CaseIterable, Codable, Sendable {
  case microsoft, wps, apple

  public var assignments: [(extension: String, app: SuiteApplication)] {
    switch self {
    case .microsoft:
      return [
        ("doc", .word), ("docx", .word), ("xls", .excel), ("xlsx", .excel),
        ("ppt", .powerPoint), ("pptx", .powerPoint), ("rtf", .word), ("csv", .excel),
      ]
    case .wps:
      return Self.extensions.map { ($0, .wps) }
    case .apple:
      return [
        ("doc", .pages), ("docx", .pages), ("xls", .numbers), ("xlsx", .numbers),
        ("ppt", .keynote), ("pptx", .keynote), ("rtf", .textEdit), ("csv", .numbers),
      ]
    }
  }

  public static let extensions = ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf", "csv"]

  @MainActor
  public func requests(using service: AssociationService) throws -> [AssociationRequest] {
    var resolved: [SuiteApplication: Application] = [:]
    return try assignments.map { ext, descriptor in
      let app = try resolved[descriptor] ?? descriptor.resolve(using: service)
      resolved[descriptor] = app
      return AssociationRequest(ext: try FileExtension(ext), application: app)
    }
  }
}

public enum SuiteApplication: String, CaseIterable, Sendable {
  case word, excel, powerPoint, wps, pages, numbers, keynote, textEdit

  public var name: String {
    switch self {
    case .word: "Microsoft Word"
    case .excel: "Microsoft Excel"
    case .powerPoint: "Microsoft PowerPoint"
    case .wps: "WPS Office"
    case .pages: "Pages"
    case .numbers: "Numbers"
    case .keynote: "Keynote"
    case .textEdit: "TextEdit"
    }
  }

  public var selectors: [String] {
    switch self {
    case .word: ["com.microsoft.Word"]
    case .excel: ["com.microsoft.Excel"]
    case .powerPoint: ["com.microsoft.Powerpoint"]
    case .wps:
      ["/Applications/wpsoffice.app", "com.kingsoft.wpsoffice.mac", "com.kingsoft.wpsoffice"]
    case .pages: ["com.apple.iWork.Pages"]
    case .numbers: ["com.apple.iWork.Numbers"]
    case .keynote: ["com.apple.iWork.Keynote"]
    case .textEdit: ["com.apple.TextEdit"]
    }
  }

  @MainActor
  public func resolve(using service: AssociationService) throws -> Application {
    for selector in selectors {
      if let app = try? service.resolve(selector) { return app }
    }
    throw UserError("\(name) is not installed or could not be resolved.")
  }
}
