//
//  G7AuthProvider.swift
//  G7SensorKit
//
//  The seam between the watch acquisition arm and the direct-auth handshake. Nothing about
//  J-PAKE, certificates or OpenSSL crosses this line: G7BluetoothManager names only this protocol
//  and the factory, so the G7Auth sources (and their xcframeworks) can move to their own target
//  later without touching the arm.
//

import Foundation
import CoreBluetooth

/// What the acquisition arm needs from an authenticator.
protocol G7AuthProvider: AnyObject, Sendable {
    /// Inbound notification from the single CB delegate; true = consumed by the handshake.
    func feed(_ uuid: CBUUID, _ value: Data) -> Bool
    /// Run the handshake through to a glucose read. Never throws; the outcome says what happened.
    func authenticate() async -> G7AuthOutcome
    func cancel()
}

struct G7AuthOutcome {
    let authenticated: Bool
    /// The raw 0x4E control notification, forwarded verbatim into the stock parser.
    let egvRaw: [UInt8]?
    let usedFastPath: Bool
    let error: String?
}

enum G7DirectAuthFactory {
    static func make(transport: G7PeripheralManager, auth: CBCharacteristic, data: CBCharacteristic, control: CBCharacteristic,
                     pin4: [UInt8], sensorName: String?, log: @escaping (String) -> Void) -> G7AuthProvider {
        G7DirectAuthSession(peripheralManager: transport, authChar: auth, dataChar: data, ctrlChar: control,
                            pin4: pin4, slotByte: G7DirectAuth.slotByte, sensorName: sensorName, log: log)
    }
}

extension G7DirectAuthSession: G7AuthProvider {
    func authenticate() async -> G7AuthOutcome {
        let r = await run()
        return G7AuthOutcome(authenticated: r.authenticated, egvRaw: r.egvRaw, usedFastPath: usedFastPath, error: r.error)
    }
}
