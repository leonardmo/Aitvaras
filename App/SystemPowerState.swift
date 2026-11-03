import Foundation
import IOKit.ps
import AitvarasAgent

enum SystemPowerState {
    static func current() -> NightlyPowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourceList = IOPSCopyPowerSourcesList(info)?.takeRetainedValue()
                as? [CFTypeRef]
        else {
            return .externallyPowered
        }

        var foundBattery = false
        var connectedToPower = false
        var batteryPercent: Int?

        for source in sourceList {
            guard let description = IOPSGetPowerSourceDescription(info, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            foundBattery = true
            connectedToPower =
                description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int,
               maximum > 0 {
                batteryPercent = Int(
                    (Double(current) / Double(maximum) * 100).rounded())
            }
            break
        }

        // A desktop Mac has no internal battery and is necessarily externally
        // powered. If IOKit reports no battery source, don't block its job.
        return NightlyPowerSnapshot(
            hasBattery: foundBattery,
            isConnectedToPower: foundBattery ? connectedToPower : true,
            batteryPercent: batteryPercent)
    }
}
