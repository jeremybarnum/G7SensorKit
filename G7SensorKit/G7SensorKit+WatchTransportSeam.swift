//
//  G7SensorKit+WatchTransportSeam.swift
//  G7SensorKit
//
//  PODLOAN — watch-from-stock M3 ringfence file (DESIGN_FROM_STOCK_REBUILD.md §1.4).
//
//  THE one place stock G7SensorKit is extended for the watch transport-injection seam: the
//  watch app's proven direct-BLE transport (G7Client: J-PAKE handshake + connect-per-reading
//  scheduler) drives the stock G7SensorDelegate flow into G7CGMManager in place of this
//  module's passive CoreBluetooth listener. Anything the external transport needs beyond the
//  already-public G7SensorDelegate surface is granted HERE — never by editing access levels
//  inside stock files.
//
//  Complete out-of-file footprint in this module (audit: grep -rn PODLOAN):
//    - G7CGMManager/G7BluetoothManager.swift — 2 sites, "#if os(iOS)" around CoreBluetooth
//      state restoration (restore-identifier init option; willRestoreState). Unavoidably
//      in-file: both sit inside stock method bodies. iOS compiles byte-identical code.
//  Every other source file in this module is verbatim upstream (base 0c87905).
//
//  Target membership: G7SensorKit-watchOS ONLY. The iOS framework builds from stock sources
//  alone, so its API surface stays exactly upstream's.
//

import Foundation

extension G7Sensor {
    /// PODLOAN transport seam: an external transport must stamp the sensor-clock-derived
    /// activation date before delivering a reading — exactly what the stock passive listener's
    /// `handleGlucoseMessage` computes from `messageTimestamp`. `G7CGMManager.sensor(_:didRead:)`
    /// refuses readings without it and uses it to timestamp samples.
    ///
    /// Concurrency note: stock confines `activationDate` to `bluetoothManager.managerQueue`;
    /// under transport injection the passive listener is idle, so the transport adapter's
    /// serial queue is the only reader/writer.
    public func setActivationDate(_ date: Date?) {
        activationDate = date
    }
}

extension G7GlucoseMessage {
    /// PODLOAN transport seam: an external transport constructs the stock message from a raw
    /// control-characteristic frame (opcode 0x4E). Delegates to the internal `init?(data:)` —
    /// the distinct argument label avoids redeclaring it.
    public init?(transportData: Data) {
        self.init(data: transportData)
    }
}
