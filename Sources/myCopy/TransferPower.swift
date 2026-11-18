import Foundation
import IOKit.pwr_mgt
import MoverCore

// An app-scoped assertion prevents idle system sleep without changing the
// user's power settings. Display sleep, explicit sleep and shutdown still work.
final class TransferPower {
    var assertion: IOPMAssertionID = 0
    var activity: NSObjectProtocol?

    func start() {
        guard activity == nil else { return }
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "mCopy active transfer and recovery" as CFString, &assertion)
        let options: ProcessInfo.ActivityOptions = result == kIOReturnSuccess ? .userInitiatedAllowingIdleSystemSleep : .userInitiated
        activity = ProcessInfo.processInfo.beginActivity(options: options, reason: "mCopy copying and verifying files")
        if result != kIOReturnSuccess {
            assertion = 0
            NSLog("mCopy: explicit sleep assertion failed (%d); using ProcessInfo sleep prevention.", result)
        }
    }

    func end() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    deinit { end() }

    static func selfTest() throws {
        let power = TransferPower()
        power.start()
        defer { power.end() }
        guard power.assertion != 0,
              let properties = IOPMAssertionCopyProperties(power.assertion)?.takeRetainedValue() as? [String: Any],
              (properties[kIOPMAssertionLevelKey] as? NSNumber)?.intValue == kIOPMAssertionLevelOn else {
            throw TransferError.unavailable("macOS did not confirm mCopy's idle-sleep assertion.")
        }
        let oldID = power.assertion
        power.end()
        guard power.assertion == 0, power.activity == nil,
              IOPMAssertionCopyProperties(oldID) == nil else {
            throw TransferError.unsafe("The test sleep assertion was not released.")
        }
        print("PASS: macOS confirmed the idle-system-sleep assertion; it was released after the test.")
    }
}
