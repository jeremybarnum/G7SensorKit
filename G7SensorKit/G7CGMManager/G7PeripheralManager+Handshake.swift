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

    /// The longest wait for the system to take another certificate chunk before sending it anyway.
    /// Chunks go out as fast as the system accepts them, as the Dexcom app sends them (about 25 in
    /// 25 ms, seen 2026-11-25): a fixed pause after every chunk stretched to about 120 ms with the app
    /// in the background and made a pairing take 11 s, past what a watch allows a background app.
    static let certificateChunkInterval: TimeInterval = 0.04

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
    /// sensor expects.
    func writeCertificateBytes(_ data: Data) throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: G7PeripheralManager.certificateChunkSize, limitedBy: data.endIndex)
                ?? data.endIndex
            waitUntilReadyToWriteWithoutResponse(atMost: G7PeripheralManager.certificateChunkInterval)
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
