import Foundation

/// The only boundary with the operating system. Planning uses read methods only.
@MainActor
public protocol AssociationSystem {
  func contentTypes(for ext: FileExtension) throws -> [ContentType]
  func defaultApplication(for type: ContentType) throws -> Application?
  func applications(for ext: FileExtension, types: [ContentType]) throws -> [Application]
  func application(matching selector: String) throws -> Application
  func register(_ application: Application) throws
  func setDefault(_ application: Application, for type: ContentType) async throws
}

@MainActor
public final class AssociationService {
  private let system: any AssociationSystem
  private let wait: @MainActor (UInt64) async throws -> Void

  public init(
    system: any AssociationSystem,
    wait: @escaping @MainActor (UInt64) async throws -> Void = {
      try await Task.sleep(nanoseconds: $0)
    }
  ) {
    self.system = system
    self.wait = wait
  }

  private func types(for ext: FileExtension) throws -> [ContentType] {
    var seen = Set<String>()
    let types = try system.contentTypes(for: ext).filter {
      $0.isSpecific(to: ext) && seen.insert($0.identifier).inserted
    }
    guard !types.isEmpty else { throw UserError("No specific content type found for \(ext).") }
    return types
  }

  public func inspect(_ ext: FileExtension, includeCandidates: Bool = true) throws
    -> ExtensionStatus
  {
    let types = try types(for: ext)
    let defaults = try types.map {
      TypeStatus(type: $0, application: try system.defaultApplication(for: $0))
    }
    guard includeCandidates else {
      return ExtensionStatus(ext: ext, defaults: defaults, candidates: [])
    }
    var seen = Set<String>()
    let candidates = try
      (defaults.compactMap(\.application) + system.applications(for: ext, types: types))
      .filter { seen.insert($0.bundleID).inserted }
    return ExtensionStatus(ext: ext, defaults: defaults, candidates: candidates)
  }

  public func resolve(_ selector: String) throws -> Application {
    try system.application(matching: selector)
  }

  /// Resolve the entire batch before any writes. Shared UTIs cannot have conflicting targets.
  public func plan(_ requests: [AssociationRequest]) throws -> AssociationPlan {
    guard !requests.isEmpty else { throw UserError("No associations requested.") }
    var changes: [AssociationChange] = []
    var indices: [String: Int] = [:]
    for request in requests {
      for type in try types(for: request.ext) {
        if let index = indices[type.identifier] {
          let existing = changes[index]
          guard existing.target.bundleID == request.application.bundleID else {
            throw UserError("Conflicting applications for shared content type \(type.identifier).")
          }
          if !existing.extensions.contains(request.ext) {
            changes[index] = AssociationChange(
              extensions: existing.extensions + [request.ext], type: type,
              previous: existing.previous, target: existing.target
            )
          }
        } else {
          indices[type.identifier] = changes.count
          changes.append(
            AssociationChange(
              extensions: [request.ext], type: type,
              previous: try system.defaultApplication(for: type), target: request.application
            ))
        }
      }
    }
    return AssociationPlan(changes: changes)
  }

  public func execute(
    _ plan: AssociationPlan, verify: Bool = true, failFast: Bool = false
  ) async throws -> ExecutionReport {
    var outcomes: [ChangeOutcome] = []
    var registration: [URL: Result<Void, any Error>] = [:]
    var stopped = false
    for change in plan.changes {
      try Task.checkCancellation()
      if stopped {
        outcomes.append(
          ChangeOutcome(
            change: change, state: .skipped, verified: false,
            error: "Stopped after an earlier failure."))
        continue
      }
      do {
        // Re-read the current state: a preview may have become stale.
        let current = try system.defaultApplication(for: change.type)
        let needsChange = current?.bundleID != change.target.bundleID
        if needsChange {
          let result =
            registration[change.target.url] ?? Result { try system.register(change.target) }
          registration[change.target.url] = result
          try result.get()
          try await system.setDefault(change.target, for: change.type)
        }
        if verify { try await verifyDefault(change) }
        outcomes.append(
          ChangeOutcome(
            change: change, state: needsChange ? .changed : .unchanged, verified: verify, error: nil
          ))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        outcomes.append(
          ChangeOutcome(
            change: change, state: .failed, verified: false, error: error.localizedDescription))
        stopped = failFast
      }
    }
    return ExecutionReport(outcomes: outcomes)
  }

  private func verifyDefault(_ change: AssociationChange) async throws {
    var actual: Application?
    // LaunchServices can propagate a change asynchronously. Keep retries bounded.
    // Allow up to five seconds of propagation, checking every 250 ms.
    for attempt in 0...20 {
      try Task.checkCancellation()
      if attempt > 0 { try await wait(250_000_000) }
      actual = try system.defaultApplication(for: change.type)
      if actual?.bundleID == change.target.bundleID { return }
    }
    throw UserError(
      "Verification timed out after 5 seconds for \(change.type.identifier): expected \(change.target.bundleID), got \(actual?.bundleID ?? "no default")."
    )
  }
}
