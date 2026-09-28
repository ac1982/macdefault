import Foundation
import Testing

@testable import MacDefaultCLI
@testable import MacDefaultCore

@Suite struct PresentationTests {
  @Test func filteringReturnsTheOriginalApplicationIndex() {
    var state = SelectionState(items: [
      PickerItem(title: "Code", detail: "com.microsoft.VSCode"),
      PickerItem(title: "TextEdit", detail: "com.apple.TextEdit"),
      PickerItem(title: "编辑器", detail: "test.unicode"),
    ])
    #expect(state.handle(.search) == .pending)
    #expect(state.handle(.text("text")) == .pending)
    #expect(state.matches == [1])
    #expect(state.handle(.confirm) == .selected(1))
    #expect(state.handle(.escape) == .pending)
    #expect(state.query.isEmpty && !state.searching)
    #expect(state.handle(.search) == .pending)
    #expect(state.handle(.text("编辑")) == .pending)
    #expect(state.handle(.confirm) == .selected(2))
  }

  @Test func noMatchesCannotAccidentallyChooseAnApp() {
    var state = SelectionState(items: [PickerItem(title: "Code", detail: "")])
    _ = state.handle(.search)
    _ = state.handle(.text("not here"))
    _ = state.handle(.move(1))
    #expect(state.matches.isEmpty)
    #expect(state.handle(.confirm) == .pending)
    #expect(state.handle(.cancel) == .cancelled)
  }

  @Test func viewportFollowsSelectionWithoutExceedingTerminalSize() {
    let items = (0..<50).map {
      PickerItem(
        title: "应用程序 \($0) — a very long name", detail: "/Applications/\($0).app", badge: "current")
    }
    var state = SelectionState(items: items)
    _ = state.handle(.last)
    for width in [20, 40, 80] {
      let lines = state.frame(
        title: "Open .txt with", subtitle: "Current · Code", width: width, height: 16,
        style: TerminalStyle())
      #expect(lines.count < 16)
      #expect(lines.allSatisfy { TerminalText.width($0) < width })
      #expect(lines.joined().contains("50/50") || width == 20)
      #expect(!lines.joined().contains("\u{1B}"))
    }
  }

  @Test func unicodeAndTerminalControlsAreHandled() {
    #expect(TerminalText.width("中文") == 4)
    #expect(TerminalText.width("e\u{301}") == 1)
    #expect(TerminalText.width("👩‍💻") == 2)
    #expect(TerminalText.fit("中文应用", width: 5) == "中文…")
    #expect(!TerminalText.clean("bad\u{1B}[2J\nname").contains("\u{1B}"))
    #expect(!TerminalText.clean("bad\nname").contains("\n"))
  }

  @Test func multipleTypesCollapseWithoutHidingMixedDefaultsOrAliases() throws {
    let a = Application(
      name: "Editor", bundleID: "test.editor", url: URL(fileURLWithPath: "/Editor.app"))
    let b = Application(
      name: "Other", bundleID: "test.other", url: URL(fileURLWithPath: "/Other.app"))
    let ext = try FileExtension("txt")
    let plan = AssociationPlan(changes: [
      AssociationChange(
        extensions: [ext],
        type: ContentType(identifier: "test.first", extensions: ["txt", "text"]), previous: a,
        target: a),
      AssociationChange(
        extensions: [ext], type: ContentType(identifier: "test.second", extensions: ["txt"]),
        previous: b, target: a),
    ])
    let compact = Output.planLines(plan, display: try DisplayOptions.parse(["--plain"])).joined(
      separator: "\n")
    #expect(compact.components(separatedBy: ".txt").count == 2)
    #expect(compact.contains("Editor / Other"))
    #expect(compact.contains("Also affects .text"))
    #expect(!compact.contains("test.first"))
    #expect(!compact.contains("\u{1B}"))
    let detailed = Output.planLines(
      plan, display: try DisplayOptions.parse(["--plain", "--verbose"])
    ).joined()
    #expect(detailed.contains("test.first") && detailed.contains("test.second"))
  }

  @Test func verboseMetadataCannotInjectTerminalControls() throws {
    let malicious = "test.bad\u{1B}[2J\nspoofed"
    let app = Application(
      name: malicious, bundleID: malicious,
      url: URL(fileURLWithPath: "/Fake.app"))
    let change = AssociationChange(
      extensions: [try FileExtension("txt")],
      type: ContentType(identifier: malicious, extensions: ["txt", malicious]),
      previous: app, target: app)
    let display = try DisplayOptions.parse(["--plain", "--verbose"])
    let lines =
      Output.planLines(AssociationPlan(changes: [change]), display: display)
      + Output.reportLines(
        ExecutionReport(outcomes: [
          ChangeOutcome(change: change, state: .changed, verified: true, error: nil)
        ]), display: display)
    #expect(lines.allSatisfy { !$0.contains("\u{1B}") && !$0.contains("\n") })
  }

  @Test func partialFailuresRemainVisibleInCompactOutput() throws {
    let app = Application(
      name: "Editor", bundleID: "test.editor", url: URL(fileURLWithPath: "/Editor.app"))
    let ext = try FileExtension("txt")
    let change = AssociationChange(
      extensions: [ext], type: ContentType(identifier: "test.txt", extensions: ["txt"]),
      previous: nil, target: app)
    let report = ExecutionReport(outcomes: [
      ChangeOutcome(change: change, state: .changed, verified: true, error: nil),
      ChangeOutcome(change: change, state: .failed, verified: false, error: "Permission denied"),
    ])
    let lines = Output.reportLines(report, display: try DisplayOptions.parse(["--plain"])).joined()
    #expect(lines.contains("Some changes could not be applied"))
    #expect(lines.contains("Permission denied"))
    #expect(lines.contains("failed"))
  }
}
