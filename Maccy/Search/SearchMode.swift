import Defaults
import Foundation

/// Namespace for the user-selected search mode and shared regexp guards.
enum Search {
  enum Mode: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable, Sendable {
    case exact
    case fuzzy
    case regexp
    case mixed

    var id: Self { self }

    var description: String {
      switch self {
      case .exact:
        return NSLocalizedString("Exact", tableName: "GeneralSettings", comment: "")
      case .fuzzy:
        return NSLocalizedString("Fuzzy", tableName: "GeneralSettings", comment: "")
      case .regexp:
        return NSLocalizedString("Regex", tableName: "GeneralSettings", comment: "")
      case .mixed:
        return NSLocalizedString("Mixed", tableName: "GeneralSettings", comment: "")
      }
    }

    var abbreviation: String {
      switch self {
      case .exact: return "EX"
      case .fuzzy: return "FZ"
      case .regexp: return "RE"
      case .mixed: return "MX"
      }
    }

    var next: Self {
      let all = Self.allCases
      guard let index = all.firstIndex(of: self) else { return all[0] }
      return all[(index + 1) % all.count]
    }
  }

  /// Rejects known catastrophic-backtracking shapes before regex compilation.
  nonisolated static func isLikelyUnsafeRegularExpression(_ pattern: String) -> Bool {
    guard pattern.count <= TextLimits.regexpInput else {
      return true
    }
    let nestedQuantifierPattern = #"\([^)]*([+*]|\{\d+,?\d*\})[^)]*\)([+*]|\{\d+,?\d*\})"#
    return pattern.range(of: nestedQuantifierPattern, options: .regularExpression) != nil
  }

  /// Whether a pattern contains syntax that can add matches after exact search.
  nonisolated static func containsRegularExpressionMetacharacter(_ pattern: String) -> Bool {
    pattern.rangeOfCharacter(from: CharacterSet(charactersIn: #"\.[]{}()*+?^$|"#)) != nil
  }
}
