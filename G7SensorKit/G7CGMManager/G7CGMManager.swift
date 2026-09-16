//
//  G7CGMManager.swift
//  CGMBLEKit
//
//  Created by Pete Schwamb on 9/24/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopAlgorithm
import LoopKit
import os.log



public protocol G7StateObserver: AnyObject {
    func g7StateDidUpdate(_ state: G7CGMManagerState?)
    func g7ConnectionStatusDidChange()
}

public class G7CGMManager: CGMManager {
    public var inSignalLoss: Bool = false
    
    public var isInoperable: Bool {
        cgmManagerStatus.isInoperable
    }
    
    private let log = OSLog(category: "G7CGMManager")

    /// How long to wait for communication to resume after a suspected session end
    /// before forgetting the sensor and scanning for a new one. BLE handshake
    /// failures are indistinguishable from a stopped session at disconnect time;
    /// readings normally resume on the sensor's next 5-minute connection cycle.
    var suspectedSessionEndGracePeriod: TimeInterval = TimeInterval(minutes: 15)

    public var state: G7CGMManagerState {
        return lockedState.value
    }

    private func setState(_ changes: (_ state: inout G7CGMManagerState) -> Void) -> Void {
        return setStateWithResult(changes)
    }

    @discardableResult
    private func mutateState(_ changes: (_ state: inout G7CGMManagerState) -> Void) -> G7CGMManagerState {
        return setStateWithResult({ (state) -> G7CGMManagerState in
            changes(&state)
            return state
        })
    }

    private func setStateWithResult<ReturnType>(_ changes: (_ state: inout G7CGMManagerState) -> ReturnType) -> ReturnType {
        var oldValue: G7CGMManagerState!
        var returnType: ReturnType!
        let newValue = lockedState.mutate { (state) in
            oldValue = state
            returnType = changes(&state)
        }

        if oldValue != newValue {
            delegate.notify { delegate in
                delegate?.cgmManagerDidUpdateState(self)
                delegate?.cgmManager(self, didUpdate: self.cgmManagerStatus)
            }

            g7StateObservers.forEach { (observer) in
                observer.g7StateDidUpdate(newValue)
            }
        }

        return returnType
    }
    private let lockedState: Locked<G7CGMManagerState>

    private let g7StateObservers = WeakSynchronizedSet<G7StateObserver>()

    public weak var cgmManagerDelegate: CGMManagerDelegate? {
        get {
            return delegate.delegate
        }
        set {
            delegate.delegate = newValue
        }
    }

    public var delegateQueue: DispatchQueue! {
        get {
            return delegate.queue
        }
        set {
            delegate.queue = newValue
        }
    }

    private let delegate = WeakSynchronizedDelegate<CGMManagerDelegate>()

    public var providesBLEHeartbeat: Bool = true

    public var managedDataInterval: TimeInterval? {
        return .hours(3)
    }

    public var shouldSyncToRemoteService: Bool {
        return state.uploadReadings
    }

    public var glucoseDisplay: GlucoseDisplayable? {
        return latestReading
    }

    public var isScanning: Bool {
        return sensor.isScanning
    }

    public var isConnected: Bool {
        return sensor.isConnected
    }

    public var sensorName: String? {
        return state.sensorID
    }

    public var sensorActivatedAt: Date? {
        return state.activatedAt
    }

    public var lifetime: TimeInterval {
        if let sessionLength = state.extendedVersion?.sessionLength {
            return sessionLength - G7Sensor.gracePeriod
        } else {
            return G7Sensor.defaultLifetime
        }
    }

    public var warmupDuration: TimeInterval {
        state.extendedVersion?.warmupDuration ?? G7Sensor.defaultWarmupDuration
    }

    public var sensorExpiresAt: Date? {
        guard let activatedAt = sensorActivatedAt else {
            return nil
        }
        return activatedAt.addingTimeInterval(lifetime)
    }

    public var sensorEndsAt: Date? {
        guard let activatedAt = sensorActivatedAt else {
            return nil
        }
        return activatedAt.addingTimeInterval(lifetime + G7Sensor.gracePeriod)
    }


    public var sensorFinishesWarmupAt: Date? {
        guard let activatedAt = sensorActivatedAt else {
            return nil
        }
        return activatedAt.addingTimeInterval(warmupDuration)
    }

    public var latestReading: G7GlucoseMessage? {
        return state.latestReading
    }

    public var lastConnect: Date? {
        return state.latestConnect
    }

    public var latestReadingTimestamp: Date? {
        return state.latestReadingTimestamp
    }

    public var uploadReadings: Bool {
        get {
            return state.uploadReadings
        }
        set {
            mutateState { state in
                state.uploadReadings = newValue
            }
        }
    }

    public let sensor: G7Sensor

    public var cgmManagerStatus: LoopKit.CGMManagerStatus {
        return CGMManagerStatus(hasValidSensorSession: true, device: device)
    }

    public var lifecycleState: G7SensorLifecycleState {
        if state.sensorID == nil {
            return .searching
        }
        if let sensorEndsAt = sensorEndsAt, sensorEndsAt.timeIntervalSinceNow < 0 {
            return .expired
        }
        if let algorithmState = latestReading?.algorithmState {
            if algorithmState.isInWarmup {
                return .warmup
            }
            if algorithmState.sensorFailed {
                return .failed
            }
        }
        if let sensorExpiresAt = sensorExpiresAt, sensorExpiresAt.timeIntervalSinceNow < 0 {
            return .gracePeriod
        }
        return .ok
    }


    public func fetchNewDataIfNeeded(_ completion: @escaping (LoopKit.CGMReadingResult) -> Void) {
        sensor.resumeScanning()
        completion(.noData)
    }

    public convenience init() {
        self.init(state: G7CGMManagerState(), sensor: G7Sensor(sensorID: nil))
    }

    public required convenience init?(rawState: RawStateValue) {
        let state = G7CGMManagerState(rawValue: rawState)
        self.init(state: state, sensor: G7Sensor(sensorID: state.sensorID))
        sensor.needsVersionInfo = state.extendedVersion == nil
    }

    /// Hand the per-sensor pairing codes to the BLE layer (G7DirectAuth reads a UserDefaults
    /// mirror because it has no reference to this manager).
    private func installDirectAuthPins() {
#if os(watchOS)
        G7DirectAuth.pins = state.directAuthPins
        if let needs = G7DirectAuth.needsCodeFor, state.directAuthPins[needs] != nil {
            G7DirectAuth.needsCodeFor = nil
        }
#endif
    }

    init(state: G7CGMManagerState, sensor: G7Sensor) {
        lockedState = Locked(state)
        self.sensor = sensor
        sensor.delegate = self
        // A grace period may have been in flight when the app was last terminated.
        restorePendingSuspectedSessionEnd()
        installDirectAuthPins()
    }

    public var rawState: RawStateValue {
        return state.rawValue
    }

    public var debugDescription: String {
        let lines = [
            "## G7CGMManager",
            "sensorID: \(String(describing: state.sensorID))",
            "activatedAt: \(String(describing: state.activatedAt))",
            "latestReading: \(String(describing: state.latestReading))",
            "latestReadingTimestamp: \(String(describing: state.latestReadingTimestamp))",
            "latestConnect: \(String(describing: state.latestConnect))",
            "uploadReadings: \(String(describing: state.uploadReadings))",
        ]
        return lines.joined(separator: "\n")
    }

    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier) async throws { }

    public func getSoundBaseURL() -> URL? { return nil }
    public func getSounds() -> [Alert.Sound] { return [] }

    public let pluginIdentifier: String = "G7CGMManager"

    public let localizedTitle = LocalizedString("Dexcom G7", comment: "CGM display title")

    public let isOnboarded = true   // No distinction between created and onboarded

    public var appURL: URL? {
        return nil
    }

    /// The user's "Reconnect sensor": drop the link or the lodged request and run one bootstrap
    /// pass for the SAME sensor, keeping its identity; see `G7BluetoothManager.reconnect`.
#if os(watchOS)
    public func reconnectG7() { sensor.reconnect() }
#endif

    // MARK: - Direct auth pairing codes (entered once per sensor on the phone; ride to the watch
    // inside the context's cgmManagerState, which the phone already sends every update)

    public enum DirectAuthCodeStatus: Equatable {
        case noSensor
        case needsCode
        case saved
        case verified(Date)
    }

    /// The current sensor's code state, for the settings row.
    public var directAuthCodeStatus: DirectAuthCodeStatus {
        guard let id = state.sensorID else { return .noSensor }
        guard state.directAuthPins[id] != nil else { return .needsCode }
        if let at = state.directAuthVerifiedAt[id] { return .verified(at) }
        return .saved
    }

    /// The user entered this sensor's pairing code (phone). Stored per sensor; "verified" only
    /// once the watch's handshake succeeds with it. Returns false if it is not 4 digits.
    @discardableResult
    public func setDirectAuthPin(_ code: String, for sensorName: String) -> Bool {
        let digits = String(code.filter { $0.isNumber }.prefix(4))
        guard digits.count == 4 else { return false }
        mutateState { state in
            state.directAuthPins[sensorName] = digits
            state.directAuthVerifiedAt[sensorName] = nil
        }
#if os(watchOS)
        G7DirectAuth.pins = state.directAuthPins
        if G7DirectAuth.needsCodeFor == sensorName { G7DirectAuth.needsCodeFor = nil }
#endif
        logDeviceCommunication("direct-auth: pairing code saved for \(sensorName)", type: .connection)
        return true
    }

    /// WATCH: the phone's cgmManagerState arrived in a context. Take its codes (the phone is
    /// where they are entered), and if the phone has moved to a NEW sensor we have a code for,
    /// adopt it by identity and go find it — no scan of our own is ever needed to notice a
    /// sensor change.
    public func receiveDirectAuthPins(_ pins: [String: String], phoneSensorID: String?) {
#if os(watchOS)
        guard !pins.isEmpty else { return }
        let before = state
        mutateState { state in
            for (name, code) in pins { state.directAuthPins[name] = code }
        }
        G7DirectAuth.pins = state.directAuthPins
        if let needs = G7DirectAuth.needsCodeFor, state.directAuthPins[needs] != nil {
            G7DirectAuth.needsCodeFor = nil
        }
        if let new = phoneSensorID, new != before.sensorID, state.directAuthPins[new] != nil {
            logDeviceCommunication("direct-auth: phone reports sensor \(new) (was \(before.sensorID ?? "none")) and we hold its code — adopting and re-acquiring", type: .connection)
            mutateState { state in
                state.sensorID = new
                state.activatedAt = nil
                state.extendedVersion = nil
            }
            sensor.adopt(sensorID: new)
            sensor.needsVersionInfo = true
            sensor.reacquireForNewSensor()
        } else if state.directAuthPins != before.directAuthPins {
            logDeviceCommunication("direct-auth: pairing codes updated from the phone (\(state.directAuthPins.count) sensor(s))", type: .connection)
            // A code for the CURRENT sensor may have just arrived: the arm stood down without
            // one ("not lodging"), and this is what re-arms it.
            sensor.resumeScanning()
        }
#endif
    }

    public func scanForNewSensor() {
        cancelSuspectedSessionEndScan()

        logDeviceCommunication("Forgetting existing sensor and starting scan for new sensor.", type: .connection)

        mutateState { state in
            state.sensorID = nil
            state.activatedAt = nil
            state.extendedVersion = nil
        }
        sensor.scanForNewSensor()
    }

    private var device: HKDevice? {
        return HKDevice(
            name: state.sensorID ?? "Unknown",
            manufacturer: "Dexcom",
            model: "G7",
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: "CGMBLEKit" + String(G7SensorKitVersionNumber),
            localIdentifier: nil,
            udiDeviceIdentifier: "00386270001863"
        )
    }

    func logDeviceCommunication(_ message: String, type: DeviceLogEntryType = .send) {
        self.cgmManagerDelegate?.deviceManager(self, logEventForDeviceIdentifier: state.sensorID, type: type, message: message, completion: nil)
    }

    private func updateDelegate(with result: CGMReadingResult) {
        delegateQueue?.async {
            self.cgmManagerDelegate?.cgmManager(self, hasNew: result)
        }
    }
}

extension G7CGMManager {
    // MARK: - G7StateObserver

    public func addStateObserver(_ observer: G7StateObserver, queue: DispatchQueue) {
        g7StateObservers.insert(observer, queue: queue)
    }

    public func removeStateObserver(_ observer: G7StateObserver) {
        g7StateObservers.removeElement(observer)
    }
}

extension G7CGMManager: G7SensorDelegate {
    public func sensor(_ sensor: G7Sensor, didDiscoverNewSensor name: String, activatedAt: Date) -> Bool {
        logDeviceCommunication("New sensor \(name) discovered, activated at \(activatedAt)", type: .connection)

        let shouldSwitchToNewSensor = true

        if shouldSwitchToNewSensor {
            mutateState { state in
                state.sensorID = name
                state.activatedAt = activatedAt
            }
            let event = PersistedCgmEvent(
                date: activatedAt,
                type: .sensorStart,
                deviceIdentifier: name,
                expectedLifetime: lifetime + G7Sensor.gracePeriod,
                warmupPeriod: warmupDuration
            )
            delegate.notify { delegate in
                delegate?.cgmManager(self, hasNew: [event])
            }

            #if !os(watchOS)
            // Direct auth in use (a code has been entered before) and none for this sensor yet:
            // ask now, while the phone is in hand. This alert is a convenience, not the state —
            // the settings row and the watch glance keep saying "needs code" until one exists.
            if !state.directAuthPins.isEmpty, state.directAuthPins[name] == nil {
                let content = Alert.Content(
                    title: "New sensor \(name)",
                    body: "Enter its pairing code in Loop ▸ Dexcom G7 so the watch can read it without your phone. The code is shown in the Dexcom app.",
                    acknowledgeActionButtonLabel: "OK")
                let alert = Alert(identifier: Alert.Identifier(managerIdentifier: pluginIdentifier, alertIdentifier: "directAuth.codeNeeded"),
                                  foregroundContent: content, backgroundContent: content, trigger: .immediate)
                delegate.notify { delegate in
                    Task { await delegate?.issueAlert(alert) }
                }
            }
            #endif
        }

        return shouldSwitchToNewSensor
    }

    public func sensor(_ sensor: G7Sensor, directAuthVerified sensorName: String) {
        mutateState { $0.directAuthVerifiedAt[sensorName] = Date() }
        logDeviceCommunication("direct-auth: pairing code VERIFIED for \(sensorName)", type: .connection)
    }

    /// The watch acquisition arm's log line, into the host's device log (Pete's
    /// omnipodLogDeviceEvent shape). Nothing produces it on the phone.
    public func sensor(_ sensor: G7Sensor, logEvent line: String) {
        logDeviceCommunication("[g7-watch] " + line, type: .connection)
    }

    public func sensor(_ sensor: G7Sensor, didReceive extendedVersion: ExtendedVersionMessage) {
        mutateState { state in
            state.extendedVersion = extendedVersion
        }
    }

    public func sensorDidConnect(_ sensor: G7Sensor, name: String) {
        mutateState { state in
            state.latestConnect = Date()
        }
        logDeviceCommunication("Sensor connected", type: .connection)
    }

    public func sensorDisconnected(_ sensor: G7Sensor, suspectedEndOfSession: Bool) {
        logDeviceCommunication("Sensor disconnected: suspectedEndOfSession=\(suspectedEndOfSession)", type: .connection)
        guard suspectedEndOfSession else { return }
#if os(watchOS)
        // Loop's own handshake: the sensor closing before auth is a failed handshake, not a
        // session end — a replacement sensor arrives by identity from the phone
        // (receiveDirectAuthPins). Riding the Dexcom watch app (authentication OFF, ride-only):
        // a join the sensor closes before Dexcom's auth completes is routine too, and stock's
        // forget-and-scan here put our scan into the sensor's tail (mute record §3k). Either way
        // the adoption is kept.
        let keep = G7DirectAuth.enabled
            || !G7RidePolicy.shouldForgetOnBareDisconnect(rideOnly: !G7DirectAuth.enabled, adopted: state.sensorID != nil)
        if keep {
            logDeviceCommunication("disconnect before auth — KEEPING \(state.sensorID ?? "sensor") (no forget, no scan)", type: .connection)
        } else {
            scheduleScanAfterSuspectedSessionEnd()
        }
#else
        scheduleScanAfterSuspectedSessionEnd()
#endif
    }

    /// A disconnect before authentication usually means the session was stopped,
    /// but the same signature occurs on transient BLE handshake failures, where
    /// forgetting the sensor immediately causes a long re-discovery outage.
    /// Instead, keep tracking the current sensor and only scan for a new one if
    /// communication does not resume within the grace period.
    private func scheduleScanAfterSuspectedSessionEnd() {
        // `suspectedSessionEndAt` is the single record of a live grace period: it
        // says whether one is running, identifies it, and survives termination.
        guard state.suspectedSessionEndAt == nil else {
            logDeviceCommunication("Suspected session end during active grace period; original deadline unchanged.", type: .connection)
            return
        }

        let graceStart = Date()
        mutateState { state in
            state.suspectedSessionEndAt = graceStart
        }

        logDeviceCommunication("Suspected session end; waiting \(suspectedSessionEndGracePeriod.minutes) minutes for communication to resume before scanning for new sensor.", type: .connection)
        scheduleGraceExpiry(graceStart: graceStart, after: suspectedSessionEndGracePeriod)
    }

    private func scheduleGraceExpiry(graceStart: Date, after delay: TimeInterval) {
        // Wall-clock deadline: a mach-time deadline pauses while the device
        // sleeps, which could postpone detection of a genuinely ended session.
        // Not cancellable, and does not need to be -- the expiry re-reads
        // `suspectedSessionEndAt` and no-ops unless it still owns the window.
        DispatchQueue.global(qos: .utility).asyncAfter(wallDeadline: .now() + delay) { [weak self] in
            self?.handleSuspectedSessionEndGraceExpiry(graceStart: graceStart)
        }
    }

    func handleSuspectedSessionEndGraceExpiry(graceStart: Date) {
        // Cleared by resumed communication, or replaced by a later grace period.
        guard state.suspectedSessionEndAt == graceStart else {
            logDeviceCommunication("Communication received during suspected session end grace period; keeping sensor.", type: .connection)
            return
        }

        logDeviceCommunication("No sensor communication since suspected session end.", type: .connection)
        scanForNewSensor()
    }

    /// Clearing the marker is the cancellation: a pending expiry finds a grace
    /// start that is no longer current and does nothing.
    private func cancelSuspectedSessionEndScan() {
        // Guarded because this runs on every glucose and backfill message, and
        // mutateState notifies observers and persists.
        guard state.suspectedSessionEndAt != nil else { return }
        mutateState { state in
            state.suspectedSessionEndAt = nil
        }
    }

    /// Re-establish a grace period that was in flight when the app was last
    /// terminated. The expiry is dispatched in memory and does not survive, so
    /// without this a genuinely ended session would be tracked forever -- the
    /// sensor never advertises again and nothing re-arms the scan.
    private func restorePendingSuspectedSessionEnd() {
        guard let graceStart = state.suspectedSessionEndAt else { return }

        // Normally resumed communication has already cleared the marker. This
        // covers the case where that clear was not persisted before we exited.
        if let latestReadingTimestamp = state.latestReadingTimestamp, latestReadingTimestamp > graceStart {
            cancelSuspectedSessionEndScan()
            return
        }

        let remaining = graceStart.addingTimeInterval(suspectedSessionEndGracePeriod).timeIntervalSinceNow
        guard remaining > 0 else {
            // The window elapsed while we were not running, with nothing heard since.
            logDeviceCommunication("Grace period for suspected session end expired while app was not running.", type: .connection)
            scanForNewSensor()
            return
        }

        logDeviceCommunication("Resuming suspected session end grace period; \(Int(remaining / 60)) minutes remaining.", type: .connection)
        scheduleGraceExpiry(graceStart: graceStart, after: remaining)
    }

    public func sensor(_ sensor: G7Sensor, logComms comms: String) {
        logDeviceCommunication("Sensor comms \(comms)", type: .receive)
    }


    public func sensor(_ sensor: G7Sensor, didError error: Error) {
        logDeviceCommunication("Sensor error \(error)", type: .error)
    }

    public func sensor(_ sensor: G7Sensor, didRead message: G7GlucoseMessage) {

        // Receiving any glucose message proves the session is still active.
        cancelSuspectedSessionEndScan()

        guard message != latestReading else {
            logDeviceCommunication("Sensor reading duplicate: \(message)", type: .error)
            updateDelegate(with: .noData)
            return
        }

        if message.algorithmState.sensorFailed {
            logDeviceCommunication("Detected failed sensor... scanning for new sensor.", type: .receive)
            scanForNewSensor()
        }

        if message.algorithmState == .known(.sessionEnded) {
            logDeviceCommunication("Detected session ended... scanning for new sensor.", type: .receive)
            scanForNewSensor()
        }


        guard let activationDate = sensor.activationDate else {
            logDeviceCommunication("Unable to process sensor reading without activation date.", type: .error)
            return
        }

        logDeviceCommunication("Sensor didRead \(message)", type: .receive)

        let latestReadingTimestamp = activationDate.addingTimeInterval(TimeInterval(message.glucoseTimestamp))

        mutateState { state in
            state.latestReading = message
            state.latestReadingTimestamp = latestReadingTimestamp
        }

        guard let glucose = message.glucose else {
            updateDelegate(with: .noData)
            return
        }

        guard message.hasReliableGlucose else {
            updateDelegate(with: .error(AlgorithmError.unreliableState(message.algorithmState)))
            return
        }

        let unit = LoopUnit.milligramsPerDeciliter
        let quantity = LoopQuantity(unit: unit, doubleValue: Double(min(max(glucose, GlucoseLimits.minimum), GlucoseLimits.maximum)))

        updateDelegate(with: .newData([
            NewGlucoseSample(
                date: latestReadingTimestamp,
                quantity: quantity,
                condition: message.condition,
                trend: message.trendType,
                trendRate: message.trendRate,
                isDisplayOnly: message.glucoseIsDisplayOnly,
                wasUserEntered: message.glucoseIsDisplayOnly,
                syncIdentifier: generateSyncIdentifier(timestamp: message.glucoseTimestamp),
                device: device
            )
        ]))
    }

    private func generateSyncIdentifier(timestamp: UInt32) -> String {
        guard let activatedAt = state.activatedAt, let sensorID = state.sensorID else {
            return "invalid"
        }

        return "\(activatedAt.timeIntervalSince1970.hours) \(sensorID) \(timestamp)"
    }

    public func sensor(_ sensor: G7Sensor, didReadBackfill backfill: [G7BackfillMessage]) {
        // Backfill likewise proves the session is still active.
        cancelSuspectedSessionEndScan()

        for msg in backfill {
            logDeviceCommunication("Sensor didReadBackfill \(msg)", type: .receive)
        }

        guard let activationDate = sensor.activationDate else {
            log.error("Unable to process backfill without activation date.")
            return
        }

        let unit = LoopUnit.milligramsPerDeciliter

        let samples = backfill.compactMap { entry -> NewGlucoseSample? in
            guard let glucose = entry.glucose else {
                return nil
            }

            guard entry.hasReliableGlucose else {
                logDeviceCommunication("Backfill reading unreliable: \(entry)", type: .receive)
                return nil
            }

            let quantity = LoopQuantity(unit: unit, doubleValue: Double(min(max(glucose, GlucoseLimits.minimum), GlucoseLimits.maximum)))

            return NewGlucoseSample(
                date: activationDate.addingTimeInterval(TimeInterval(entry.timestamp)),
                quantity: quantity,
                condition: entry.condition,
                trend: entry.trendType,
                trendRate: entry.trendRate,
                isDisplayOnly: entry.glucoseIsDisplayOnly,
                wasUserEntered: entry.glucoseIsDisplayOnly,
                syncIdentifier: generateSyncIdentifier(timestamp: entry.timestamp),
                device: device
            )
        }

        updateDelegate(with: .newData(samples))
    }

    public func sensorConnectionStatusDidUpdate(_ sensor: G7Sensor) {
        g7StateObservers.forEach { (observer) in
            observer.g7ConnectionStatusDidChange()
        }
    }
}

extension G7BackfillMessage {
    public var trendRate: LoopQuantity? {
        guard let trend = trend else {
            return nil
        }
        return LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: trend)
    }
}

extension G7GlucoseMessage: GlucoseDisplayable {
    public var isStateValid: Bool {
        return hasReliableGlucose
    }

    public var trendRate: LoopQuantity? {
        guard let trend = trend else {
            return nil
        }
        return LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: trend)
    }

    public var glucoseQuantity: LoopQuantity? {
        guard let glucose = glucose else {
            return nil
        }
        return LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(glucose))
    }

    public var isLocal: Bool {
        return true
    }

    public var glucoseRangeCategory: LoopKit.GlucoseRangeCategory? {
        guard let glucose = glucose else {
            return nil
        }

        if glucose < GlucoseLimits.minimum {
            return .belowRange
        } else if glucose > GlucoseLimits.maximum {
            return .aboveRange
        } else {
            return nil
        }
    }
}
