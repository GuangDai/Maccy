import Foundation
@testable import Maccy

@MainActor
struct HistoryBuilder {
  private var contents: [HistoryItemContent] = []
  private var application: String?
  private var firstCopiedAt = Date(timeIntervalSince1970: 1_717_171_717)
  private var lastCopiedAt = Date(timeIntervalSince1970: 1_717_171_717)
  private var numberOfCopies = 1
  private var pin: String?
  private var title: String?

  func withContent(type: String, value: Data?) -> Self {
    var builder = self
    builder.contents.append(HistoryItemContent(type: type, value: value))
    return builder
  }

  func withApplication(_ application: String?) -> Self {
    var builder = self
    builder.application = application
    return builder
  }

  func withCopiedAt(_ date: Date) -> Self {
    var builder = self
    builder.firstCopiedAt = date
    builder.lastCopiedAt = date
    return builder
  }

  func withNumberOfCopies(_ count: Int) -> Self {
    var builder = self
    builder.numberOfCopies = count
    return builder
  }

  func withPin(_ pin: String?) -> Self {
    var builder = self
    builder.pin = pin
    return builder
  }

  func withTitle(_ title: String?) -> Self {
    var builder = self
    builder.title = title
    return builder
  }

  func build() -> HistoryItem {
    let item = HistoryItem(contents: contents)
    item.application = application
    item.firstCopiedAt = firstCopiedAt
    item.lastCopiedAt = lastCopiedAt
    item.numberOfCopies = numberOfCopies
    item.pin = pin
    item.title = title ?? item.generateTitle()
    return item
  }
}

/// Seeds test history through the committed store + `StoreEvent` projection
/// used by the live background-ingest path, never through legacy `History.add`.
@MainActor
enum HistoryTestDriver {
  enum SeedError: Error {
    case missingDecorator
  }

  /// Commits and consumes one item, returning its projected decorator.
  static func seed(
    _ item: HistoryItem,
    in history: History = .shared
  ) throws -> HistoryItemDecorator {
    let seeded = try seed([item], in: history)
    guard let decorator = seeded.first else {
      throw SeedError.missingDecorator
    }
    return decorator
  }

  /// Commits all items in one save, consumes their added events in order, and
  /// returns the decorators resolved by stable persistent identity.
  static func seed(
    _ items: [HistoryItem],
    in history: History = .shared
  ) throws -> [HistoryItemDecorator] {
    let context = Storage.shared.context
    for item in items {
      context.insert(item)
    }
    context.processPendingChanges()
    try context.save()

    for item in items {
      history.consume(.added(snapshot(of: item)))
    }

    let decoratorsByID = Dictionary(
      uniqueKeysWithValues: history.all.map { ($0.item.persistentModelID, $0) }
    )
    return try items.map { item in
      guard let decorator = decoratorsByID[item.persistentModelID] else {
        throw SeedError.missingDecorator
      }
      return decorator
    }
  }
}
