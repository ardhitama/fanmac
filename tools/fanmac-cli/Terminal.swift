//
//  Terminal.swift
//  fanmac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Colour, line layout and raw keyboard input for the terminal.
//

import Darwin

/// Ardvis Dark's terminal roles, as the app's theme (FanMacTheme.swift),
/// drawn only when the output is a terminal and NO_COLOR isn't set. Text
/// comes in two roles, never fainter: plain text and the palette's dim text
/// (ANSI bright black), each at 4.5:1 or more on the Mac's background. The
/// accent is the theme's grey, as the app's is.
struct Palette {
    enum Role {
        case text
        case secondary
        case accent
        case warning
        case destructive

        var rgb: (UInt8, UInt8, UInt8) {
            switch self {
            case .text: return (0xAB, 0xB2, 0xBF)
            case .secondary: return (0x7E, 0x85, 0x94)
            case .accent: return (0xA3, 0xA3, 0xA3)
            case .warning: return (0xE2, 0xC0, 0x8D)
            case .destructive: return (0xFF, 0x66, 0x4A)
            }
        }
    }

    let enabled: Bool
    private let trueColor: Bool

    init(fd: Int32) {
        let term = getenv("TERM").map { String(cString: $0) } ?? ""
        enabled = isatty(fd) == 1 && getenv("NO_COLOR") == nil && term != "dumb"
        let colorTerm = getenv("COLORTERM").map { String(cString: $0) } ?? ""
        trueColor = colorTerm.contains("truecolor") || colorTerm.contains("24bit")
    }

    func paint(_ text: String, _ role: Role?, bold: Bool = false) -> String {
        guard enabled, role != nil || bold else { return text }
        var codes: [String] = []
        if bold { codes.append("1") }
        if let (r, g, b) = role?.rgb {
            if trueColor {
                codes.append("38;2;\(r);\(g);\(b)")
            } else {
                // Nearest colour in the xterm 6×6×6 cube.
                func level(_ v: UInt8) -> Int { Int((Double(v) / 255 * 5).rounded()) }
                codes.append("38;5;\(16 + 36 * level(r) + 6 * level(g) + level(b))")
            }
        }
        return "\u{1B}[\(codes.joined(separator: ";"))m\(text)\u{1B}[0m"
    }
}

/// A line of styled runs that can be cut to the terminal's width without
/// splitting an escape sequence.
struct StyledLine {
    private(set) var runs: [(text: String, role: Palette.Role?, bold: Bool)] = []

    init() {}

    init(_ text: String, _ role: Palette.Role? = nil, bold: Bool = false) {
        add(text, role, bold: bold)
    }

    var width: Int { runs.reduce(0) { $0 + $1.text.count } }

    @discardableResult
    mutating func add(_ text: String, _ role: Palette.Role? = nil, bold: Bool = false) -> StyledLine {
        runs.append((text, role, bold))
        return self
    }

    /// Pads with spaces to `column`, for aligned columns.
    mutating func pad(to column: Int) {
        if width < column { add(String(repeating: " ", count: column - width)) }
    }

    func render(_ palette: Palette, maxWidth: Int) -> String {
        var remaining = maxWidth
        var out = ""
        for run in runs where remaining > 0 {
            let text = run.text.count > remaining ? String(run.text.prefix(remaining)) : run.text
            remaining -= text.count
            out += palette.paint(text, run.role, bold: run.bold)
        }
        return out
    }
}

/// Splits `text` into lines of at most `width` characters at spaces.
func wrap(_ text: String, width: Int) -> [String] {
    guard width > 10 else { return [text] }
    var lines: [String] = []
    var current = ""
    for word in text.split(separator: " ") {
        if current.isEmpty {
            current = String(word)
        } else if current.count + 1 + word.count <= width {
            current += " " + word
        } else {
            lines.append(current)
            current = String(word)
        }
    }
    if !current.isEmpty { lines.append(current) }
    return lines
}

/// Terminal size in columns and rows.
func terminalSize() -> (columns: Int, rows: Int) {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return (80, 24) }
    return (Int(size.ws_col), Int(size.ws_row))
}

func writeOut(_ text: String) {
    var bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeMutableBytes { write(STDOUT_FILENO, $0.baseAddress! + offset, $0.count - offset) }
        if written <= 0 { return }
        offset += written
    }
}

// MARK: - Raw mode

/// The terminal settings to restore, kept global so a signal handler can reach them.
nonisolated(unsafe) private var savedTermios: termios?

private let enterScreen = "\u{1B}[?1049h\u{1B}[?25l"
private let leaveScreen = "\u{1B}[?25h\u{1B}[?1049l"

/// Switches to the alternate screen with unbuffered, unechoed input, and puts
/// the terminal back on `restore()` or on SIGTERM / SIGHUP.
enum RawTerminal {
    static func enter() -> Bool {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return false }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return false }
        savedTermios = original

        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 0
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

        for sig in [SIGTERM, SIGHUP] {
            signal(sig) { _ in
                if var saved = savedTermios { tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved) }
                _ = leaveScreen.withCString { write(STDOUT_FILENO, $0, strlen($0)) }
                _exit(1)
            }
        }
        writeOut(enterScreen)
        return true
    }

    static func restore() {
        writeOut(leaveScreen)
        if var saved = savedTermios {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
        }
    }
}

enum Key: Equatable {
    case up, down, left, right
    case character(Character)
    case escape
    case interrupt
}

/// Waits up to `timeout` milliseconds for input and decodes the keys read.
func readKeys(timeout: Int32) -> [Key] {
    var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    guard poll(&pfd, 1, timeout) > 0 else { return [] }
    var buffer = [UInt8](repeating: 0, count: 64)
    let count = read(STDIN_FILENO, &buffer, buffer.count)
    guard count > 0 else { return [] }
    let bytes = Array(buffer[0..<count])

    var keys: [Key] = []
    var i = 0
    while i < bytes.count {
        let byte = bytes[i]
        if byte == 0x1B {
            // ESC [ X or ESC O X are arrows; a lone ESC is the Escape key.
            if i + 2 < bytes.count, bytes[i + 1] == 0x5B || bytes[i + 1] == 0x4F {
                switch bytes[i + 2] {
                case 0x41: keys.append(.up)
                case 0x42: keys.append(.down)
                case 0x43: keys.append(.right)
                case 0x44: keys.append(.left)
                default: break
                }
                i += 3
                continue
            }
            keys.append(.escape)
        } else if byte == 0x03 {
            keys.append(.interrupt)
        } else if byte < 0x80 {
            keys.append(.character(Character(UnicodeScalar(byte))))
        }
        i += 1
    }
    return keys
}
