import Foundation

// MARK: - Query fields and text matching

public enum QueryField: String, Sendable, Equatable {
    case name
    case stem
    case `extension`
    case path
    case parentPath
    case root
    case content
    case tag
    case comment
}

public enum TextMode: String, Sendable, Equatable {
    case contains
    case whole
    case wholeWords
    case prefix
    case suffix
    case wildcard
    case regex
}

public struct TextOptions: Sendable, Equatable {
    public var caseSensitive = false
    public var diacritics = false
    public var ignorePunctuation = false
    public var ignoreWhitespace = false

    public init(
        caseSensitive: Bool = false,
        diacritics: Bool = false,
        ignorePunctuation: Bool = false,
        ignoreWhitespace: Bool = false
    ) {
        self.caseSensitive = caseSensitive
        self.diacritics = diacritics
        self.ignorePunctuation = ignorePunctuation
        self.ignoreWhitespace = ignoreWhitespace
    }
}

public struct TextTerm: Sendable, Equatable {
    public var text: String
    public var field: QueryField
    public var mode: TextMode
    public var options: TextOptions

    public init(
        text: String,
        field: QueryField = .name,
        mode: TextMode = .contains,
        options: TextOptions = TextOptions()
    ) {
        self.text = text
        self.field = field
        self.mode = mode
        self.options = options
    }
}

// MARK: - Numeric and date comparisons

public enum NumericProperty: String, Sendable, Equatable {
    case size
    case nameLength
    case pathLength
    case childCount
    case childFileCount
    case childFolderCount
    case parentCount
}

public struct NumericComparison: Sendable, Equatable {
    public var property: NumericProperty
    public var min: Int64?
    public var max: Int64?
    public var inclusiveMin: Bool
    public var inclusiveMax: Bool

    public init(
        property: NumericProperty,
        min: Int64? = nil,
        max: Int64? = nil,
        inclusiveMin: Bool = true,
        inclusiveMax: Bool = true
    ) {
        self.property = property
        self.min = min
        self.max = max
        self.inclusiveMin = inclusiveMin
        self.inclusiveMax = inclusiveMax
    }
}

public enum DateProperty: String, Sendable, Equatable {
    case modified
    case created
    case accessed
}

public struct DateComparison: Sendable, Equatable {
    public var property: DateProperty
    public var min: Date?
    public var max: Date?
    public var inclusiveMin: Bool
    public var inclusiveMax: Bool

    public init(
        property: DateProperty,
        min: Date? = nil,
        max: Date? = nil,
        inclusiveMin: Bool = true,
        inclusiveMax: Bool = true
    ) {
        self.property = property
        self.min = min
        self.max = max
        self.inclusiveMin = inclusiveMin
        self.inclusiveMax = inclusiveMax
    }
}

// MARK: - Special functions

public enum ChildKind: String, Sendable, Equatable {
    case any
    case file
    case folder
}

public enum DuplicateField: String, Sendable, Equatable {
    case name
    case stem
    case `extension`
    case path
    case parent
    case size
    case content
}

public struct SortSpecification: Sendable, Equatable {
    public var field: String
    public var descending: Bool

    public init(field: String, descending: Bool = false) {
        self.field = field
        self.descending = descending
    }
}

// MARK: - Expression tree

public indirect enum QueryExpression: Sendable, Equatable {
    case all
    case none
    case text(TextTerm)
    case ext(values: [String], negated: Bool)
    case type(files: Bool, folders: Bool)
    case numeric(NumericComparison)
    case date(DateComparison)
    case empty
    case child(TextTerm, kind: ChildKind, recursive: Bool)
    case exists(TextTerm)
    case duplicate(fields: [DuplicateField], min: Int?, max: Int?)
    case kind(String)
    case and([QueryExpression])
    case or([QueryExpression])
    case not(QueryExpression)

    public var isAll: Bool {
        if case .all = self { return true }
        return false
    }

    public var usesContent: Bool {
        switch self {
        case .text(let term): return term.field == .content
        case .child(let term, _, _): return term.field == .content
        case .exists(let term): return term.field == .content
        case .and(let items), .or(let items): return items.contains { $0.usesContent }
        case .not(let item): return item.usesContent
        default: return false
        }
    }
}

// MARK: - Parsed query

public struct ParsedQuery: Sendable, Equatable {
    /// The complete parsed expression. Search evaluation always uses this.
    public var expression: QueryExpression
    /// `count:` function, if present.
    public var resultLimit: Int?
    /// `sort:` function, if present.
    public var sortSpecifications: [SortSpecification]
    /// `distinct:` function fields, if present.
    public var distinctFields: [String]
    /// The original text the user typed, kept for display and history.
    public var raw: String

    public init(
        expression: QueryExpression = .all,
        resultLimit: Int? = nil,
        sortSpecifications: [SortSpecification] = [],
        distinctFields: [String] = [],
        raw: String = ""
    ) {
        self.expression = expression
        self.resultLimit = resultLimit
        self.sortSpecifications = sortSpecifications
        self.distinctFields = distinctFields
        self.raw = raw
    }

    public var isEmpty: Bool { expression.isAll }

    // MARK: Legacy convenience views
    //
    // These keep Spotlight enrichment, highlighting and older call sites simple
    // while the full expression remains authoritative for the local engine.

    public var nameTerms: [String] {
        var result: [String] = []
        collectText(expression, fields: [.name], negated: false) { term, isNegated in
            if !isNegated && term.mode == .contains && !term.text.isEmpty { result.append(term.text) }
        }
        return result
    }

    public var excludedTerms: [String] {
        var result: [String] = []
        collectText(expression, fields: [.name, .path, .parentPath], negated: false) { term, isNegated in
            if isNegated && term.mode == .contains && !term.text.isEmpty { result.append(term.text) }
        }
        return result
    }

    public var pathTerms: [String] {
        var result: [String] = []
        collectText(expression, fields: [.path, .parentPath], negated: false) { term, isNegated in
            if !isNegated && term.mode == .contains && !term.text.isEmpty { result.append(term.text) }
        }
        return result
    }

    public var tagTerms: [String] {
        var result: [String] = []
        collectText(expression, fields: [.tag], negated: false) { term, isNegated in
            if !isNegated && term.mode == .contains && !term.text.isEmpty { result.append(term.text) }
        }
        return result
    }

    public var commentTerms: [String] {
        var result: [String] = []
        collectText(expression, fields: [.comment], negated: false) { term, isNegated in
            if !isNegated && term.mode == .contains && !term.text.isEmpty { result.append(term.text) }
        }
        return result
    }

    public var includeFiles: Bool {
        switch expression {
        case .type(let files, _): return files
        case .and(let items), .or(let items):
            let types = items.compactMap { item -> Bool? in
                if case .type(let files, _) = item { return files }
                return nil
            }
            return types.last ?? true
        default: return true
        }
    }

    public var includeFolders: Bool {
        switch expression {
        case .type(_, let folders): return folders
        case .and(let items), .or(let items):
            let types = items.compactMap { item -> Bool? in
                if case .type(_, let folders) = item { return folders }
                return nil
            }
            return types.last ?? true
        default: return true
        }
    }

    public var allowedExtensions: Set<String> {
        extensionValues(negated: false)
    }

    public var deniedExtensions: Set<String> {
        extensionValues(negated: true)
    }

    public var minSize: Int64? { numericBound(.size, lower: true) }
    public var maxSize: Int64? { numericBound(.size, lower: false) }
    public var modifiedAfter: Date? { dateBound(.modified, lower: true) }
    public var modifiedBefore: Date? { dateBound(.modified, lower: false) }
    public var createdAfter: Date? { dateBound(.created, lower: true) }
    public var createdBefore: Date? { dateBound(.created, lower: false) }

    /// A compact summary shown above the results.
    public var filterSummary: String {
        var parts: [String] = []
        if !includeFiles { parts.append(L("sadece klasörler")) }
        if !includeFolders { parts.append(L("sadece dosyalar")) }
        if !allowedExtensions.isEmpty {
            parts.append(L("ext: %@", allowedExtensions.sorted().joined(separator: ", ")))
        }
        if !deniedExtensions.isEmpty {
            parts.append(L("ext hariç: %@", deniedExtensions.sorted().joined(separator: ", ")))
        }
        if !pathTerms.isEmpty { parts.append(L("yol: %@", pathTerms.joined(separator: " "))) }
        if !tagTerms.isEmpty { parts.append(L("etiket: %@", tagTerms.joined(separator: " "))) }
        if !commentTerms.isEmpty { parts.append(L("yorum: %@", commentTerms.joined(separator: " "))) }
        if minSize != nil || maxSize != nil { parts.append(L("boyut")) }
        if modifiedAfter != nil || modifiedBefore != nil { parts.append(L("değişiklik tarihi")) }
        if createdAfter != nil || createdBefore != nil { parts.append(L("oluşturma tarihi")) }
        if !distinctFields.isEmpty { parts.append(L("tekil")) }
        if expression.usesContent { parts.append(L("içerik")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Legacy helpers

    private func collectText(
        _ expression: QueryExpression,
        fields: Set<QueryField>,
        negated: Bool,
        _ visitor: (TextTerm, Bool) -> Void
    ) {
        switch expression {
        case .text(let term):
            if fields.contains(term.field) && !term.text.isEmpty { visitor(term, negated) }
        case .child(let term, _, _):
            if fields.contains(term.field) && !term.text.isEmpty { visitor(term, negated) }
        case .exists(let term):
            if fields.contains(term.field) && !term.text.isEmpty { visitor(term, negated) }
        case .and(let items), .or(let items):
            for item in items { collectText(item, fields: fields, negated: negated, visitor) }
        case .not(let item):
            collectText(item, fields: fields, negated: !negated, visitor)
        default:
            break
        }
    }

    private func extensionValues(negated: Bool) -> Set<String> {
        func walk(_ expression: QueryExpression, into result: inout Set<String>, negated: Bool) {
            switch expression {
            case .ext(let values, let isNegated):
                if isNegated == negated { result.formUnion(values) }
            case .and(let items), .or(let items):
                for item in items { walk(item, into: &result, negated: negated) }
            case .not(let item):
                walk(item, into: &result, negated: !negated)
            default:
                break
            }
        }
        var result: Set<String> = []
        walk(expression, into: &result, negated: negated)
        return result
    }

    private func numericBound(_ property: NumericProperty, lower: Bool) -> Int64? {
        func walk(_ expression: QueryExpression) -> Int64? {
            switch expression {
            case .numeric(let comparison) where comparison.property == property:
                return lower ? comparison.min : comparison.max
            case .and(let items), .or(let items):
                for item in items { if let found = walk(item) { return found } }
                return nil
            default:
                return nil
            }
        }
        return walk(expression)
    }

    private func dateBound(_ property: DateProperty, lower: Bool) -> Date? {
        func walk(_ expression: QueryExpression) -> Date? {
            switch expression {
            case .date(let comparison) where comparison.property == property:
                return lower ? comparison.min : comparison.max
            case .and(let items), .or(let items):
                for item in items { if let found = walk(item) { return found } }
                return nil
            default:
                return nil
            }
        }
        return walk(expression)
    }
}
