import Foundation
import IOKit.pwr_mgt
import IOKit.ps

@MainActor
final class SleepGuard {
    struct Status {
        let label: String
        let active: Bool
    }

    private var assertionID: IOPMAssertionID = 0
    private var assertionActive = false

    func update(enabled: Bool) -> Status {
        let powerLabel = powerSourceLabel()
        let onAC = powerLabel == "AC"
        if enabled && onAC {
            enableAssertion()
        } else {
            disable()
        }
        return Status(label: powerLabel, active: assertionActive)
    }

    func disable() {
        if assertionActive {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            assertionActive = false
        }
    }

    private func enableAssertion() {
        guard !assertionActive else { return }
        let name = "gobx menubar prevent sleep" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name,
            &assertionID
        )
        assertionActive = (result == kIOReturnSuccess)
    }

    private func powerSourceLabel() -> String {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return "Unknown" }
        let type = IOPSGetProvidingPowerSourceType(snapshot).takeRetainedValue() as String
        if type == kIOPSACPowerValue { return "AC" }
        if type == kIOPSBatteryPowerValue { return "Battery" }
        return "Unknown"
    }

}
