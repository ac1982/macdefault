import Darwin
import Foundation
import MacDefaultCore

enum SelectionAction: Equatable {
  case move(Int)
  case choose(Int)
  case text(String)
  case first, last, search, backspace, confirm, escape, cancel, ignore
}

enum SelectionResult: Equatable {
  case pending
  case selected(Int)
  case cancelled
}

struct PickerItem {
  let title: String
  let detail: String
  var badge = ""
  var searchText: String?
}

/// Selection and filtering are independent of terminal I/O and rendering.
struct SelectionState {
  let items: [PickerItem]
  var index = 0
  var query = ""
  var searching = false

  init(items: [PickerItem], index: Int = 0) {
    self.items = items
    self.index = min(max(0, index), max(0, items.count - 1))
  }

  var matches: [Int] {
    items.indices.filter {
      query.isEmpty
        || (items[$0].title + " " + (items[$0].searchText ?? items[$0].detail))
          .localizedStandardContains(query)
    }
  }

  mutating func handle(_ action: SelectionAction) -> SelectionResult {
    let count = matches.count
    switch action {
    case .cancel: return .cancelled
    case .escape:
      if searching || !query.isEmpty {
        searching = false
        query = ""
        index = 0
      } else {
        return .cancelled
      }
    case .search: searching = true
    case .text(let text):
      if searching {
        query += text
        index = 0
      }
    case .backspace:
      if !query.isEmpty {
        query.removeLast()
        index = 0
      }
    case .move(let delta):
      if count > 0 { index = (index + delta % count + count) % count }
    case .first: index = 0
    case .last: index = max(0, count - 1)
    case .choose(let choice):
      if (0..<count).contains(choice) { index = choice }
    case .confirm:
      if count > 0 { return .selected(matches[index]) }
    case .ignore: break
    }
    return .pending
  }

  func frame(title: String, subtitle: String, width: Int, height: Int, style: TerminalStyle)
    -> [String]
  {
    let width = max(1, width - 1)  // Keep the cursor out of the terminal's auto-wrap column.
    let capacity = min(8, max(1, height - 9))
    let matches = matches
    let start = min(max(0, index - capacity / 2), max(0, matches.count - capacity))
    let end = min(matches.count, start + capacity)
    var lines = [
      "", "  " + style.bold(TerminalText.fit(title, width: width - 2)),
      "  " + style.muted(TerminalText.fit(subtitle, width: width - 2)), "",
    ]
    for position in start..<end {
      let item = items[matches[position]]
      let marker = position == index ? "›" : " "
      let number = String(position + 1)
      let badge = item.badge.isEmpty ? "" : "  \(item.badge)"
      let body =
        "\(marker) \(TerminalText.pad(number, to: 2)) \(TerminalText.fit(item.title, width: width - 8 - badge.count))\(badge)"
      let row = TerminalText.fit("  " + body, width: width)
      lines.append(position == index ? style.accent(row) : row)
    }
    if matches.isEmpty {
      lines.append(
        "  " + style.muted(TerminalText.fit("No matching applications", width: width - 2)))
    }
    lines.append("")
    if !matches.isEmpty {
      lines.append(
        "  " + style.muted(TerminalText.fit(items[matches[index]].detail, width: width - 2)))
    } else {
      lines.append("")
    }
    let counter = matches.isEmpty ? "0 matches" : "\(index + 1)/\(matches.count)"
    let navigation =
      width < 30
      ? "↑↓ Enter · \(counter)"
      : width < 60
        ? "↑↓  Enter  /  q  · \(counter)"
        : "↑↓ move  Enter choose  / filter  q cancel  · \(counter)"
    let hint = searching ? "Filter: \(query)▏  ·  Enter choose  Esc clear" : navigation
    lines.append("  " + style.muted(TerminalText.fit(hint, width: width - 2)))
    return lines
  }
}

enum TerminalPicker {
  static func choose(items: [PickerItem], title: String, subtitle: String, display: DisplayOptions)
    throws -> Int
  {
    guard !items.isEmpty else { throw InputError("No choices available") }
    guard Console.interactive else {
      throw InputError("Interactive selection requires a terminal; supply --app for scripts")
    }
    if display.plain || ProcessInfo.processInfo.environment["TERM"] == "dumb"
      || Console.size.height < 12
    {
      return try numbered(items: items, title: title)
    }
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
      throw InputError("Cannot read terminal settings")
    }
    var raw = original
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
    raw.c_oflag &= ~tcflag_t(OPOST)
    guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
      throw InputError("Cannot enter interactive mode")
    }
    let saved = original
    let signals = [SIGINT, SIGTERM].map { number in
      let previous = signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler {
        var restored = saved
        tcsetattr(STDIN_FILENO, TCSANOW, &restored)
        Console.write("\u{1B}[?25h\r\n")
        Darwin.exit(128 + number)
      }
      source.resume()
      return (source, previous, number)
    }
    var drawn = 0
    var lastSize = Console.size
    Console.write("\u{1B}[?25l")
    defer {
      erase(lines: drawn)
      Console.write("\u{1B}[?25h")
      tcsetattr(STDIN_FILENO, TCSANOW, &original)
      for (source, previous, number) in signals {
        source.cancel()
        signal(number, previous)
      }
    }
    var state = SelectionState(items: items)
    func draw() {
      let size = Console.size
      // A resize can reflow old rows; reset the viewport instead of guessing their positions.
      if size != lastSize {
        Console.write("\u{1B}[2J\u{1B}[H")
        drawn = 0
        lastSize = size
      }
      erase(lines: drawn)
      let lines = state.frame(
        title: title, subtitle: subtitle, width: size.width, height: size.height,
        style: display.style)
      Console.write(lines.joined(separator: "\r\n") + "\r\n")
      drawn = lines.count
    }
    draw()
    while true {
      guard let byte = readByte(timeout: 150) else {
        if Console.size != lastSize { draw() }
        continue
      }
      let action = readAction(first: byte, searching: state.searching)
      switch state.handle(action) {
      case .pending: draw()
      case .selected(let index): return index
      case .cancelled: throw CancellationError()
      }
    }
  }

  private static func erase(lines: Int) {
    if lines > 0 { Console.write("\u{1B}[\(lines)A\r\u{1B}[J") }
  }

  private static func numbered(items: [PickerItem], title: String) throws -> Int {
    Console.lines(
      ["", "  \(title)", ""]
        + items.enumerated().map {
          "  \($0.offset + 1). \(TerminalText.clean($0.element.title))"
        })
    while true {
      Console.write("\n  Choose a number, or q to cancel: ")
      guard let line = readLine() else { throw CancellationError() }
      let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if value.lowercased() == "q" || value == "\u{1B}" { throw CancellationError() }
      if let number = Int(value), (1...items.count).contains(number) { return number - 1 }
      Console.write("  Enter a number from 1 to \(items.count)\n")
    }
  }

  private static func readByte(timeout: Int32) -> UInt8? {
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    guard poll(&descriptor, 1, timeout) > 0 else { return nil }
    var byte: UInt8 = 0
    return read(STDIN_FILENO, &byte, 1) == 1 ? byte : 4
  }

  private static func readAction(first byte: UInt8, searching: Bool) -> SelectionAction {
    switch byte {
    case 3, 4: return .cancel
    case 10, 13: return .confirm
    case 8, 127: return .backspace
    case 27:
      guard let next = readByte(timeout: 100) else { return .escape }
      guard next == 91 || next == 79 else { return .ignore }
      var sequence: [UInt8] = []
      while sequence.count < 8, let next = readByte(timeout: 100) {
        sequence.append(next)
        if (64...126).contains(next) { break }
      }
      switch String(decoding: sequence, as: UTF8.self) {
      case "A": return .move(-1)
      case "B": return .move(1)
      case "H", "1~": return .first
      case "F", "4~": return .last
      default: return .ignore
      }
    case 113 where !searching: return .cancel
    case 106 where !searching: return .move(1)
    case 107 where !searching: return .move(-1)
    case 47 where !searching: return .search
    case 49...57 where !searching: return .choose(Int(byte - 49))
    default:
      guard byte >= 32 else { return .ignore }
      var bytes = [byte]
      let count = byte < 128 ? 1 : byte & 0xE0 == 0xC0 ? 2 : byte & 0xF0 == 0xE0 ? 3 : 4
      while bytes.count < count, let next = readByte(timeout: 100) { bytes.append(next) }
      return .text(String(decoding: bytes, as: UTF8.self))
    }
  }
}

enum AppSelector {
  static func select(from status: ExtensionStatus, display: DisplayOptions) throws -> Application {
    guard !status.candidates.isEmpty else {
      throw InputError(
        "No applications found for \(status.ext); supply --app with a bundle ID or .app path")
    }
    let current = Set(status.defaults.compactMap { $0.application?.bundleID })
    let items = status.candidates.map {
      PickerItem(
        title: $0.name, detail: display.verbose ? $0.bundleID + "  ·  " + $0.url.path : $0.url.path,
        badge: current.contains($0.bundleID) ? "current" : "", searchText: $0.bundleID)
    }
    let index = try TerminalPicker.choose(
      items: items, title: "Open \(status.ext) with",
      subtitle: "Current  ·  " + Output.names(status.defaults.map(\.application)), display: display)
    return status.candidates[index]
  }
}
