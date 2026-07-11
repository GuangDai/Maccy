import Defaults
import Foundation

/// Owns application-object wiring and infrastructure startup.
@MainActor
final class CompositionRoot {
  private let appState: AppState
  private let clipboard: Clipboard
  private let storage: Storage
  private let imageProcessor: any ImageProcessing

  /// Creates the production composition from the existing application objects.
  init(
    appState: AppState = .shared,
    clipboard: Clipboard = .shared,
    storage: Storage = .shared,
    imageProcessor: any ImageProcessing = HistoryItemDecorator.defaultImageProcessor
  ) {
    self.appState = appState
    self.clipboard = clipboard
    self.storage = storage
    self.imageProcessor = imageProcessor
  }

  /// Installs application bridges and starts clipboard ingestion before launch completes.
  func prepareForLaunch(appDelegate: AppDelegate) {
    appState.appDelegate = appDelegate
    HistoryCommandServices.current = AppHistoryCommandService(
      history: appState.history,
      navigator: appState.navigator
    )

    let history = appState.history
    clipboard.ingestor = BackgroundClipboardIngestor(
      modelContainer: storage.container,
      image: imageProcessor,
      now: { Date() },
      onEvent: { @MainActor event, trimmedPersistentIDs in
        history.consume(event, trimmedPersistentIDs: trimmedPersistentIDs)
      }
    )
    clipboard.start()

    let clipboardObserver = clipboard
    Task {
      for await _ in Defaults.updates(.clipboardCheckInterval, initial: false) {
        clipboardObserver.restart()
      }
    }
  }

  /// Attaches and starts memory governance after the application UI is built.
  func finishLaunching(memoryGovernor: MemoryGovernor = .shared) {
    memoryGovernor.attach(history: appState.history)
    memoryGovernor.start()
  }
}
