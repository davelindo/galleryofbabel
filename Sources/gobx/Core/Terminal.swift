import Darwin
import Foundation

struct TerminalSize: Sendable {
    var cols: Int
    var rows: Int

    static let fallback = TerminalSize(cols: 80, rows: 24)
}

enum Terminal {
    struct RawModeState {
        let original: termios
    }

    static func isInteractiveStdout() -> Bool {
        guard isatty(fileno(stdout)) != 0 else { return false }
        let term = ProcessInfo.processInfo.environment["TERM"] ?? ""
        return term != "dumb" && !term.isEmpty
    }

    static func isInteractiveStdin() -> Bool {
        isatty(fileno(stdin)) != 0
    }

    static func stdoutSize() -> TerminalSize {
        var w = winsize()
        if ioctl(fileno(stdout), TIOCGWINSZ, &w) == 0 {
            let cols = max(20, Int(w.ws_col))
            let rows = max(10, Int(w.ws_row))
            return TerminalSize(cols: cols, rows: rows)
        }
        return .fallback
    }

    static func writeStdout(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }

    static func enableRawMode() -> RawModeState? {
        var term = termios()
        guard tcgetattr(fileno(stdin), &term) == 0 else { return nil }
        let original = term

        term.c_lflag &= ~UInt(ECHO | ICANON)
        term.c_iflag &= ~UInt(IXON | ICRNL)
        withUnsafeMutablePointer(to: &term.c_cc) { ptr in
            ptr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { buf in
                buf[Int(VMIN)] = 0
                buf[Int(VTIME)] = 0
            }
        }

        guard tcsetattr(fileno(stdin), TCSAFLUSH, &term) == 0 else { return nil }
        return RawModeState(original: original)
    }

    static func restoreMode(_ state: RawModeState) {
        var term = state.original
        _ = tcsetattr(fileno(stdin), TCSAFLUSH, &term)
    }
}

enum ANSI {
    static let esc = "\u{1b}"
    static let clearScreen = "\(esc)[2J"
    static let home = "\(esc)[H"
    static let clearToEnd = "\(esc)[J"
    static let hideCursor = "\(esc)[?25l"
    static let showCursor = "\(esc)[?25h"
    static let altScreenOn = "\(esc)[?1049h"
    static let altScreenOff = "\(esc)[?1049l"
    static let reset = "\(esc)[0m"
    static let bold = "\(esc)[1m"
    static let dim = "\(esc)[2m"
    static let red = "\(esc)[31m"
    static let green = "\(esc)[32m"
    static let yellow = "\(esc)[33m"
    static let blue = "\(esc)[34m"
    static let magenta = "\(esc)[35m"
    static let cyan = "\(esc)[36m"
    static let gray = "\(esc)[90m"

    static func move(row: Int, col: Int) -> String {
        "\(esc)[\(row);\(col)H"
    }
}
