import Foundation
import SwiftData

/// Persistence operations `History` relies on, isolated to `@MainActor`.
protocol HistoryPersistence {
  @MainActor
  func insert(_ item: HistoryItem) throws
  @MainActor
  func delete(_ item: HistoryItem) throws
  @MainActor
  func deleteUnpinned() throws
  @MainActor
  func deleteAll() throws
  @MainActor
  func save() throws
  @MainActor
  func fetchAll() throws -> [HistoryItem]
  @MainActor
  func countHistoryItems() throws -> Int
  @MainActor
  func countHistoryItemContents() throws -> Int
}

/// `HistoryPersistence` backed by `Storage.shared.context` (the main SwiftData
/// context). Each mutating method processes pending changes and saves.
struct SwiftDataHistoryPersistence: HistoryPersistence {
  @MainActor
  func insert(_ item: HistoryItem) throws {
    Storage.shared.context.insert(item)
    Storage.shared.context.processPendingChanges()
    try Storage.shared.context.save()
  }

  @MainActor
  func delete(_ item: HistoryItem) throws {
    Storage.shared.context.delete(item)
    Storage.shared.context.processPendingChanges()
    try Storage.shared.context.save()
  }

  @MainActor
  func deleteUnpinned() throws {
    try Storage.shared.context.transaction {
      try Storage.shared.context.delete(
        model: HistoryItem.self,
        where: #Predicate { $0.pin == nil }
      )
      try Storage.shared.context.delete(
        model: HistoryItemContent.self,
        where: #Predicate { $0.item?.pin == nil }
      )
    }
    Storage.shared.context.processPendingChanges()
    try Storage.shared.context.save()
  }

  @MainActor
  func deleteAll() throws {
    try Storage.shared.context.delete(model: HistoryItem.self)
    Storage.shared.context.processPendingChanges()
    try Storage.shared.context.save()
  }

  @MainActor
  func save() throws {
    Storage.shared.context.processPendingChanges()
    try Storage.shared.context.save()
  }

  @MainActor
  func fetchAll() throws -> [HistoryItem] {
    try Storage.shared.context.fetch(FetchDescriptor<HistoryItem>())
  }

  @MainActor
  func countHistoryItems() throws -> Int {
    try Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>())
  }

  @MainActor
  func countHistoryItemContents() throws -> Int {
    try Storage.shared.context.fetchCount(FetchDescriptor<HistoryItemContent>())
  }
}
