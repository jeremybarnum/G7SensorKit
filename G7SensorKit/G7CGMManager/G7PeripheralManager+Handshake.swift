//
//  G7PeripheralManager+Handshake.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation

/// Characteristic-name-addressed I/O, so the pairing handshake can talk in
/// terms of "the authentication characteristic" rather than resolving
/// `CBCharacteristic` objects at every step.
extension G7PeripheralManager {

    /// The largest payload the sensor accepts in one write on the certificate
    /// characteristic. Fixed at the classic ATT default rather than negotiated:
    /// the sensor reassembles by byte count, and a larger MTU buys nothing.
    static let certificateChunkSize = 20

    func characteristic(_ uuid: CGMServiceCharacteristicUUID) throws -> CBCharacteristic {
        guard let service = peripheral.services?.itemWithUUID(SensorServiceUUID.cgmService.cbUUID) else {
            throw PeripheralManagerError.invalidConfiguration
        }
        guard let characteristic = service.characteristics?.itemWithUUID(uuid.cbUUID) else {
            throw PeripheralManagerError.unknownCharacteristic
        }
        return characteristic
    }

    func writeValue(
        _ value: Data,
        for uuid: CGMServiceCharacteristicUUID,
        type: CBCharacteristicWriteType,
        timeout: TimeInterval = 5
    ) throws {
        try writeValue(value, for: characteristic(uuid), type: type, timeout: timeout)
    }

    /// Streams `data` to the certificate characteristic in the chunk size the
    /// sensor expects, one chunk straight after another, as the Dexcom app
    /// sends them (76 chunks about 1 ms apart, seen 2026-11-25).
    ///
    /// A pause after each chunk (40 ms, which a watch app in the background
    /// stretched to about 130 ms) made a pairing take 11 s, and a watch allows
    /// a background app about 5 s of Bluetooth traffic per connection before
    /// it counts against an allowance that ends in the app's Bluetooth being
    /// cut off. Waiting for the system's "ready to send" callback is no
    /// substitute: it comes only after a write has failed.
    func writeCertificateBytes(_ data: Data) throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: G7PeripheralManager.certificateChunkSize, limitedBy: data.endIndex)
                ?? data.endIndex
            try writeValue(data[offset ..< end], for: .certificate, type: .withoutResponse)
            offset = end
        }
    }

    /// A one-line summary of a characteristic's discovered properties, for the
    /// pairing log. Which properties a sensor actually advertises has varied
    /// across firmware, and it is the first thing worth knowing when a
    /// handshake stalls on a real device.
    func describeCharacteristic(_ uuid: CGMServiceCharacteristicUUID) -> String {
        guard let characteristic = try? characteristic(uuid) else {
            return "\(uuid) not discovered"
        }
        var properties = [String]()
        let flags: [(CBCharacteristicProperties, String)] = [
            (.read, "read"),
            (.write, "write"),
            (.writeWithoutResponse, "writeWithoutResponse"),
            (.notify, "notify"),
            (.indicate, "indicate")
        ]
        for (flag, name) in flags where characteristic.properties.contains(flag) {
            properties.append(name)
        }
        return "\(uuid) [\(properties.joined(separator: ","))] notifying=\(characteristic.isNotifying)"
    }
}
