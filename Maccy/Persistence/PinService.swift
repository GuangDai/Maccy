import Logging
import Sauce
import SwiftData

/// Queries assigned pin shortcuts and derives the keys that remain available.
@MainActor
struct PinService {
  /// Pin keys not reserved for other shortcuts.
  static var supportedPins: Set<String> {
    // Keys reserved for built-in shortcuts: "a" (select all), "q" (quit),
    // "v" (paste), "w" (close window), "z" (undo/redo).
    var keys = Set([
      "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l",
      "m", "n", "o", "p", "r", "s", "t", "u", "x", "y"
    ])

    if let deleteKey = KeyChord.deleteKey,
       let character = Sauce.shared.character(for: Int(deleteKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }

    if let pinKey = KeyChord.pinKey,
       let character = Sauce.shared.character(for: Int(pinKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }
    if let previewKey = KeyChord.previewKey,
       let character = Sauce.shared.character(for: Int(previewKey.QWERTYKeyCode), cocoaModifiers: []) {
      keys.remove(character)
    }

    return keys
  }

  private let context: ModelContext
  private let logger = Logger(label: "org.p0deje.Maccy")

  /// Creates a pin query module over the caller-owned model context.
  init(context: ModelContext) {
    self.context = context
  }

  /// Supported pin keys that are not assigned to a stored history item.
  var availablePins: [String] {
    let descriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin != nil }
    )
    let pins: [String]
    do {
      pins = try context.fetch(descriptor).compactMap(\.pin)
    } catch {
      logger.error("Failed to fetch assigned pins: \(String(describing: error))")
      pins = []
    }

    return Array(Self.supportedPins.subtracting(Set(pins)))
  }

  /// A random unassigned pin key, or nil if every supported key is taken.
  var randomAvailablePin: String? { availablePins.randomElement() }
}
