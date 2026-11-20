import SwiftUI

/// Lightweight, zero-dependency syntax highlighting for chat code blocks.
/// One ordered-alternative regex per language: block comments, line comments,
/// strings, keywords, numbers. Good enough for a chat transcript — this is
/// not an IDE-grade highlighter.
enum CodeHighlighter {
    private static let stringColor = Color(red: 0.80, green: 0.32, blue: 0.16)
    private static let keywordColor = Color.purple
    private static let numberColor = Color.teal

    static func highlight(_ code: String, language: String) -> AttributedString {
        let lang = language.lowercased()
        var pattern = ""
        var colors: [Color] = []

        func add(_ fragment: String, _ color: Color) {
            pattern += (pattern.isEmpty ? "" : "|") + "(" + fragment + ")"
            colors.append(color)
        }

        if usesBlockComments(lang) {
            add(#"/\*(?s:.*?)\*/"#, Color.secondary)
        }
        if usesHashComments(lang) {
            add(#"#[^\n]*"#, Color.secondary)
        } else {
            add(#"//[^\n]*"#, Color.secondary)
        }
        add(#""(?:[^"\\]|\\.)*""#, stringColor)
        if lang != "json" {
            add(#"'(?:[^'\\]|\\.)*'"#, stringColor)
        }
        add(#"`(?:[^`\\]|\\.)*`"#, stringColor)
        add("\\b(?:" + keywords(for: lang) + ")\\b", keywordColor)
        add(#"\b\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, numberColor)

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return AttributedString(code)
        }

        // Build incrementally: plain runs between matches, colored run per match.
        var attributed = AttributedString()
        var cursor = code.startIndex
        let nsRange = NSRange(code.startIndex..<code.endIndex, in: code)
        for match in regex.matches(in: code, range: nsRange) {
            guard let matchRange = Range(match.range, in: code) else { continue }
            if cursor < matchRange.lowerBound {
                attributed += AttributedString(code[cursor..<matchRange.lowerBound])
            }
            var segment = AttributedString(code[matchRange])
            for group in 1..<match.numberOfRanges {
                if match.range(at: group).location != NSNotFound {
                    segment.foregroundColor = colors[group - 1]
                    break
                }
            }
            attributed += segment
            cursor = matchRange.upperBound
        }
        if cursor < code.endIndex {
            attributed += AttributedString(code[cursor..<code.endIndex])
        }
        return attributed
    }

    private static func usesBlockComments(_ lang: String) -> Bool {
        ["swift", "js", "javascript", "ts", "typescript", "tsx", "jsx", "go", "golang", "rust", "java", "kotlin", "c", "cpp", "css", "scss", "php"].contains(lang)
    }

    private static func usesHashComments(_ lang: String) -> Bool {
        ["python", "py", "sh", "bash", "zsh", "shell", "yaml", "yml", "toml", "ruby", "rb", "r"].contains(lang)
    }

    private static func keywords(for lang: String) -> String {
        switch lang {
        case "swift":
            return "func|let|var|if|else|guard|for|while|return|class|struct|enum|extension|import|switch|case|default|break|continue|defer|self|super|nil|true|false|static|private|public|internal|open|override|init|throws|throw|try|catch|async|await|actor|protocol|where|in|as|is|some|any"
        case "js", "javascript", "ts", "typescript", "tsx", "jsx":
            return "function|const|let|var|if|else|for|while|return|class|extends|import|export|from|switch|case|default|break|continue|new|this|super|null|undefined|true|false|async|await|try|catch|finally|throw|typeof|instanceof|of|in|delete|yield|static|get|set|interface|type|enum|implements|public|private|protected|readonly|declare|namespace|as|satisfies"
        case "python", "py":
            return "def|class|if|elif|else|for|while|return|import|from|as|with|try|except|finally|raise|lambda|yield|global|nonlocal|pass|break|continue|in|is|not|and|or|None|True|False|self|async|await|assert|del|match|case"
        case "go", "golang":
            return "func|var|const|if|else|for|range|return|package|import|type|struct|interface|map|chan|go|defer|select|switch|case|default|break|continue|fallthrough|nil|true|false"
        case "rust", "rs":
            return "fn|let|mut|if|else|match|for|while|loop|return|struct|enum|impl|trait|pub|use|mod|crate|super|self|Self|where|as|in|ref|move|async|await|dyn|const|static|type|break|continue|true|false|None|Some|Ok|Err"
        case "sh", "bash", "zsh", "shell":
            return "if|then|else|elif|fi|for|while|do|done|case|esac|function|return|export|local|read|echo|exit|in|set|unset|source"
        case "json":
            return "true|false|null"
        default:
            return "function|const|let|var|if|else|for|while|return|class|import|export|switch|case|default|true|false|null|this|self|new|def|fn|struct|enum|public|private|static|async|await|try|catch|throw"
        }
    }
}
