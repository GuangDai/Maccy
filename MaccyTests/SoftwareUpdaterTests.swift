import Foundation
import XCTest
@testable import Maccy

@MainActor
final class SoftwareUpdaterTests: XCTestCase {
  func testDisabledUpdaterStartsOnlyWhenNeeded() {
    let defaults = UserDefaults.standard
    let key = "SUEnableAutomaticChecks"
    let savedValue = defaults.object(forKey: key)
    defaults.set(false, forKey: key)
    defer {
      if let savedValue {
        defaults.set(savedValue, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
    }

    var startCalls = 0
    var checkCalls = 0
    let updater = SoftwareUpdater(
      startUpdater: { startCalls += 1 },
      performUpdateCheck: { checkCalls += 1 }
    )

    XCTAssertEqual(startCalls, 0)

    updater.automaticallyChecksForUpdates = true
    XCTAssertEqual(startCalls, 1)

    updater.checkForUpdates()
    XCTAssertEqual(startCalls, 1)
    XCTAssertEqual(checkCalls, 1)
  }
}
