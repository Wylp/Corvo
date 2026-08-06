import AppKit
import SwiftUI

/// Colours a clipping the way an editor would, so a snippet can be recognised by
/// its shape before it is read. Pure and free of isolation: the whole thing is a
/// function of its input, which is what makes `detect(_:)` testable.
enum SyntaxHighlighter {
    enum Language {
        case shell, json, cLike, plain
    }

    /// A card shows about ten lines, so tokenising more than this produces
    /// colour that is immediately clipped away — and this runs for every visible
    /// card on every redraw.
    ///
    /// ponytail: a flat character budget, not a line count. The ceiling is a
    /// single 1200-character line, which still gets tokenised in full. Upgrade
    /// path: cut at the tenth newline as well, once a clipping of that shape
    /// actually shows up.
    static let characterLimit = 1200

    // MARK: - Detection

    nonisolated static func detect(_ text: String) -> Language {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .plain }
        // The brackets are checked on the whole clipping; everything else only
        // reads the head, which is all that gets coloured anyway.
        if isJSON(trimmed) { return .json }
        let head = String(trimmed.prefix(characterLimit))
        if isShell(head) { return .shell }
        if isCLike(head) { return .cLike }
        return .plain
    }

    private static func isJSON(_ text: String) -> Bool {
        guard let first = text.first, let last = text.last else { return false }
        return (first == "{" && last == "}") || (first == "[" && last == "]")
    }

    /// Commands that never open an English or Portuguese sentence — seeing one
    /// in first position is enough on its own.
    private static let shellCommands: Set<String> = [
        "curl", "wget", "git", "docker", "npm", "npx", "yarn", "pnpm", "brew",
        "ssh", "scp", "rsync", "sudo", "kubectl", "chmod", "chown", "cargo",
        "xcodebuild", "xcrun", "xcodegen", "systemctl", "psql", "ffmpeg", "gh",
    ]

    /// Commands that are also ordinary words. "open the door" and "cat sat on
    /// the mat" are prose, so these only count with a flag, a path or a pipe
    /// beside them.
    private static let ambiguousCommands: Set<String> = [
        "cd", "ls", "cat", "cp", "mv", "rm", "echo", "open", "grep", "make",
        "go", "python3", "pip", "tar", "awk", "sed", "find", "touch", "kill",
    ]

    private static func isShell(_ text: String) -> Bool {
        if text.contains("-H ") || text.contains("--header") || text.contains("| grep") {
            return true
        }
        let line = text.prefix { $0 != "\n" }
        guard let command = line.split(separator: " ").first.map(String.init) else { return false }
        if shellCommands.contains(command) { return true }
        guard ambiguousCommands.contains(command) else { return false }
        return line.contains(" -") || line.contains("/") || line.contains("|") || line.contains("~")
    }

    private static let codeKeywords: Set<String> = [
        "func", "function", "const", "let", "var", "class", "struct", "enum",
        "import", "export", "return", "if", "else", "for", "while", "switch",
        "case", "guard", "def", "public", "private", "static", "async", "await",
        "new", "throw", "try", "catch", "interface", "extends", "implements",
    ]

    /// Prose is the thing to protect against, so a keyword alone is never
    /// enough: "return", "for", "if" and "class" are ordinary words in English
    /// and in Portuguese. A brace or an arrow is not, so one of those has to be
    /// there too — and a semicolon, which prose does use mid-sentence, only
    /// counts when it ends a line and two different keywords back it up.
    private static func isCLike(_ text: String) -> Bool {
        let keywords = Set(words(in: text)).intersection(codeKeywords).count
        guard keywords > 0 else { return false }
        if text.contains("{") || text.contains("}") || text.contains("=>") { return true }
        guard keywords >= 2 else { return false }
        return text.contains(";\n") || text.hasSuffix(";")
    }

    private static func words(in text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init)
    }

    // MARK: - Highlighting

    /// - Parameter limit: how much of `text` to colour. Defaults to the card's
    ///   budget, which is the only thing that called this until the hover
    ///   preview arrived. The preview passes its own, larger one — it has the
    ///   room to show more, and raising the shared constant instead would have
    ///   made every visible card pay for it on every redraw.
    nonisolated static func highlight(_ text: String, as language: Language,
                                      limit: Int = characterLimit) -> AttributedString {
        let source = String(text.prefix(limit))
        guard language != .plain else { return AttributedString(source) }
        var result = AttributedString()
        for span in spans(of: source, in: language) {
            var run = AttributedString(span.text)
            if let role = span.role { run.foregroundColor = palette[role] }
            result.append(run)
        }
        return result
    }

    private enum Role: Hashable {
        /// Language keywords, and the flags of a command line — a flag is what a
        /// keyword is to a shell.
        case keyword
        case string
        /// Numbers, and JSON's `true` / `false` / `null`.
        case number
        case comment
        /// The subject of the line: the command being run, a JSON key, a URL.
        case emphasis
    }

    private struct Span {
        let text: String
        let role: Role?
    }

    /// Every character of the source lands in exactly one span, in order, which
    /// is what keeps `highlight(_:as:)` from altering what the user copied.
    private static func spans(of source: String, in language: Language) -> [Span] {
        let chars = Array(source)
        var spans: [Span] = []
        var index = 0
        var plainStart = 0
        // A shell command is the first word of its line; nothing else is.
        var atLineStart = true

        func emit(upTo end: Int, as role: Role) {
            if index > plainStart {
                spans.append(Span(text: String(chars[plainStart..<index]), role: nil))
            }
            spans.append(Span(text: String(chars[index..<end]), role: role))
            index = end
            plainStart = end
        }

        while index < chars.count {
            let char = chars[index]

            if char == "\n" {
                atLineStart = true
                index += 1
                continue
            }
            if char == " " || char == "\t" {
                index += 1
                continue
            }

            if char == "\"" || char == "'" {
                let end = endOfString(chars, from: index)
                let isKey = language == .json && nextVisible(chars, from: end) == ":"
                emit(upTo: end, as: isKey ? .emphasis : .string)
                atLineStart = false
                continue
            }

            if language == .cLike, char == "/", index + 1 < chars.count {
                if chars[index + 1] == "/" {
                    emit(upTo: endOfLine(chars, from: index), as: .comment)
                    atLineStart = false
                    continue
                }
                if chars[index + 1] == "*" {
                    emit(upTo: endOfBlockComment(chars, from: index), as: .comment)
                    atLineStart = false
                    continue
                }
            }

            if char == "#", language != .json {
                emit(upTo: endOfLine(chars, from: index), as: .comment)
                atLineStart = false
                continue
            }

            if language == .shell, char == "-", isTokenStart(chars, at: index) {
                emit(upTo: endOfWord(chars, from: index), as: .keyword)
                atLineStart = false
                continue
            }

            if char.isNumber {
                emit(upTo: endOfNumber(chars, from: index), as: .number)
                atLineStart = false
                continue
            }

            if char.isLetter || char == "_" {
                let end = endOfIdentifier(chars, from: index)
                let word = String(chars[index..<end])
                // A URL is one token to the eye even though it is punctuation to
                // a lexer, so it is taken whole rather than shredded at the `/`.
                if language == .shell, word == "http" || word == "https",
                   end < chars.count, chars[end] == ":" {
                    emit(upTo: endOfWord(chars, from: index), as: .emphasis)
                    atLineStart = false
                    continue
                }
                if let role = role(of: word, in: language, atLineStart: atLineStart) {
                    emit(upTo: end, as: role)
                    atLineStart = false
                    continue
                }
                index = end
                atLineStart = false
                continue
            }

            index += 1
            atLineStart = false
        }

        if plainStart < chars.count {
            spans.append(Span(text: String(chars[plainStart...]), role: nil))
        }
        return spans
    }

    private static func role(of word: String, in language: Language, atLineStart: Bool) -> Role? {
        switch language {
        case .shell:
            return atLineStart ? .emphasis : nil
        case .json:
            return ["true", "false", "null"].contains(word) ? .number : nil
        case .cLike:
            return codeKeywords.contains(word) ? .keyword : nil
        case .plain:
            return nil
        }
    }

    // MARK: - Scanners

    private static func isTokenStart(_ chars: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        return chars[index - 1].isWhitespace
    }

    private static func endOfString(_ chars: [Character], from start: Int) -> Int {
        let quote = chars[start]
        var index = start + 1
        while index < chars.count {
            if chars[index] == "\\" {
                index += 2
                continue
            }
            if chars[index] == quote { return index + 1 }
            // An unterminated quote stops at the line: one stray apostrophe must
            // not swallow the rest of the clipping.
            if chars[index] == "\n" { return index }
            index += 1
        }
        return chars.count
    }

    private static func endOfLine(_ chars: [Character], from start: Int) -> Int {
        var index = start
        while index < chars.count, chars[index] != "\n" { index += 1 }
        return index
    }

    private static func endOfBlockComment(_ chars: [Character], from start: Int) -> Int {
        var index = start + 2
        while index + 1 < chars.count {
            if chars[index] == "*", chars[index + 1] == "/" { return index + 2 }
            index += 1
        }
        return chars.count
    }

    private static func endOfNumber(_ chars: [Character], from start: Int) -> Int {
        var index = start
        while index < chars.count, chars[index].isNumber || chars[index] == "." { index += 1 }
        return index
    }

    private static func endOfIdentifier(_ chars: [Character], from start: Int) -> Int {
        var index = start
        while index < chars.count,
              chars[index].isLetter || chars[index].isNumber || chars[index] == "_" {
            index += 1
        }
        return index
    }

    private static func endOfWord(_ chars: [Character], from start: Int) -> Int {
        var index = start
        while index < chars.count, !chars[index].isWhitespace { index += 1 }
        return index
    }

    private static func nextVisible(_ chars: [Character], from start: Int) -> Character? {
        var index = start
        while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
        return index < chars.count ? chars[index] : nil
    }

    // MARK: - Palette

    /// Derived from the system colours rather than written as hex, so the
    /// palette follows the user's appearance and accessibility settings. The
    /// system tints are calibrated as control fills, though, and several of them
    /// — green above all, at roughly 2:1 — fail as *text* on a white card, so in
    /// light appearance each is darkened until it clears 4.5:1. In dark
    /// appearance the system value is already the right one.
    private static let palette: [Role: Color] = [
        .keyword: adaptive(.keyword),
        .string: adaptive(.string),
        .number: adaptive(.number),
        .emphasis: adaptive(.emphasis),
        .comment: Color(nsColor: .secondaryLabelColor),
    ]

    private static func adaptive(_ role: Role) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let base = systemTint(for: role)
            guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua else { return base }
            return base.blended(withFraction: 0.35, of: .black) ?? base
        })
    }

    private static func systemTint(for role: Role) -> NSColor {
        switch role {
        case .keyword: return .systemPink
        case .string: return .systemGreen
        case .number: return .systemOrange
        case .emphasis: return .systemTeal
        case .comment: return .secondaryLabelColor
        }
    }
}
