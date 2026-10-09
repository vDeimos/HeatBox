// Power.swift: whether the Mac is running on its battery.

import Engine
import Foundation
import IOKit.ps

struct BatteryPower: PowerSource {
    /// True on battery. False on mains power, or when it cannot be told.
    var onBattery: Bool {
        guard let unmanaged = IOPSGetProvidingPowerSourceType(nil) else { return false }
        return (unmanaged.takeUnretainedValue() as String) == kIOPMBatteryPowerKey
    }
}
