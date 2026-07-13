import Foundation
import SwiftData

/// Persistence operations `History` relies on, isolated to `@MainActor`.
protocol HistoryPersistence {
  @MainActor
  func delete(_ item: HistoryItem) throws
  @MainActor
  func delete(_ items: [HistoryItem]) throws
  @MainActor
  func deleteUnpinned() throws
  @MainActor
  func deleteAll() throws
  @MainActor
  func save() throws
  @MainActor
  func fetchAll() throws -> [HistoryItem]
  @MainActor
  func model(for id: PersistentIdentifier) -> HistoryItem?
  @MainActor
  func countHistoryItems() throws -> Int
  @MainActor
  func countHistoryItemContents() throws -> Int
}

/// `HistoryPersistence` backed by a caller-provided SwiftData context. Each
/// mutating method processes pending changes and saves.
@MainActor
struct SwiftDataHistoryPersistence: HistoryPersistence {
  private let context: ModelContext

  init(context: ModelContext) {
    self.context = context
  }

  func delete(_ item: HistoryItem) throws {
    context.delete(item)
    context.processPendingChanges()
    try context.save()
  }

  func delete(_ items: [HistoryItem]) throws {
    guard !items.isEmpty else { return }
    try context.transaction {
      for item in items {
        context.delete(item)
      }
    }
    context.processPendingChanges()
    try context.save()
  }

  func deleteUnpinned() throws {
    // Predicate deletion evaluates persisted rows, not unsaved inserts. Commit
    // any pending main-context edits first so the same operation can delete a
    // newly inserted unpinned item while preserving pending pinned items.
    if context.hasChanges {
      try context.save()
    }
    try context.transaction {
      try context.delete(
        model: HistoryItem.self,
        where: #Predicate { $0.pin == nil }
      )
      try context.delete(
        model: HistoryItemContent.self,
        where: #Predicate { $0.item?.pin == nil }
      )
    }
    context.processPendingChanges()
    try context.save()
  }

  func deleteAll() throws {
    if context.hasChanges {
      try context.save()
    }
    try context.transaction {
      try context.delete(model: HistoryItem.self)
      try context.delete(model: HistoryItemContent.self)
    }
    context.processPendingChanges()
    try context.save()
  }

  func save() throws {
    context.processPendingChanges()
    try context.save()
  }

  func fetchAll() throws -> [HistoryItem] {
    try context.fetch(FetchDescriptor<HistoryItem>())
  }

  func model(for id: PersistentIdentifier) -> HistoryItem? {
    context.model(for: id) as? HistoryItem
  }

  func countHistoryItems() throws -> Int {
    try context.fetchCount(FetchDescriptor<HistoryItem>())
  }

  func countHistoryItemContents() throws -> Int {
    try context.fetchCount(FetchDescriptor<HistoryItemContent>())
  }
}
