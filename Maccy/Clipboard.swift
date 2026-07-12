import AppKit
import Defaults
import Sauce

/// Observes the system pasteboard and dispatches copies to the off-main ingest actor.
@MainActor
class Clipboard {
  struct TimerConfiguration {
    let interval: TimeInterval
    let tolerance: TimeInterval
    let runLoopMode: RunLoop.Mode
  }

  /// Shared clipboard observer instance.
  static let shared = Clipboard()

  /// Last `NSPasteboard.changeCount` observed; mismatch signals a new copy.
  var changeCount: Int

  /// The off-main ingest actor this clipboard dispatches copies to.
  ///
  /// `AppDelegate` sets this at launch to a `BackgroundClipboardIngestor` whose
  /// `onEvent` reconciles the main-context history via `History.consume`. When
  /// set, `checkForChangesInPasteboard()` builds a raw `IngestRequest` from
  /// `NSPasteboardSource().snapshot()` and hands it off to the actor in a task;
  /// the filtering, dedup, and single-transaction write all happen off the main
  /// thread inside the actor's `filterContents`. When `nil` (e.g. legacy tests
  /// that haven't wired an ingestor) the ingest half of
  /// `checkForChangesInPasteboard` no-ops, but the change-detection gates still
  /// run.
  var ingestor: ClipboardIngestor?

  private let pasteboard = NSPasteboard.general

  private var timer: Timer?

  /// Serializes burst dispatch without dropping already-observed copies.
  private let ingestMailbox = IngestMailbox()

  /// The application currently in the foreground when a copy is observed.
  private var sourceApp: NSRunningApplication? { NSWorkspace.shared.frontmostApplication }

  init() {
    changeCount = pasteboard.changeCount
  }

  /// Starts the pasteboard polling timer.
  func start() {
    timer?.invalidate()
    let configuration = Self.timerConfiguration(checkInterval: Defaults[.clipboardCheckInterval])
    let timer = Timer(
      timeInterval: configuration.interval,
      target: self,
      selector: #selector(checkForChangesInPasteboard),
      userInfo: nil,
      repeats: true
    )
    timer.tolerance = configuration.tolerance
    self.timer = timer
    RunLoop.main.add(timer, forMode: configuration.runLoopMode)
  }

  static func timerConfiguration(checkInterval: TimeInterval) -> TimerConfiguration {
    let interval = max(0.1, checkInterval)
    return TimerConfiguration(
      interval: interval,
      tolerance: interval * 0.1,
      runLoopMode: .common
    )
  }

  /// Restarts the pasteboard polling timer with the current check interval.
  func restart() {
    timer?.invalidate()
    start()
  }

  /// Copies a plain string onto the pasteboard and triggers change detection.
  @MainActor
  func copy(_ string: String) {
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
    sync()
    checkForChangesInPasteboard()
  }

  /// Copies a history item onto the pasteboard.
  ///
  /// - Parameter removeFormatting: When true, drops non-string representations
  ///   except file URLs.
  @MainActor
  func copy(_ item: HistoryItem?, removeFormatting: Bool = false) {
    guard let item else { return }

    pasteboard.clearContents()
    var contents = item.contents

    if removeFormatting {
      contents = clearFormatting(contents)
    }

    for content in contents {
      guard content.type != NSPasteboard.PasteboardType.fileURL.rawValue else { continue }
      pasteboard.setData(content.value, forType: NSPasteboard.PasteboardType(content.type))
    }

    // Use writeObjects for file URLs so that multiple copied files work.
    // Only do this for file URLs: it duplicates some other data types (e.g.
    // formatted text) when pasted.
    let fileURLItems: [NSURL] = contents.compactMap { item in
      guard item.type == NSPasteboard.PasteboardType.fileURL.rawValue else { return nil }
      guard let value = item.value else { return nil }
      guard let url = URL(dataRepresentation: value, relativeTo: nil, isAbsolute: true) else { return nil }
      return url as NSURL
    }
    pasteboard.writeObjects(fileURLItems)

    pasteboard.setString("", forType: .fromMaccy)
    pasteboard.setString(item.application ?? "", forType: .source)
    sync()

    Task { @MainActor in
      Notifier.notify(body: item.title, sound: .knock)
      checkForChangesInPasteboard()
    }
  }

  /// Synthesizes the system paste key chord.
  ///
  /// Based on https://github.com/Clipy/Clipy/blob/develop/Clipy/Sources/Services/PasteService.swift.
  func paste() {
    Accessibility.check()

    // Add flag that left/right modifier key has been pressed.
    // See https://github.com/TermiT/Flycut/pull/18 for details.
    let cmdFlag = CGEventFlags(rawValue: UInt64(KeyChord.pasteKeyModifiers.rawValue) | 0x000008)
    var vCode = Sauce.shared.keyCode(for: KeyChord.pasteKey)

    // Force QWERTY keycode when keyboard layout switches to
    // QWERTY upon pressing ⌘ key (e.g. "Dvorak - QWERTY ⌘").
    // See https://github.com/p0deje/Maccy/issues/482 for details.
    if KeyboardLayout.current.commandSwitchesToQWERTY && cmdFlag.contains(.maskCommand) {
      vCode = KeyChord.pasteKey.QWERTYKeyCode
    }

    let source = CGEventSource(stateID: .combinedSessionState)
    // Disable local keyboard events while pasting
    source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                       state: .eventSuppressionStateSuppressionInterval)

    let keyVDown = CGEvent(keyboardEventSource: source, virtualKey: vCode, keyDown: true)
    let keyVUp = CGEvent(keyboardEventSource: source, virtualKey: vCode, keyDown: false)
    guard let keyVDown = keyVDown, let keyVUp = keyVUp else {
      return
    }
    keyVDown.flags = cmdFlag
    keyVUp.flags = cmdFlag
    keyVDown.post(tap: .cgSessionEventTap)
    keyVUp.post(tap: .cgSessionEventTap)
  }

  /// Clears the system pasteboard when the user has enabled clearing on quit.
  func clear() {
    guard Defaults[.clearSystemClipboard] else {
      return
    }

    pasteboard.clearContents()
  }

  /// Detects a pasteboard change and dispatches a raw `IngestRequest` to the
  /// off-main `ingestor` actor.
  ///
  /// The change-detection gates (changeCount, paste-stack interrupt,
  /// `ignoreEvents` / `ignoreOnlyNextEvent`, the cheap `shouldIgnore` fast
  /// paths over pasteboard types and the source app) stay here on the main
  /// thread because they are O(types) and must run before any pasteboard read.
  /// Once the gates clear, the pasteboard is snapshotted into plain value
  /// types via `NSPasteboardSource().snapshot()` and handed to the lossless FIFO
  /// ingest mailbox; its single drain task calls the actor one request at a time.
  /// The actor's `filterContents` is the comprehensive,
  /// unit-tested filter — the `shouldIgnore` calls above are only a fast path,
  /// not the authoritative filter. When `ingestor` is `nil` the dispatch is a
  /// no-op (the gates still ran), which keeps legacy unwired callers/tests
  /// working.
  @objc
  @MainActor
  func checkForChangesInPasteboard() {
    guard pasteboard.changeCount != changeCount else {
      return
    }

    changeCount = pasteboard.changeCount

    if Defaults[.ignoreEvents] {
      if Defaults[.ignoreOnlyNextEvent] {
        Defaults[.ignoreEvents] = false
        Defaults[.ignoreOnlyNextEvent] = false
      }

      return
    }

    // Reading types on NSPasteboard gives all the available
    // types - even the ones that are not present on the NSPasteboardItem.
    // See https://github.com/p0deje.Maccy/issues/241.
    if shouldIgnore(Set(pasteboard.types ?? [])) {
      return
    }

    if let sourceAppBundle = sourceApp?.bundleIdentifier, shouldIgnore(sourceAppBundle) {
      return
    }

    guard let request = ingestRequestFromPasteboard() else {
      return
    }

    guard let ingestor else {
      return
    }

    ingestMailbox.submit(request, to: ingestor) { [weak self] result in
      self?.surfaceIngestFailureIfNeeded(result)
    }
  }

  /// Surfaces a persistence failure (the actor set
  /// `IngestResult.persistenceFailed`) onto `History.lastPersistError` so a lost
  /// copy is diagnosable instead of only a log line (NEW-ingest-dualpath-4). The
  /// actor already logged the error detail; this flags it on the main-side state.
  func surfaceIngestFailureIfNeeded(_ result: IngestResult) {
    guard result.persistenceFailed else { return }
    History.shared.lastPersistError = ClipboardIngestPersistenceError()
  }

  private struct ClipboardIngestPersistenceError: Error {}

  /// Builds a raw, unfiltered `IngestRequest` from the current pasteboard
  /// snapshot.
  ///
  /// Flattens every `PasteboardItemSnapshot.contents` map (type→bytes) into
  /// `[ContentDTO]` (fingerprint left `nil` — the actor computes fingerprints
  /// lazily inside `HistoryItemEngine`; `size` is the byte count). Returns
  /// `nil` when there is nothing to ingest (empty pasteboard or every type
  /// empty), so the caller can short-circuit before spawning a `Task`. Type
  /// filtering, the `maxValueSize` cap, and rich-text/empty-string handling all
  /// happen inside the actor's `filterContents`; this builder records exactly
  /// what was on the pasteboard.
  @MainActor
  func ingestRequestFromPasteboard() -> IngestRequest? {
    let source = NSPasteboardSource()
    var contents: [ContentDTO] = []
    for snapshot in source.snapshot() {
      for (type, bytes) in snapshot.contents {
        contents.append(
          ContentDTO(type: type, value: bytes, fingerprint: nil, size: bytes.count)
        )
      }
    }

    guard !contents.isEmpty else {
      return nil
    }

    return IngestRequest(
      source: CopyOrigin(changeCount: source.changeCount),
      contents: contents,
      application: sourceApp?.bundleIdentifier,
      now: Date(),
      policy: .liveSnapshot()
    )
  }
}

private extension Clipboard {
  /// Returns true when none of the enabled types are present, or any ignored
  /// type is.
  private func shouldIgnore(_ types: Set<NSPasteboard.PasteboardType>) -> Bool {
    let rawTypes = Set(types.map(\.rawValue))
    let enabledTypes = Set(Defaults[.enabledPasteboardTypes].map(\.rawValue))
    let ignoredTypes = IngestFilterRules.builtInIgnoredTypes
      .union(Defaults[.ignoredPasteboardTypes])

    return rawTypes.isDisjoint(with: enabledTypes) ||
      !rawTypes.isDisjoint(with: ignoredTypes)
  }

  /// Returns true when the source app's bundle id matches the ignore list
  /// (inverted when "ignore all except listed" is set).
  private func shouldIgnore(_ sourceAppBundle: String) -> Bool {
    if Defaults[.ignoreAllAppsExceptListed] {
      return !Defaults[.ignoredApps].contains(sourceAppBundle)
    } else {
      return Defaults[.ignoredApps].contains(sourceAppBundle)
    }
  }

  /// Some applications require the window to lose and regain focus to sync the
  /// clipboard:
  /// - Chrome Remote Desktop (https://github.com/p0deje/Maccy/issues/948)
  /// - Netbeans (https://github.com/p0deje/Maccy/issues/879)
  private func sync() {
    guard let app = sourceApp,
          app.bundleURL?.lastPathComponent == "Chrome Remote Desktop.app" ||
            app.localizedName?.contains("NetBeans") == true else {
      return
    }

    NSApp.activate(ignoringOtherApps: true)
    NSApp.hide(self)
  }

  /// Drops non-string representations from contents, preserving file URLs.
  private func clearFormatting(_ contents: [HistoryItemContent]) -> [HistoryItemContent] {
    var newContents: [HistoryItemContent] = contents
    let stringContents = contents.filter { NSPasteboard.PasteboardType($0.type) == .string }

    // If there is no string representation of data,
    // behave like we didn't have to remove formatting.
    if !stringContents.isEmpty {
      newContents = stringContents

      // Preserve file URLs.
      // https://github.com/p0deje/Maccy/issues/962
      let fileURLContents = contents.filter { NSPasteboard.PasteboardType($0.type) == .fileURL }
      if !fileURLContents.isEmpty {
        newContents += fileURLContents
      }
    }

    return newContents
  }
}
