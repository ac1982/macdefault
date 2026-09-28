import Darwin
import Foundation

struct TerminalStyle {
  var color = false
  func paint(_ text: String, _ code: String) -> String {
    color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
  }
  func bold(_ text: String) -> String { paint(text, "1") }
  func muted(_ text: String) -> String { paint(text, "2") }
  func accent(_ text: String) -> String { paint(text, "1;36") }
  func good(_ text: String) -> String { paint(text, "32") }
  func warning(_ text: String) -> String { paint(text, "33") }
  func bad(_ text: String) -> String { paint(text, "31") }
}

enum TerminalText {
  /// Never let application metadata inject terminal controls or extra rows.
  static func clean(_ text: String) -> String {
    text.unicodeScalars.map {
      let n = $0.value
      let control =
        n < 32 || (127...159).contains(n) || n == 0x2028 || n == 0x2029
        || (0x202A...0x202E).contains(n) || (0x2066...0x2069).contains(n)
      return control ? " " : String($0)
    }.joined()
  }

  static func width(_ text: String) -> Int {
    clean(text).reduce(0) { $0 + cells($1) }
  }

  private static func cells(_ character: Character) -> Int {
    let scalars = character.unicodeScalars
    if scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) {
      return 2
    }
    if scalars.contains(where: {
      let n = $0.value
      return (0x1100...0x115F).contains(n) || (0x2E80...0xA4CF).contains(n)
        || (0xAC00...0xD7A3).contains(n) || (0xF900...0xFAFF).contains(n)
        || (0xFE10...0xFE6F).contains(n) || (0xFF01...0xFF60).contains(n)
        || (0xFFE0...0xFFE6).contains(n) || (0x20000...0x3FFFD).contains(n)
    }) {
      return 2
    }
    return 1
  }

  static func fit(_ text: String, width: Int) -> String {
    let text = clean(text)
    guard width > 0 else { return "" }
    guard self.width(text) > width else { return text }
    var result = ""
    var used = 0
    for character in text {
      let size = cells(character)
      if used + size > width - 1 { break }
      result.append(character)
      used += size
    }
    return result + "…"
  }

  static func pad(_ text: String, to width: Int) -> String {
    let text = fit(text, width: width)
    return text + String(repeating: " ", count: max(0, width - self.width(text)))
  }
}

enum Console {
  static var interactive: Bool { isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 }
  static var size: (width: Int, height: Int) {
    var value = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &value) == 0, value.ws_col > 0, value.ws_row > 0 {
      return (Int(value.ws_col), Int(value.ws_row))
    }
    return (80, 24)
  }
  static func style(plain: Bool = false) -> TerminalStyle {
    let env = ProcessInfo.processInfo.environment
    return TerminalStyle(
      color: !plain && isatty(STDOUT_FILENO) != 0
        && env["NO_COLOR"] == nil && env["TERM"] != "dumb")
  }
  static func write(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
  }
  static func lines(_ lines: [String]) { write(lines.joined(separator: "\n") + "\n") }
  static func error(_ text: String) {
    FileHandle.standardError.write(Data("macdefault: \(text)\n".utf8))
  }
}
