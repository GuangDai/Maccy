import Logging
import os
import SwiftUI

/// Lazily resolves and caches the icon for a clipboard source application,
/// keeping it fresh when the bundle is deleted, renamed, or replaced.
@MainActor
class ApplicationImage {
  private static let logger = Logger(label: "org.p0deje.Maccy")
  fileprivate static let fallbackImage = NSImage(
    systemSymbolName: "questionmark.app.dashed",
    accessibilityDescription: nil
  ) ?? NSImage()
  private static let retryInterval: TimeInterval = 60 * 60

  let bundleIdentifier: String?
  private let resolveApplicationURL: @MainActor (String) -> URL?
  private let loadIcon: @MainActor (URL) -> NSImage
  private var image: NSImage?
  private var lastChecked: Date?
  private(set) var watchedApplicationURL: URL?
  // The dispatch source is reached from both the @MainActor getter/handler and
  // the nonisolated deinit. ApplicationImageCache holds these instances in an
  // NSCache, whose memory-pressure eviction is not guaranteed to run on the main
  // thread; a main-isolated stored property would force the deinit to hop or
  // assert onto main to cancel. Holding the source in a nonisolated Sendable
  // lock lets the deinit cancel it from any thread. DispatchSourceFileSystemObject
  // is Sendable, so the lock's state is Sendable and this compiles under Swift 6
  // complete mode with no nonisolated(unsafe).
  nonisolated private let eventSourceLock = OSAllocatedUnfairLock<
    (any DispatchSourceFileSystemObject)?
  >(initialState: nil)

  init(
    bundleIdentifier: String?,
    image: NSImage? = nil,
    resolveApplicationURL: @escaping @MainActor (String) -> URL? = {
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
    },
    loadIcon: @escaping @MainActor (URL) -> NSImage = {
      NSWorkspace.shared.icon(forFile: $0.path)
    }
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.image = image
    self.resolveApplicationURL = resolveApplicationURL
    self.loadIcon = loadIcon
  }

  deinit {
    // NSCache may evict on a background thread under memory pressure, so this
    // nonisolated deinit is not guaranteed to run on main. Cancel the source
    // under the lock; DispatchSourceProtocol.cancel() is documented thread-safe,
    // so this is correct on any thread and needs no MainActor.assumeIsolated
    // (which would trap off-main with the same dispatch_assert_queue_fail
    // signature as the 2.6.1 dispatch-source crash).
    eventSourceLock.withLock { $0?.cancel() }
  }

  /// The resolved application icon, or the fallback image if the bundle cannot be found.
  var nsImage: NSImage {
    guard let bundleIdentifier else {
      return Self.fallbackImage
    }

    if let image {
      return image
    }

    // The bundle was not found on a previous lookup (the app may have been
    // uninstalled). Only retry after `retryInterval` so the fallback does not
    // cause repeated `NSWorkspace` lookups on every layout pass.
    if let lastChecked,
      Date().timeIntervalSince(lastChecked) < Self.retryInterval {
      return Self.fallbackImage
    }
    lastChecked = .now

    if let appURL = resolveApplicationURL(bundleIdentifier) {
      let img = loadIcon(appURL)
      image = img

      stopWatching()
      let descriptor = open(appURL.path, O_EVTONLY)
      guard descriptor != -1 else {
        let errorCode = errno
        let reason = String(cString: strerror(errorCode))
        Self.logger.error("open \(appURL.path): error \(errorCode) \(reason)")
        return img
      }
      // Defensive fd guard: ensure `descriptor` is closed if we leave scope
      // before the cancel handler is installed. `makeFileSystemObjectSource`
      // does not throw today, but a future change that fails between `open` and
      // `resume` would otherwise leak the fd. The source is stored on the lock
      // only after the cancel handler is in place.
      var sourceInstalled = false
      defer { if !sourceInstalled { close(descriptor) } }
      // The dispatch source fires its handler on the main queue. The handler
      // closure is non-@Sendable, so it inherits this class's @MainActor
      // isolation; running it anywhere but main would trip the @MainActor
      // prologue (`dispatch_assert_queue(main)`) before the body executes. A
      // background queue here was a latent SIGTRAP that fired only when a
      // watched bundle was deleted or renamed.
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: [.delete, .rename],
        queue: DispatchQueue.main
      )
      source.setEventHandler { [weak self] in
        guard let self else {
          return
        }
        // Read the source out of the lock, then read `.data` on the unwrapped
        // value so the member resolves to `DispatchSource.FileSystemEvent`
        // (through the existential's optional-chaining inside the lock closure
        // it instead resolves to `DispatchSourceProtocol.data: UInt`).
        let eventSource = self.eventSourceLock.withLock { $0 }
        guard let eventSource else {
          return
        }
        let event = eventSource.data
        if event.contains(.delete) {
          // App bundle deleted (uninstalled) — drop the cached icon.
          Self.logger.info("ApplicationImage: deleted \(appURL.path)")
          self.stopWatching()
          self.image = nil
        } else if event.contains(.rename) {
          // App bundle renamed/replaced (e.g. updated) — resolve its current
          // URL and arm a new source instead of reading the stale captured path.
          Self.logger.info("ApplicationImage: renamed \(appURL.path)")
          self.reloadAfterRename()
        }
      }
      source.setCancelHandler {
        close(descriptor)
      }
      eventSourceLock.withLock { $0 = source }
      watchedApplicationURL = appURL
      sourceInstalled = true
      source.resume()

      return img
    }

    return Self.fallbackImage
  }

  /// Invalidates a renamed bundle's old descriptor, resolves the bundle id
  /// again, reloads its icon, and arms a source for the newly resolved URL.
  @discardableResult
  func reloadAfterRename() -> NSImage {
    stopWatching()
    image = nil
    lastChecked = nil
    return nsImage
  }

  /// Cancels and detaches the current file-system source. The cancel handler
  /// owns descriptor closure, so replacing a source cannot leak the old fd.
  private func stopWatching() {
    let source = eventSourceLock.withLock { current in
      let source = current
      current = nil
      return source
    }
    source?.cancel()
    watchedApplicationURL = nil
  }
}
