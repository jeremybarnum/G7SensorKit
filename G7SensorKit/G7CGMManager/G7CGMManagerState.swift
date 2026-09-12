//
//  G7CGMManagerState.swift
//  CGMBLEKit
//
//  Created by Pete Schwamb on 9/26/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit


public struct G7CGMManagerState: RawRepresentable, Equatable {
    public typealias RawValue = CGMManager.RawStateValue

    public var sensorID: String?
    public var activatedAt: Date?
    public var extendedVersion: ExtendedVersionMessage?
    public var latestReading: G7GlucoseMessage?
    public var latestReadingTimestamp: Date?
    public var latestConnect: Date?
    public var uploadReadings: Bool = true

    /// Direct auth (watch reads the sensor with its own J-PAKE, no Dexcom app on the watch):
    /// the per-sensor pairing codes, keyed by sensor name. Entered once per sensor on the phone
    /// (the code is shown in the Dexcom app); they ride to the watch inside the context's
    /// cgmManagerState — the phone's whole state, which it already sends. A code only works with
    /// its own sensor, so old entries are harmless.
    public var directAuthPins: [String: String] = [:]
    /// When the watch's handshake last succeeded with each code — "verified", not just "saved".
    public var directAuthVerifiedAt: [String: Date] = [:]

    init() {
    }

    public init(rawValue: RawValue) {
        self.sensorID = rawValue["sensorID"] as? String
        self.activatedAt = rawValue["activatedAt"] as? Date
        if let readingData = rawValue["latestReading"] as? Data {
            latestReading = G7GlucoseMessage(data: readingData)
        }
        if let extendedVersionData = rawValue["extendedVersion"] as? Data {
            extendedVersion = ExtendedVersionMessage(data: extendedVersionData)
        }
        self.latestReadingTimestamp = rawValue["latestReadingTimestamp"] as? Date
        self.latestConnect = rawValue["latestConnect"] as? Date
        self.uploadReadings = rawValue["uploadReadings"] as? Bool ?? true
        self.directAuthPins = rawValue["directAuthPins"] as? [String: String] ?? [:]
        self.directAuthVerifiedAt = rawValue["directAuthVerifiedAt"] as? [String: Date] ?? [:]
    }

    public var rawValue: RawValue {
        var rawValue: RawValue = [:]
        rawValue["sensorID"] = sensorID
        rawValue["activatedAt"] = activatedAt
        rawValue["latestReading"] = latestReading?.data
        rawValue["extendedVersion"] = extendedVersion?.data
        rawValue["latestReadingTimestamp"] = latestReadingTimestamp
        rawValue["latestConnect"] = latestConnect
        rawValue["uploadReadings"] = uploadReadings
        rawValue["directAuthPins"] = directAuthPins
        rawValue["directAuthVerifiedAt"] = directAuthVerifiedAt
        return rawValue
    }
}
