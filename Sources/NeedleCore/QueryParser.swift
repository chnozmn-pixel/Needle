import Foundation

/// Parses the Everything search language into an expression tree.
///
/// Supported: substring and phrase search, `!` NOT, `|` OR, `< >` groups,
/// wildcards, regular expressions, modifiers (case, path, whole words,
/// prefix/suffix, diacritics, punctuation/whitespace), filename functions,
/// size/date comparisons, macros, content search, child/parent/exists,
/// duplicates and result-shaping functions.
public enum QueryParser {

    // MARK: - Public

    public static func parse(_ raw: String) -> ParsedQuery {
        var prepared = raw
        var andPrecedence = false

        if let range = prepared.range(of: "?and-precedence:", options: .caseInsensitive) {
            andPrecedence = true
            prepared.removeSubrange(range)
        }
        if let range = prepared.range(of: "?or-precedence:", options: .caseInsensitive) {
            andPrecedence = false
            prepared.removeSubrange(range)
        }

        var parser = Parser(tokens: tokenize(prepared), andPrecedence: andPrecedence)
        var expression = parser.parseExpression()
        if parser.noBang, case .not(let inner) = expression { expression = inner }
        expression = applyDupeConstraints(expression, min: parser.dupeMin, max: parser.dupeMax)

        return ParsedQuery(
            expression: expression,
            resultLimit: parser.resultLimit,
            sortSpecifications: parser.sortSpecifications,
            distinctFields: parser.distinctFields,
            raw: raw
        )
    }

    // MARK: - Lexer

    private enum Token: Sendable {
        case word(String)
        case quoted(String)
        case pipe
        case bang
        case open
        case close
    }

    private static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(input)
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace { i += 1; continue }

            switch ch {
            case "|":
                tokens.append(.pipe)
                i += 1
            case "!":
                tokens.append(.bang)
                i += 1
            case "<":
                tokens.append(.open)
                i += 1
            case ">":
                tokens.append(.close)
                i += 1
            case "\"":
                i += 1
                var value = ""
                while i < chars.count {
                    let c = chars[i]
                    if c == "\"" { i += 1; break }
                    if c == "\\", i + 1 < chars.count, isEscapable(chars[i + 1]) {
                        i += 1
                        value.append(chars[i])
                        i += 1
                        continue
                    }
                    value.append(c)
                    i += 1
                }
                tokens.append(.quoted(value))
            default:
                var value = ""
                var plainSuffix = false

                while i < chars.count {
                    let c = chars[i]
                    let lower = value.lowercased()
                    let keepsOperators = lower.hasPrefix("regex:") || lower.hasPrefix("regex*:")
                        || lower.hasPrefix("wildcards:")
                    if c.isWhitespace || (c == "|" && !keepsOperators) { break }
                    if c == "\\", i + 1 < chars.count, isEscapable(chars[i + 1]) {
                        i += 1
                        value.append(chars[i])
                        i += 1
                        continue
                    }
                    value.append(c)
                    i += 1

                    let current = value.lowercased()
                    if (current == "regex*" || current == "wildcards*"),
                       i < chars.count, chars[i] == ":" {
                        i += 1
                        value.append(":")
                        let rest = String(chars[i...]).trimmingCharacters(in: .whitespaces)
                        value.append(rest)
                        i = chars.count
                        plainSuffix = true
                        break
                    }
                }

                // A group close directly attached to a word (`<foo bar>`)
                // still needs to become its own token. Operators inside a
                // function value (`size:>10mb`, `ext:!pdf`) stay in the word.
                if value.count > 1, value.hasSuffix(">"), !value.contains(":") {
                    value.removeLast()
                    tokens.append(.word(value))
                    tokens.append(.close)
                } else if !value.isEmpty || plainSuffix {
                    tokens.append(.word(value))
                }
            }
        }
        return tokens
    }

    private static func isEscapable(_ ch: Character) -> Bool {
        ch == "\"" || ch == "\\" || ch == "!" || ch == "|" || ch == "<" || ch == ">" || ch == " "
    }

    // MARK: - Parser state

    private struct Options {
        var caseSensitive = false
        var diacritics = false
        var ignorePunctuation = false
        var ignoreWhitespace = false
        var matchPath = false
        var wildcardsEnabled = true
        var regex = false
        var whole = false
        var wholeWords = false
        var prefix = false
        var suffix = false
        var metric = false

        mutating func apply(key: String, enabled: Bool) -> Bool {
            switch key {
            case "case": caseSensitive = enabled
            case "diacritics", "diac": diacritics = enabled
            case "ignorepunctuation", "nopunc": ignorePunctuation = enabled
            case "ignorewhitespace", "nows": ignoreWhitespace = enabled
            case "path": matchPath = enabled
            case "wildcards": wildcardsEnabled = enabled
            case "regex": regex = enabled
            case "whole", "wholefilename", "wfn", "entire": whole = enabled
            case "wholewords", "ww": wholeWords = enabled
            case "prefix": prefix = enabled
            case "suffix": suffix = enabled
            case "metric": metric = enabled
            default: return false
            }
            return true
        }

        var textOptions: TextOptions {
            TextOptions(
                caseSensitive: caseSensitive,
                diacritics: diacritics,
                ignorePunctuation: ignorePunctuation,
                ignoreWhitespace: ignoreWhitespace
            )
        }
    }

    private struct Parser {
        var tokens: [Token]
        var index = 0
        var andPrecedence: Bool
        var globalOptions = Options()
        var noBang = false
        var resultLimit: Int?
        var sortSpecifications: [SortSpecification] = []
        var distinctFields: [String] = []
        var dupeMin: Int?
        var dupeMax: Int?

        // MARK: Structure

        mutating func parseExpression() -> QueryExpression {
            parseGlobalModifiers()
            return andPrecedence ? parseOROfAND() : parseANDOfOR()
        }

        private mutating func parseGlobalModifiers() {
            while let token = current {
                guard case .word(let word) = token, word.hasPrefix("?") else { return }
                let body = String(word.dropFirst())
                guard let colon = body.firstIndex(of: ":") else { return }
                let key = Self.normalizeKey(String(body[..<colon]))
                let value = String(body[body.index(after: colon)...])

                if key == "nobang" || key == "no!" {
                    noBang = true
                } else if key == "andprecedence" {
                    andPrecedence = true
                } else if key == "orprecedence" {
                    andPrecedence = false
                } else if !globalOptions.apply(key: key, enabled: true) {
                    return
                }
                index += 1

                if !value.isEmpty { tokens.insert(.word(value), at: index) }
            }
        }

        private mutating func parseANDOfOR() -> QueryExpression {
            var items: [QueryExpression] = []
            while isOperandStart {
                items.append(parseORChain())
            }
            return combine(items, mode: .and)
        }

        private mutating func parseOROfAND() -> QueryExpression {
            var items: [QueryExpression] = []
            while isOperandStart {
                items.append(parseANDChain())
                if case .pipe = current { index += 1 } else { break }
            }
            return combine(items, mode: .or)
        }

        private mutating func parseORChain() -> QueryExpression {
            var items: [QueryExpression] = [parseUnary()]
            while case .pipe = current {
                index += 1
                guard isOperandStart else { break }
                items.append(parseUnary())
            }
            return combine(items, mode: .or)
        }

        private mutating func parseANDChain() -> QueryExpression {
            var items: [QueryExpression] = []
            while isOperandStart { items.append(parseUnary()) }
            return combine(items, mode: .and)
        }

        private mutating func parseUnary() -> QueryExpression {
            guard let token = current else { return .all }
            switch token {
            case .bang:
                index += 1
                let inner = parseUnary()
                if case .none = inner { return .none }
                return .not(inner)
            case .open:
                index += 1
                let inner = parseExpression()
                if case .close = current { index += 1 }
                return inner
            case .word(let value):
                index += 1
                return parseTerm(value, quoted: false)
            case .quoted(let value):
                index += 1
                return parseTerm(value, quoted: true)
            case .pipe, .close:
                index += 1
                return .all
            }
        }

        private enum Combination { case and; case or }

        private func combine(_ items: [QueryExpression], mode: Combination) -> QueryExpression {
            let flat = items.flatMap { item -> [QueryExpression] in
                switch (mode, item) {
                case (.and, .and(let nested)): return nested
                case (.or, .or(let nested)): return nested
                default: return [item]
                }
            }.filter { !$0.isAll }

            if flat.isEmpty { return .all }
            if flat.count == 1 { return flat[0] }
            switch mode {
            case .and: return .and(flat)
            case .or: return .or(flat)
            }
        }

        private var current: Token? {
            index < tokens.count ? tokens[index] : nil
        }

        private var isOperandStart: Bool {
            switch current {
            case .word, .quoted, .bang, .open: return true
            default: return false
            }
        }

        // MARK: Terms

        private mutating func parseTerm(_ raw: String, quoted: Bool) -> QueryExpression {
            var options = globalOptions
            let field: QueryField? = (quoted || raw.contains(":"))
                ? nil : (Self.looksLikePath(raw) ? .path : nil)
            var mode: TextMode?
            var explicitField = false
            var text = raw
            var sawTypeModifier: String?
            var functionKey: String?
            let explicitNegation = !quoted && text.hasPrefix("!")
            if explicitNegation { text.removeFirst() }

            while let colon = text.firstIndex(of: ":") {
                let rawKey = String(text[..<colon])
                if rawKey.isEmpty { break }
                let (baseKey, enabled) = Self.splitNegation(rawKey)
                let key = Self.normalizeKey(baseKey)
                let remainder = String(text[text.index(after: colon)...])

                if Self.isModifier(key) {
                    if key == "file" || key == "folder" || key == "dir" {
                        // `file:` / `folder:` with no value are type switches.
                        if remainder.isEmpty {
                            sawTypeModifier = key
                            text = remainder
                            continue
                        }
                    }
                    if key == "path", enabled == false {
                        options.matchPath = false
                        text = remainder
                        continue
                    }
                    _ = options.apply(key: key, enabled: enabled)
                    text = remainder
                    continue
                }

                if Self.isFunction(key) {
                    functionKey = key
                    text = remainder
                    explicitField = true
                    break
                }
                break
            }

            let decodedText = Self.decodeEntities(text)

            if functionKey == nil, !quoted, !explicitField {
                let bare = sawTypeModifier ?? decodedText.lowercased()
                switch bare {
                case "file": return .type(files: true, folders: false)
                case "folder", "dir": return .type(files: false, folders: true)
                default: break
                }
            }

            if options.regex { mode = .regex }
            if options.whole { mode = .whole }
            if options.wholeWords, mode == nil { mode = .wholeWords }
            if options.prefix, mode == nil { mode = .prefix }
            if options.suffix, mode == nil { mode = .suffix }
            if mode == nil, options.wildcardsEnabled,
               decodedText.contains("*") || decodedText.contains("?") {
                mode = .wildcard
            }
            if mode == nil { mode = .contains }

            let effectiveField: QueryField
            if let functionKey, let mapped = Self.field(for: functionKey) {
                effectiveField = mapped
            } else if let field, !explicitField {
                effectiveField = field
            } else if options.matchPath {
                effectiveField = .path
            } else {
                effectiveField = .name
            }

            let term = TextTerm(
                text: decodedText,
                field: effectiveField,
                mode: mode ?? .contains,
                options: options.textOptions
            )

            var expression: QueryExpression
            if let functionKey {
                expression = Self.applyFunction(
                    functionKey,
                    value: term.text,
                    term: term,
                    options: options,
                    parser: &self
                )
            } else {
                expression = .text(term)
            }
            if explicitNegation { expression = .not(expression) }
            return expression
        }

        private static func applyFunction(
            _ key: String,
            value: String,
            term: TextTerm,
            options: Options,
            parser: inout Parser
        ) -> QueryExpression {
            switch key {
            case "file":
                let typeExpression = QueryExpression.type(files: true, folders: false)
                if value.isEmpty { return typeExpression }
                var filtered = term
                filtered.field = .name
                return .and([typeExpression, .text(filtered)])
            case "folder", "dir":
                let typeExpression = QueryExpression.type(files: false, folders: true)
                if value.isEmpty { return typeExpression }
                var filtered = term
                filtered.field = .name
                return .and([typeExpression, .text(filtered)])

            case "ext", "exts", "extension":
                let negated = value.hasPrefix("!") || value.hasPrefix("~")
                let clean = negated ? String(value.dropFirst()) : value
                return .ext(values: extensionValues(clean), negated: negated)

            case "size":
                return .numeric(parseNumeric(value, property: .size, metric: options.metric))

            case "dm", "datemodified", "modified", "date":
                return .date(parseDateComparison(value, property: .modified))

            case "dc", "datecreated", "created":
                return .date(parseDateComparison(value, property: .created))

            case "da", "dateaccessed", "accessed":
                return .date(parseDateComparison(value, property: .accessed))

            case "len", "namelen", "namelength", "length":
                let property: NumericProperty = options.matchPath ? .pathLength : .nameLength
                return .numeric(parseNumeric(value, property: property, metric: options.metric))

            case "fullpathlen", "fullpathlength":
                return .numeric(parseNumeric(value, property: .pathLength, metric: options.metric))

            case "childcount", "childfilecount", "childfoldercount", "parentcount", "depth":
                let property: NumericProperty
                switch key {
                case "childfilecount": property = .childFileCount
                case "childfoldercount": property = .childFolderCount
                case "parentcount", "depth": property = .parentCount
                default: property = .childCount
                }
                return .numeric(parseNumeric(value, property: property, metric: options.metric))

            case "empty":
                return .empty

            case "child", "childfile", "childfolder", "descendant", "descendantfile", "descendantfolder":
                let kind: ChildKind
                if key.contains("file") { kind = .file }
                else if key.contains("folder") { kind = .folder }
                else { kind = .any }
                let recursive = key.hasPrefix("descendant")
                var childTerm = term
                childTerm.field = .name
                childTerm.mode = value.contains("*") || value.contains("?") ? .wildcard : term.mode
                return .child(childTerm, kind: kind, recursive: recursive)

            case "parent":
                var parentTerm = term
                parentTerm.field = .parentPath
                parentTerm.mode = .whole
                return .text(parentTerm)

            case "fullpath", "path":
                var pathTerm = term
                pathTerm.field = .path
                return .text(pathTerm)

            case "location", "loc":
                var locationTerm = term
                locationTerm.field = .parentPath
                return .text(locationTerm)

            case "root", "volume", "volumelabel":
                var rootTerm = term
                rootTerm.field = .root
                return .text(rootTerm)

            case "content":
                var contentTerm = term
                contentTerm.field = .content
                return .text(contentTerm)

            case "name", "stem", "kind", "type":
                var fieldTerm = term
                fieldTerm.field = field(for: key) ?? .name
                return .text(fieldTerm)

            case "exists", "fileexists", "folderexists":
                var existsTerm = term
                existsTerm.field = .name
                return .exists(existsTerm)

            case "dupe":
                let fields: [DuplicateField]
                if value.isEmpty {
                    fields = [.name]
                } else {
                    fields = value.split(separator: ";").compactMap {
                        DuplicateField(rawValue: normalizeKey(String($0)))
                    }
                }
                return .duplicate(fields: fields.isEmpty ? [.name] : fields,
                                  min: parser.dupeMin,
                                  max: parser.dupeMax)

            case "dupemin":
                parser.dupeMin = Int(value)
                return .all

            case "dupemax":
                parser.dupeMax = Int(value)
                return .all

            case "distinct":
                parser.distinctFields = value.split(separator: ";").map(String.init)
                return .all

            case "distinctsort":
                parser.sortSpecifications = value.split(separator: ";").map {
                    let part = String($0)
                    return part.hasSuffix("-descending")
                        ? SortSpecification(field: String(part.dropLast("-descending".count)), descending: true)
                        : SortSpecification(field: part)
                }
                return .all

            case "count":
                parser.resultLimit = Int(value)
                return .all

            case "sort":
                parser.sortSpecifications = value.split(separator: ";").map {
                    let part = String($0)
                    return part.hasSuffix("-descending")
                        ? SortSpecification(field: String(part.dropLast("-descending".count)), descending: true)
                        : SortSpecification(field: part)
                }
                return .all

            case "audio":
                return .or(extensionValues("mp3;wav;flac;aac;m4a;ogg;wma;opus;aiff").map {
                    .ext(values: [$0], negated: false)
                })
            case "doc", "document":
                return .or(extensionValues("txt;doc;docx;pdf;rtf;odt;pages;md;csv;xls;xlsx;ppt;pptx;epub").map {
                    .ext(values: [$0], negated: false)
                })
            case "exe", "executable":
                return .or(extensionValues("exe;app;dmg;pkg;sh;command;msi;bat;appimage").map {
                    .ext(values: [$0], negated: false)
                })
            case "image":
                return .or(extensionValues("jpg;jpeg;png;gif;bmp;tiff;webp;heic;svg;ico;psd;raw").map {
                    .ext(values: [$0], negated: false)
                })
            case "video":
                return .or(extensionValues("mp4;mov;avi;mkv;wmv;flv;webm;m4v;mpg;mpeg").map {
                    .ext(values: [$0], negated: false)
                })
            case "zip", "archive":
                return .or(extensionValues("zip;rar;7z;tar;gz;bz2;xz;iso").map {
                    .ext(values: [$0], negated: false)
                })

            default:
                return .text(term)
            }
        }

        // MARK: Key classification

        private static let modifierKeys: Set<String> = [
            "case", "nocase", "diacritics", "diac", "nodia",
            "ignorepunctuation", "nopunc", "noignorepunctuation",
            "ignorewhitespace", "nows", "noignorewhitespace",
            "path", "nopath", "file", "folder", "dir",
            "regex", "noregex", "wildcards", "nowildcards",
            "whole", "wholefilename", "wfn", "entire", "nowhole",
            "wholewords", "ww", "no", "nowholewords",
            "prefix", "noprefix", "suffix", "nosuffix",
            "startwith", "endwith", "^", "$", "metric", "nomultiplestring"
        ]

        private static let functionKeys: Set<String> = [
            "file", "folder", "dir", "ext", "exts", "extension",
            "size", "dm", "datemodified", "modified", "date",
            "dc", "datecreated", "created", "da", "dateaccessed", "accessed",
            "len", "namelen", "namelength", "length", "fullpathlen", "fullpathlength",
            "childcount", "childfilecount", "childfoldercount", "parentcount", "depth",
            "empty", "child", "childfile", "childfolder", "descendant",
            "descendantfile", "descendantfolder", "parent", "fullpath",
            "location", "loc", "root", "volume", "volumelabel", "content",
            "tag", "label", "comment",
            "name", "stem", "kind", "type", "exists", "fileexists", "folderexists",
            "dupe", "dupemin", "dupemax", "distinct", "distinctsort",
            "count", "sort", "audio", "doc", "document", "exe", "executable",
            "image", "video", "zip", "archive"
        ]

        static func isModifier(_ key: String) -> Bool { modifierKeys.contains(key) }
        static func isFunction(_ key: String) -> Bool { functionKeys.contains(key) }

        static func normalizeKey(_ raw: String) -> String {
            var result = ""
            for ch in raw.lowercased() {
                if ch == "-" || ch == "_" || ch == " " { continue }
                result.append(ch)
            }
            if result == "no" { return "no" }
            if result.hasPrefix("no"), result.count > 2 {
                return String(result.dropFirst(2))
            }
            if result == "dia" { return "diacritics" }
            if result == "punc" { return "ignorepunctuation" }
            if result == "ws" { return "ignorewhitespace" }
            if result == "startwith" || result == "^" { return "prefix" }
            if result == "endwith" || result == "$" { return "suffix" }
            if result == "wholefilename" { return "whole" }
            if result == "nowholewords" { return "wholewords" }
            return result
        }

        static func splitNegation(_ raw: String) -> (key: String, enabled: Bool) {
            let lower = raw.lowercased()
            if lower.hasPrefix("no-") || lower.hasPrefix("no") {
                if lower.hasPrefix("no-") { return (String(raw.dropFirst(3)), false) }
                if raw.count > 2 { return (String(raw.dropFirst(2)), false) }
            }
            if lower.hasPrefix("::") { return (String(raw.dropFirst(2)), true) }
            if lower.hasPrefix("~") { return (String(raw.dropFirst()), false) }
            return (raw, true)
        }

        static func field(for key: String) -> QueryField? {
            switch key {
            case "name": return .name
            case "stem": return .stem
            case "ext", "exts", "extension": return .`extension`
            case "path", "fullpath": return .path
            case "location", "loc": return .parentPath
            case "root", "volume", "volumelabel": return .root
            case "content": return .content
            case "tag", "label": return .tag
            case "comment": return .comment
            default: return nil
            }
        }

        static func looksLikePath(_ value: String) -> Bool {
            value.contains("/") || value.contains("\\")
        }

        static func decodeEntities(_ value: String) -> String {
            let replacements: [String: String] = [
                "&sp:": " ", "&vert:": "|", "&excl:": "!", "&lt:": "<",
                "&gt:": ">", "&quot:": "\"", "&ast:": "*", "&quest:": "?"
            ]
            var result = value
            for (key, replacement) in replacements {
                result = result.replacingOccurrences(of: key, with: replacement, options: .caseInsensitive)
            }

            let pattern = "&#(x[0-9a-fA-F]+|[0-9]+);"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let body = String(result[range]).dropFirst(2).dropLast()
                let scalarValue: UInt32?
                if body.hasPrefix("x") || body.hasPrefix("X") {
                    scalarValue = UInt32(body.dropFirst(), radix: 16)
                } else {
                    scalarValue = UInt32(body)
                }
                if let value = scalarValue, let scalar = Unicode.Scalar(value) {
                    result.replaceSubrange(range, with: String(Character(scalar)))
                }
            }
            return result
        }
    }

    // MARK: - Values

    private static func extensionValues(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == ";" || $0 == "," })
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
            .map { value in
                var clean = value
                while clean.hasPrefix(".") || clean.hasPrefix("*") { clean.removeFirst() }
                return clean
            }
            .filter { !$0.isEmpty }
    }

    private static func applyDupeConstraints(
        _ expression: QueryExpression,
        min: Int?,
        max: Int?
    ) -> QueryExpression {
        guard min != nil || max != nil else { return expression }
        switch expression {
        case .duplicate(let fields, let existingMin, let existingMax):
            return .duplicate(fields: fields, min: min ?? existingMin, max: max ?? existingMax)
        case .and(let items):
            return .and(items.map { applyDupeConstraints($0, min: min, max: max) })
        case .or(let items):
            return .or(items.map { applyDupeConstraints($0, min: min, max: max) })
        case .not(let item):
            return .not(applyDupeConstraints(item, min: min, max: max))
        default:
            return expression
        }
    }

    // MARK: Numeric values

    private static func parseNumeric(_ raw: String, property: NumericProperty, metric: Bool) -> NumericComparison {
        var value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        var negated = false
        if value.hasPrefix("!") || value.hasPrefix("~") {
            negated = true
            value.removeFirst()
        }

        var inclusiveMin = true
        var inclusiveMax = true
        var direction = 0
        if value.hasPrefix(">=") {
            value.removeFirst(2)
            inclusiveMin = true
            direction = 1
        } else if value.hasPrefix("<=") {
            value.removeFirst(2)
            inclusiveMax = true
            direction = -1
        } else if value.hasPrefix(">") {
            value.removeFirst()
            inclusiveMin = false
            direction = 1
        } else if value.hasPrefix("<") {
            value.removeFirst()
            inclusiveMax = false
            direction = -1
        }

        var min: Int64?
        var max: Int64?
        if value.contains("..") {
            let parts = value.split(separator: "..", maxSplits: 1)
            if parts.count == 2 {
                min = parseSize(String(parts[0]), metric: metric)
                max = parseSize(String(parts[1]), metric: metric)
            }
        } else if let exact = parseSize(value, metric: metric) {
            if direction > 0 { min = exact }
            else if direction < 0 { max = exact }
            else { min = exact; max = exact }
        }

        if negated {
            let upper = min ?? max
            return NumericComparison(property: property, min: nil, max: upper,
                                    inclusiveMin: true, inclusiveMax: false)
        }
        return NumericComparison(property: property, min: min, max: max,
                                inclusiveMin: inclusiveMin, inclusiveMax: inclusiveMax)
    }

    private static func parseSize(_ raw: String, metric: Bool = false) -> Int64? {
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }

        let base: Double = metric ? 1_000 : 1_024
        let multipliers: [String: Double] = [
            "b": 1, "": 1, "byte": 1, "bytes": 1,
            "k": base, "kb": base, "kib": 1_024,
            "m": base * base, "mb": base * base, "mib": 1_048_576,
            "g": base * base * base, "gb": base * base * base, "gib": 1_073_741_824,
            "t": base * base * base * base, "tb": base * base * base * base,
            "tib": 1_099_511_627_776
        ]

        var suffix = ""
        while let last = text.last, last.isLetter {
            suffix.insert(last, at: text.startIndex)
            text.removeLast()
        }
        guard let multiplier = multipliers[suffix], let number = Double(text), number >= 0 else { return nil }
        return Int64((number * multiplier).rounded())
    }

    // MARK: Date values

    private static func parseDateComparison(_ raw: String, property: DateProperty) -> DateComparison {
        var value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        var inclusiveMin = true
        var inclusiveMax = true
        var direction = 0 // -1 = less-than, 1 = greater-than
        if value.hasPrefix(">=") {
            value.removeFirst(2)
            inclusiveMin = true
            direction = 1
        } else if value.hasPrefix("<=") {
            value.removeFirst(2)
            inclusiveMax = true
            direction = -1
        } else if value.hasPrefix(">") {
            value.removeFirst()
            inclusiveMin = false
            direction = 1
        } else if value.hasPrefix("<") {
            value.removeFirst()
            inclusiveMax = false
            direction = -1
        }

        let now = Date()
        if value.contains("..") {
            let parts = value.split(separator: "..", maxSplits: 1)
            if parts.count == 2 {
                return DateComparison(
                    property: property,
                    min: parseDate(String(parts[0])),
                    max: endOfDay(parseDate(String(parts[1]))),
                    inclusiveMin: inclusiveMin,
                    inclusiveMax: inclusiveMax
                )
            }
        }

        if let relative = parseRelativeDate(value, now: now) {
            return DateComparison(property: property, min: relative, max: now,
                                  inclusiveMin: true, inclusiveMax: true)
        }
        if let date = parseDate(value) {
            if direction < 0 {
                return DateComparison(property: property, min: nil, max: date,
                                      inclusiveMin: inclusiveMin, inclusiveMax: inclusiveMax)
            }
            if direction > 0 {
                let bound = value.count == 10 ? endOfDay(date) ?? date : date
                return DateComparison(property: property, min: bound, max: nil,
                                      inclusiveMin: inclusiveMin, inclusiveMax: inclusiveMax)
            }
            return DateComparison(property: property, min: date, max: endOfDay(date),
                                  inclusiveMin: inclusiveMin, inclusiveMax: inclusiveMax)
        }
        return DateComparison(property: property, min: nil, max: nil,
                              inclusiveMin: inclusiveMin, inclusiveMax: inclusiveMax)
    }

    private static func parseRelativeDate(_ raw: String, now: Date) -> Date? {
        let calendar = Calendar.current
        switch raw {
        case "now": return now
        case "today": return calendar.startOfDay(for: now)
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case "thisweek":
            return calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))
        case "lastweek": return calendar.date(byAdding: .day, value: -7, to: now)
        case "thismonth":
            return calendar.date(from: calendar.dateComponents([.year, .month], from: now))
        case "lastmonth": return calendar.date(byAdding: .month, value: -1, to: now)
        case "thisyear":
            return calendar.date(from: calendar.dateComponents([.year], from: now))
        case "lastyear": return calendar.date(byAdding: .year, value: -1, to: now)
        default: break
        }

        var digits = ""
        for ch in raw {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        guard let amount = Int(digits), amount > 0 else { return nil }
        let unit = String(raw.dropFirst(digits.count)).trimmingCharacters(in: .whitespaces)
        let component: Calendar.Component
        switch unit {
        case "min", "mins", "minute", "minutes", "m": component = .minute
        case "h", "hour", "hours": component = .hour
        case "d", "day", "days": component = .day
        case "w", "week", "weeks": component = .weekOfYear
        case "month", "months": component = .month
        case "y", "year", "years": component = .year
        default: return nil
        }
        return calendar.date(byAdding: component, value: -amount, to: now)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let calendar = Calendar.current
        let now = Date()

        switch text {
        case "now": return now
        case "today": return calendar.startOfDay(for: now)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        case "lastweek": return calendar.date(byAdding: .day, value: -7, to: now)
        case "lastmonth": return calendar.date(byAdding: .month, value: -1, to: now)
        case "lastyear": return calendar.date(byAdding: .year, value: -1, to: now)
        default: break
        }

        if let relative = parseRelativeDate(text, now: now) { return relative }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current

        switch text.count {
        case 4: formatter.dateFormat = "yyyy"
        case 7: formatter.dateFormat = "yyyy-MM"
        case 10: formatter.dateFormat = "yyyy-MM-dd"
        case 16: formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        case 19: formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        default: return nil
        }
        return formatter.date(from: text)
    }

    private static func endOfDay(_ date: Date?) -> Date? {
        guard let date else { return nil }
        let calendar = Calendar.current
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: date))
    }
}
