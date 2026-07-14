import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Actor-owned running total for thumbnail disk usage.
///
/// The ledger knows when a fresh directory inventory is required, but owns no
/// file-system behavior. `nil` means the total has not been established (or a
/// mutation could not be measured), so the next successful write inventories
/// lazily rather than adding work during cache construction.
struct ThumbnailDiskUsageLedger {
  enum Maintenance: Equatable {
    case none
    case inventory
  }

  let budget: Int
  private(set) var totalBytes: Int?

  mutating func recordWrite(replacing previousBytes: Int?, with currentBytes: Int?) -> Maintenance {
    guard let totalBytes, let previousBytes, let currentBytes else {
      return .inventory
    }

    let updatedBytes = max(0, totalBytes - max(0, previousBytes) + max(0, currentBytes))
    self.totalBytes = updatedBytes
    return updatedBytes > budget ? .inventory : .none
  }

  mutating func recordRemoval(bytes: Int?) {
    guard let totalBytes, let bytes else {
      self.totalBytes = nil
      return
    }
    self.totalBytes = max(0, totalBytes - max(0, bytes))
  }

  mutating func recordInventory(totalBytes: Int) {
    self.totalBytes = max(0, totalBytes)
  }

  mutating func invalidate() {
    totalBytes = nil
  }
}

/// Two-tier (memory + disk-LRU) thumbnail cache for the image pipeline.
///
/// An `actor` (not `final class @unchecked Sendable`) because `NSCache`'s
/// internal locking only serializes its own dictionary — it does NOT serialize
/// the disk-LRU writes that this type performs. The actor gives both
/// Sendability and mutual exclusion over the disk path.
///
/// The cache key is the composite `(MaccyFingerprint, maxPixelSize)`. A
/// fingerprint-only key would return a stale, wrong-sized thumbnail after the
/// user changes `Defaults[.imageMaxHeight]` (which triggers `cleanupImages` +
/// rebuild in `History`). `MaccyFingerprint` does not encode pixel dimensions,
/// so the size must live in the key.
actor ThumbnailCache {
  /// Soft upper bound on total on-disk thumbnail bytes before LRU eviction.
  private static let diskByteBudget: Int = 256 * 1024 * 1024

  private let memory: NSCache<ThumbnailCacheKey, NSImage> = {
    let cache = NSCache<ThumbnailCacheKey, NSImage>()
    cache.countLimit = 256
    cache.totalCostLimit = 64 * 1024 * 1024
    return cache
  }()

  private let diskDirectory: URL
  private let downsample: @Sendable (Data, CGFloat) -> CGImage?
  private var diskUsage: ThumbnailDiskUsageLedger

  /// - Parameter diskDirectory: Where PNG thumbnails are persisted. `nil`
  ///   means the default `~/Library/Application Support/Maccy/Thumbnails/`.
  ///   Tests inject a temp directory so they never touch the runner's real
  ///   Application Support.
  init(
    diskDirectory: URL? = nil,
    downsample: @escaping @Sendable (Data, CGFloat) -> CGImage? = { data, maxPixelSize in
      ImageDownsampler.thumbnail(data: data, max: maxPixelSize)
    }
  ) {
    let resolved = diskDirectory ?? Self.defaultDirectory
    self.diskDirectory = resolved
    self.downsample = downsample
    diskUsage = ThumbnailDiskUsageLedger(budget: Self.diskByteBudget)
    try? FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
  }

  private static var defaultDirectory: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return support.appending(path: "Maccy", directoryHint: .isDirectory)
      .appending(path: "Thumbnails", directoryHint: .isDirectory)
  }

  /// Returns a thumbnail for `fingerprint`, building it from `data` (downsampled
  /// to `maxPixelSize`) on miss. Memory hit → disk hit → build → persist.
  func thumbnail(for fingerprint: MaccyFingerprint, data: Data, max maxPixelSize: CGFloat) async -> NSImage? {
    let key = ThumbnailCacheKey(fingerprint: fingerprint, maxPixelSize: Int(maxPixelSize))
    if let cached = memory.object(forKey: key) {
      return cached
    }

    let fileURL = diskURL(forKey: key)
    let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
    if fileExists, let image = readDisk(at: fileURL) {
      memory.setObject(image, forKey: key, cost: diskCost(image))
      return image
    }

    guard let cgImage = downsample(data, maxPixelSize) else {
      return nil
    }
    guard !Task.isCancelled else {
      return nil
    }

    let previousBytes = fileExists ? diskFileSize(at: fileURL) : 0
    if writeDisk(cgImage: cgImage, to: fileURL) {
      let maintenance = diskUsage.recordWrite(
        replacing: previousBytes,
        with: diskFileSize(at: fileURL)
      )
      if maintenance == .inventory {
        inventoryAndEvictIfNeeded()
      }
    } else {
      diskUsage.invalidate()
    }

    let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    memory.setObject(image, forKey: key, cost: Int(cgImage.width) * Int(cgImage.height) * 4)
    return image
  }

  /// Removes both the memory and disk entry for `(fingerprint, maxPixelSize)`.
  func evict(fingerprint: MaccyFingerprint, max maxPixelSize: CGFloat) async {
    let key = ThumbnailCacheKey(fingerprint: fingerprint, maxPixelSize: Int(maxPixelSize))
    memory.removeObject(forKey: key)
    let url = diskURL(forKey: key)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let bytes = diskFileSize(at: url)
    do {
      try FileManager.default.removeItem(at: url)
      diskUsage.recordRemoval(bytes: bytes)
    } catch {
      return
    }
  }

  // MARK: - Disk

  private func diskURL(forKey key: ThumbnailCacheKey) -> URL {
    let name = "\(key.fingerprint.hash)-\(key.fingerprint.size)-\(key.maxPixelSize).png"
    return diskDirectory.appending(path: name)
  }

  private func readDisk(at url: URL) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      return nil
    }
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      return nil
    }
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
  }

  private func writeDisk(cgImage: CGImage, to url: URL) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else { return false }
    CGImageDestinationAddImage(destination, cgImage, nil)
    return CGImageDestinationFinalize(destination)
  }

  /// Best-effort LRU: if the directory's total file size exceeds the budget,
  /// delete oldest-modified files until under budget. A running byte ledger
  /// requests this inventory only while unknown or after crossing the budget.
  private struct DiskEntry {
    let url: URL
    let size: Int
    let mtime: Date
  }

  private func inventoryAndEvictIfNeeded() {
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: diskDirectory,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles]
    ) else {
      return
    }

    var sized: [DiskEntry] = []
    var total = 0
    for url in entries {
      let values = try? url.resourceValues(forKeys: Set(keys))
      let size = values?.fileSize ?? 0
      let mtime = values?.contentModificationDate ?? Date.distantPast
      total += size
      sized.append(DiskEntry(url: url, size: size, mtime: mtime))
    }

    if total > diskUsage.budget {
      sized.sort { $0.mtime < $1.mtime }
      for entry in sized {
        do {
          try FileManager.default.removeItem(at: entry.url)
          total = max(0, total - entry.size)
        } catch {
          continue
        }
        if total <= diskUsage.budget {
          break
        }
      }
    }
    diskUsage.recordInventory(totalBytes: total)
  }

  private func diskFileSize(at url: URL) -> Int? {
    try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
  }

  private func diskCost(_ image: NSImage) -> Int {
    let pixels = image.size.width.rounded() * image.size.height.rounded()
    return Int(max(pixels, 0)) * 4
  }
}

/// `NSCache` key for `ThumbnailCache`. `NSCache` requires `Key: NSObject &
/// NSCopying`; a Swift struct won't work, so this class holds the value-type
/// `MaccyFingerprint` by value.
final class ThumbnailCacheKey: NSObject, NSCopying {
  let fingerprint: MaccyFingerprint
  let maxPixelSize: Int

  init(fingerprint: MaccyFingerprint, maxPixelSize: Int) {
    self.fingerprint = fingerprint
    self.maxPixelSize = maxPixelSize
  }

  func copy(with zone: NSZone? = nil) -> Any {
    ThumbnailCacheKey(fingerprint: fingerprint, maxPixelSize: maxPixelSize)
  }

  override var hash: Int {
    var hasher = Hasher()
    hasher.combine(fingerprint)
    hasher.combine(maxPixelSize)
    return hasher.finalize()
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? ThumbnailCacheKey else {
      return false
    }
    return fingerprint == other.fingerprint && maxPixelSize == other.maxPixelSize
  }
}
