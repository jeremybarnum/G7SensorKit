//
//  G7BluetoothManager.swift
//  CGMBLEKit
//
//  Created by Pete Schwamb on 11/11/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import CoreBluetooth

/// FORK ADDITION (Sport Mode #101): public sink for the radio census, since the BLE types
/// themselves are module-internal. The watch app assigns it; nil (default) = os_log only.
///
/// #101 phase 2 additionally publishes two lock-protected timestamps so the app can gate
/// pod radio work on live G7 acquisition state (2026-08-10 23:31:48: the pod scan fired
/// 100ms before the D2W ride appeared and the G7 connect never completed — the app needs
/// to SEE an in-flight connect / fresh ride activity, not infer it from the clock):
/// - `connectPendingSince`: a `centralManager.connect` we issued that has neither
///   didConnect nor didFailToConnect'd yet. The fragile establishment phase.
/// - `lastRideSignalAt`: most recent acquisition signal of any kind (connection event,
///   sensor advertisement, connect issued/landed). "Fresh signal" means a ride is in
///   progress or imminent; silence means the radio is ours to use.
public enum G7RadioCensus {
    public static var sink: ((String) -> Void)?

    /// Every sensor NAME this radio sees, as a signal rather than as prose.
    ///
    /// The census already logged these names, but only inside sentences — recovering "which
    /// sensors are actually in range" meant parsing log strings. The host needs it as data to
    /// break the stranded-identity trap: when the persisted sensor is gone and a replacement is
    /// advertising beside it, nothing in the manager can notice, because it is busy failing
    /// authentication against a corpse and therefore never learns the new sensor's ID.
    /// (Ported from the pure/SportMode line, 2026-08-21.)
    public static var sensorSighted: ((String) -> Void)?

    /// Tail-exposure instrument (mute record §5, 2026-09-06): the adopted sensor's link just
    /// closed — the start of its advertising tail — and our own acquisition scan just started.
    /// The watch app logs what of ours was on the radio in the 40 s after each close, one line
    /// per window, because bluetoothd never tells an app about the failed establishment that
    /// writes the −70 dBm floor; the exposure is the half we can see. Called on CoreBluetooth's
    /// queue.
    public static var sensorClosed: ((String) -> Void)?
    public static var scanStarted: (() -> Void)?

    private static let stateLock = NSLock()
    private static var _connectPendingSince: Date?
    private static var _lastRideSignalAt: Date?

    public static var connectPendingSince: Date? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _connectPendingSince
    }
    public static var lastRideSignalAt: Date? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _lastRideSignalAt
    }

    static func noteConnectPending() {
        stateLock.lock(); defer { stateLock.unlock() }
        if _connectPendingSince == nil { _connectPendingSince = Date() }
        _lastRideSignalAt = Date()
    }
    static func noteConnectResolved() {
        stateLock.lock(); defer { stateLock.unlock() }
        _connectPendingSince = nil
        _lastRideSignalAt = Date()
    }
    static func noteRideSignal() {
        stateLock.lock(); defer { stateLock.unlock() }
        _lastRideSignalAt = Date()
    }
}
import Foundation
import os.log


enum PeripheralConnectionCommand {
    case connect
    case makeActive
    case ignore
}

protocol G7BluetoothManagerDelegate: AnyObject {

    /**
     Tells the delegate that the bluetooth manager has finished connecting to and discovering all required services of its peripheral

     - parameter manager: The bluetooth manager
     - parameter peripheralManager: The peripheral manager
     - parameter error:   An error describing why bluetooth setup failed

     - returns: True if scanning should stop
     */
    func bluetoothManager(_ manager: G7BluetoothManager, readied peripheralManager: G7PeripheralManager) -> Bool

    /**
     Tells the delegate that the bluetooth manager encountered an error while connecting to and discovering required services of a peripheral

     - parameter manager: The bluetooth manager
     - parameter peripheralManager: The peripheral manager
     - parameter error:   An error describing why bluetooth setup failed
     */
    func bluetoothManager(_ manager: G7BluetoothManager, readyingFailed peripheralManager: G7PeripheralManager, with error: Error)

    /// Our own J-PAKE handshake (G7DirectAuthSession) authenticated the link. The stock auth
    /// observer never sees that exchange, so this clears its pending-auth state before the
    /// sensor's routine hang-up would otherwise be misread as end-of-session.
    func bluetoothManager(_ manager: G7BluetoothManager, directAuthDidAuthenticate peripheralManager: G7PeripheralManager)

    /**
     Asks the delegate if the discovered or restored peripheral is active or should be connected to

     - parameter manager:    The bluetooth manager
     - parameter peripheral: The found peripheral

     - returns: PeripheralConnectionCommand indicating what should be done with this peripheral
     */
    func bluetoothManager(_ manager: G7BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral) -> PeripheralConnectionCommand

    /// Informs the delegate that the bluetooth manager received new data in the control characteristic
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    ///   - peripheralManager: The peripheral manager
    ///   - response: The data received on the control characteristic
    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReceiveControlResponse response: Data)

    /// Informs the delegate that the bluetooth manager received new data in the backfill characteristic
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    ///   - response: The data received on the backfill characteristic
    func bluetoothManager(_ manager: G7BluetoothManager, didReceiveBackfillResponse response: Data)

    /// Informs the delegate that the bluetooth manager received new data in the authentication characteristic
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    ///   - peripheralManager: The peripheral manager
    ///   - response: The data received on the authentication characteristic
    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReceiveAuthenticationResponse response: Data)

    /// Informs the delegate that the bluetooth manager started or stopped scanning
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    func bluetoothManagerScanningStatusDidChange(_ manager: G7BluetoothManager)

    /// Informs the delegate that a peripheral disconnected
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    func peripheralDidDisconnect(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, wasRemoteDisconnect: Bool)
}


extension G7BluetoothManagerDelegate {
    /// Optional: only the stock sensor observer needs to react to a direct-auth success.
    func bluetoothManager(_ manager: G7BluetoothManager, directAuthDidAuthenticate peripheralManager: G7PeripheralManager) {}
}

class G7BluetoothManager: NSObject {

    weak var delegate: G7BluetoothManagerDelegate?

    private let log = OSLog(category: "G7BluetoothManager")

    /// Isolated to `managerQueue`
    private var centralManager: CBCentralManager! = nil

    /// Isolated to `managerQueue`
    private var activePeripheral: CBPeripheral? {
        get {
            return activePeripheralManager?.peripheral
        }
    }

    /// Isolated to `managerQueue`
    private var managedPeripherals: [UUID:G7PeripheralManager] = [:]

    // RE-SETTLED 2026-09-08 (mute record §3d–§5, six watch sysdiagnoses on her line). The
    // 2026-08-25 settlement kept all three doorways (retrieve+connect, connection events, scan)
    // open at once. That is the configuration her record measured feeding bluetoothd's
    // per-device signal-quality tally fastest (§3e: stock re-arm + scan, 0→5 in 12 min sitting
    // still): our pending connect plus our scan on the chip during the sensor's post-read tail
    // is what turns a failed establishment into the −70 dBm floor that mutes every app on the
    // bond for 20–45 min. The 20–40 minute outages the August scan fix cured carry that wedge's
    // exact signature, and the scan "worked" because a direct connect from an active-scan hit
    // bypasses the parked floor (§3k) — an accidental heal for a wedge it helped cause.
    //
    // On watchOS the doorways are now RIDE-ONLY (G7RidePolicy): no connect request of ours and
    // no scan while a sensor is adopted; register for connection events and JOIN Dexcom's link
    // when the OS reports it up. Un-adopted acquisition also never scans — adoption from the
    // air via the connection-event registration is proven (§3k 16:16:40). The phone keeps stock
    // acquisition: the mute is a watch-daemon phenomenon and the phone was never in the arms.
    static var rideOnly: Bool { G7RidePolicy.rideOnlyEnabled }

    // SCAN WATCHDOG (H14 probe + remedy, 2026-08-20). The night of 08-19 the known-sensor branch sat in
    // a bare pending connect for 37 minutes while the sensor advertised on grid (Mac observer). Whatever
    // the root cause (H14: a scan session dead at the bluetoothd level while isScanning reads true), a
    // full recycle of the acquisition is correct under every theory. 320 s = one full sensor window plus
    // jitter: a whole window with acquisition armed and NOTHING delivered is deafness, not bad luck.
    private var scanWatchdog: DispatchSourceTimer?
    private var lastDeliveryAt: Date?

    // MARK: - Timed, bounded connect state (see G7TimedConnect)
    private var timedFireTimer: DispatchSourceTimer?
    private var timedCancelTimer: DispatchSourceTimer?
    private var timedIssuedAt: Date?

    // MARK: - Direct auth (our own J-PAKE; see G7DirectAuthSession)
    private var directAuthSession: G7DirectAuthSession?
    /// Under timed connect there is one shot per grid cycle, so a handshake that dies (dropped
    /// chunk, early hang-up) would cost the whole reading. Allow ONE same-burst retry per cycle:
    /// the sensor keeps advertising after it hangs up, so a bounded connect ~1.5 s later lands.
    /// Reset when a normal grid fire happens, never by the retry itself (no loop).
    private var timedRetryUsedThisCycle = false
    /// A failed handshake asked for the retry while its link was still up (AES failure: the sensor
    /// closes ~3 s later). didDisconnect consumes this and schedules the retry from the real close.
    private var timedRetryPending = false
    /// When the direct-auth link came up — to measure how long a failed link ran.
    private var directAuthLinkStartedAt: Date?
    /// CUSHION (2026-09-12). The mute-feeding failure needs a request parked past the daemon's 6-s
    /// fast scan AND the sensor's post-read wind-down (measured failure zone close+11…+16 s).
    /// The retry is issued at close+1.5 s (observed-good) with a 4-s bound — withdrawn by
    /// close+5.5 s, half the distance to the earliest measured trouble, and 2 s under the 6-s
    /// rule — and only after an EARLY failure: if the failed link itself ran past the cap the
    /// sensor is already deep in its cycle, so take the loss and wait for the grid.
    private static let timedRetryDelay: TimeInterval = 1.5
    private static let timedRetryBound: TimeInterval = 4
    private static let timedRetryLinkCap: TimeInterval = 10

    /// Consecutive fires without a didConnect. At `timedMissLimit` the anchor is presumed stale
    /// and ONE normal scan+connect pass runs to re-anchor (logged loudly — it contaminates that cycle).
    private var timedMisses = 0
    private static let timedMissLimit = 3
    private var timedReacquirePass = false
    private var timedReacquireTimer: DispatchSourceTimer?
    /// Persisted so the grid survives a relaunch; re-anchored on every didConnect.
    private var timedAnchor: Date? {
        get { (UserDefaults.standard.object(forKey: G7TimedConnect.anchorKey) as? Double).map { Date(timeIntervalSince1970: $0) } }
        set {
            if let d = newValue { UserDefaults.standard.set(d.timeIntervalSince1970, forKey: G7TimedConnect.anchorKey) }
            else { UserDefaults.standard.removeObject(forKey: G7TimedConnect.anchorKey) }
        }
    }
    private static let timedClock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.S"; return f }()

    private func armScanWatchdog() {
        scanWatchdog?.cancel()
        if lastDeliveryAt == nil { lastDeliveryAt = Date() }   // baseline, so the first check is not "∞"
        let t = DispatchSource.makeTimerSource(queue: managerQueue)
        t.schedule(deadline: .now() + 320, repeating: 320)
        t.setEventHandler { [weak self] in self?.scanWatchdogFired() }
        t.resume()
        scanWatchdog = t
    }

    private func scanWatchdogFired() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard !G7TimedConnect.enabled else { return }   // timed mode owns the radio; no recycle
        guard activePeripheral?.state != .connected else { return }
        let age = lastDeliveryAt.map { Int(-$0.timeIntervalSinceNow) }
        guard (age ?? Int.max) > 315 else { return }
        Self.census("scan-watchdog: NOTHING delivered in \(age.map(String.init) ?? "∞")s with acquisition armed — recycling scan + connect (H14 probe)")
        if let p = activePeripheral, p.state == .connecting {
            centralManager.cancelPeripheralConnection(p)
        }
        managerQueue_stopScanning()
        managerQueue_scanForPeripheral()
    }

    // MARK: - Timed, bounded connect

    /// Public entry (off the manager queue). ON: drop any scan or standing request and arm the
    /// grid timer. OFF: tear the timers down and return to the normal posture.
    func setTimedConnect(_ on: Bool, seedAnchor: Date?) {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))
        UserDefaults.standard.set(on, forKey: G7TimedConnect.key)
        managerQueue.sync {
            if on {
                // Always reseed from the FRESHEST thing we know. A stale anchor is fatal: the
                // sensor drifts ~0.4 s/cycle, so an anchor hours old puts the burst outside the
                // 5-s bound and every fire misses. OFF→ON must therefore reseed, not keep.
                let candidates: [(String, Date)] = [("the last reading", seedAnchor), ("last delivery", lastDeliveryAt), ("the previous anchor", timedAnchor)].compactMap { n, d in d.map { (n, $0) } }
                let (label, seed) = candidates.max(by: { $0.1 < $1.1 }) ?? ("NOW — nothing known, first cycle is a guess", Date())
                timedAnchor = seed
                timedMisses = 0
                Self.census(String(format: "timed: anchor SEEDED at %@ from %@ (%.0f s old)", Self.timedClock.string(from: seed), label, Date().timeIntervalSince(seed)))
                if centralManager.isScanning {
                    centralManager.stopScan()
                    delegate?.bluetoothManagerScanningStatusDidChange(self)
                }
                if let p = activePeripheral, p.state == .connecting {
                    centralManager.cancelPeripheralConnection(p)
                    G7RadioCensus.noteConnectResolved()
                    Self.census("timed: ON — withdrew the standing request that was pending")
                }
                managerQueue_armTimedConnect()
            } else {
                managerQueue_tearDownTimed()
            }
        }
        if !on { scanForPeripheral() }
    }

    private func managerQueue_tearDownTimed() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        timedFireTimer?.cancel(); timedFireTimer = nil
        timedCancelTimer?.cancel(); timedCancelTimer = nil
        timedIssuedAt = nil
        timedReacquireTimer?.cancel(); timedReacquireTimer = nil
        timedReacquirePass = false
        timedMisses = 0
        timedRetryPending = false
        Self.census("timed: OFF — timers torn down, normal acquisition resumes")
    }

    private func managerQueue_armTimedConnect() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard G7TimedConnect.enabled else { return }
        timedFireTimer?.cancel(); timedFireTimer = nil
        guard let anchor = timedAnchor else { Self.census("timed: cannot arm — no anchor"); return }
        let fireAt = G7TimedConnect.nextFire(anchor: anchor, now: Date())
        let t = DispatchSource.makeTimerSource(queue: managerQueue)
        t.schedule(deadline: .now() + max(0.05, fireAt.timeIntervalSinceNow))
        t.setEventHandler { [weak self] in self?.managerQueue_timedFire(scheduled: fireAt) }
        t.resume()
        timedFireTimer = t
        Self.census(String(format: "timed: ARMED for %@ (anchor %@, in %.0f s) — no scan, no standing request",
                           Self.timedClock.string(from: fireAt), Self.timedClock.string(from: anchor), fireAt.timeIntervalSinceNow))
    }

    private func managerQueue_timedFire(scheduled: Date, isRetry: Bool = false) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        timedFireTimer = nil
        guard G7TimedConnect.enabled else { return }
        if !isRetry { timedRetryUsedThisCycle = false }   // a fresh grid cycle earns one retry
        guard centralManager.state == .poweredOn else { Self.census("timed: fire skipped — radio not powered on"); managerQueue_armTimedConnect(); return }
        if let p = activePeripheral, p.state == .connected { Self.census("timed: fire skipped — already connected"); managerQueue_armTimedConnect(); return }
        guard let id = activePeripheralIdentifier, let peripheral = centralManager.retrievePeripherals(withIdentifiers: [id]).first else {
            Self.census("timed: fire skipped — no adopted peripheral (adopt the sensor BEFORE removing Dexcom)")
            managerQueue_armTimedConnect(); return
        }
        if let pm = activePeripheralManager { pm.peripheral = peripheral } else {
            activePeripheralManager = G7PeripheralManager(peripheral: peripheral, configuration: .dexcomG7, centralManager: centralManager)
            activePeripheralManager?.delegate = self
        }
        managedPeripherals[peripheral.identifier] = activePeripheralManager
        let late = Date().timeIntervalSince(scheduled)
        timedIssuedAt = Date()
        G7RadioCensus.noteConnectPending()
        centralManager.connect(peripheral)
        // A retry gets the tighter bound: withdrawn 2 s under the daemon's 6-s rule.
        let bound = isRetry ? Self.timedRetryBound : G7TimedConnect.bound
        Self.census(String(format: "timed: connect ISSUED%@ (timer late %+.2f s) — bounded cancel in %.0f s", isRetry ? " [RETRY]" : "", late, bound))
        timedCancelTimer?.cancel()
        let c = DispatchSource.makeTimerSource(queue: managerQueue)
        c.schedule(deadline: .now() + bound)
        c.setEventHandler { [weak self] in self?.managerQueue_timedBoundedCancel(peripheral) }
        c.resume()
        timedCancelTimer = c
    }

    /// Direct auth failed on this cycle's link. Under timed connect, ask for the cycle's one retry.
    /// If the link is still up (AES failure — the sensor closes ~3 s later) the retry is deferred to
    /// didDisconnect so it is timed from the REAL close; if the link is already down (sensor hung up
    /// mid-J-PAKE) schedule it now. Either way the retry lands in close+1.5…+5.5 s.
    private func managerQueue_timedRequestRetry(peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard G7TimedConnect.enabled, !timedRetryUsedThisCycle else { return }
        if peripheral.state == .connected || peripheral.state == .connecting {
            timedRetryPending = true
            Self.census("timed: direct-auth failed with the link still up — retry PENDING until the sensor closes")
        } else {
            managerQueue_scheduleTimedRetry(closeAt: Date())
        }
    }

    /// Schedule the same-burst retry relative to the sensor's close: fire at close+1.5 s, bounded
    /// at 4 s (withdrawn by close+5.5 s). Skipped if the failed link ran past the cap — a late
    /// failure means the sensor is already deep in its cycle and a retry would chase its tail.
    private func managerQueue_scheduleTimedRetry(closeAt: Date) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard G7TimedConnect.enabled, !timedRetryUsedThisCycle else { return }
        let linkRan = directAuthLinkStartedAt.map { closeAt.timeIntervalSince($0) } ?? 0
        guard linkRan <= Self.timedRetryLinkCap else {
            Self.census(String(format: "timed: retry SKIPPED — failed link ran %.1f s (> %.0f s cap): sensor deep in its cycle, waiting for the grid", linkRan, Self.timedRetryLinkCap))
            timedRetryUsedThisCycle = true
            managerQueue_armTimedConnect()
            return
        }
        timedRetryUsedThisCycle = true
        timedFireTimer?.cancel(); timedFireTimer = nil
        let fireAt = closeAt.addingTimeInterval(Self.timedRetryDelay)
        let t = DispatchSource.makeTimerSource(queue: managerQueue)
        t.schedule(deadline: .now() + max(0.05, fireAt.timeIntervalSinceNow))
        t.setEventHandler { [weak self] in self?.managerQueue_timedFire(scheduled: fireAt, isRetry: true) }
        t.resume()
        timedFireTimer = t
        Self.census(String(format: "timed: SAME-BURST RETRY scheduled at close+%.1f s (failed link ran %.1f s; bound %.0f s → withdrawn by close+%.1f s; one per cycle)",
                           Self.timedRetryDelay, linkRan, Self.timedRetryBound, Self.timedRetryDelay + Self.timedRetryBound))
    }

    private func managerQueue_timedBoundedCancel(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        timedCancelTimer = nil
        guard G7TimedConnect.enabled else { return }
        let age = timedIssuedAt.map { Date().timeIntervalSince($0) } ?? -1
        if peripheral.state == .connecting {
            centralManager.cancelPeripheralConnection(peripheral)
            G7RadioCensus.noteConnectResolved()
            Self.census(String(format: "timed: BOUNDED CANCEL at +%.1f s — request withdrawn under the fast scan", age))
        } else {
            Self.census(String(format: "timed: bound reached at +%.1f s, state=%d — nothing pending to cancel", age, peripheral.state.rawValue))
        }
        timedIssuedAt = nil
        managerQueue_timedNoteMissAndRearm()
    }

    /// A fire ended without a didConnect. Re-arm, or after `timedMissLimit` in a row run the
    /// one-shot re-acquire pass.
    private func managerQueue_timedNoteMissAndRearm() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        timedMisses += 1
        if timedMisses >= Self.timedMissLimit, !timedReacquirePass {
            timedReacquirePass = true
            timedMisses = 0
            Self.census("timed: \(Self.timedMissLimit) consecutive MISSES — anchor presumed stale; ONE normal scan+connect pass to re-anchor (contaminates this cycle; 90 s cap)")
            let t = DispatchSource.makeTimerSource(queue: managerQueue)
            t.schedule(deadline: .now() + 90)
            t.setEventHandler { [weak self] in
                guard let self = self, self.timedReacquirePass else { return }
                self.timedReacquirePass = false
                if self.centralManager.isScanning { self.centralManager.stopScan(); self.delegate?.bluetoothManagerScanningStatusDidChange(self) }
                if let p = self.activePeripheral, p.state == .connecting { self.centralManager.cancelPeripheralConnection(p); G7RadioCensus.noteConnectResolved() }
                Self.census("timed: re-acquire pass TIMED OUT at 90 s — scan and request withdrawn, back to the grid")
                self.managerQueue_armTimedConnect()
            }
            t.resume()
            timedReacquireTimer = t
            managerQueue_scanForPeripheral()
            return
        }
        Self.census("timed: miss \(timedMisses)/\(Self.timedMissLimit)")
        managerQueue_armTimedConnect()
    }

    var activePeripheralIdentifier: UUID? {
        get {
            return lockedPeripheralIdentifier.value
        }
    }
    private let lockedPeripheralIdentifier: Locked<UUID?> = Locked(nil)

    /// Isolated to `managerQueue`
    private var activePeripheralManager: G7PeripheralManager? {
        didSet {
            oldValue?.delegate = nil
            lockedPeripheralIdentifier.value = activePeripheralManager?.peripheral.identifier
        }
    }

    // MARK: - Synchronization

    private let managerQueue = DispatchQueue(label: "com.loudnate.CGMBLEKit.bluetoothManagerQueue", qos: .unspecified)

    /// FORK ADDITION (Sport Mode #101, 2026-08-10): radio-census sink. os_log lines from this
    /// layer never reach the on-watch mirrored log, which is what the field analysis reads —
    /// the 2026-08-10 acquisition investigation had to infer the mechanism because discovery,
    /// connection events, and connect verdicts were all invisible. Same pattern as OmnipodKit's
    /// `podLoanLogSink`; the watch wires it, the phone leaves it nil (os_log only).
    ///
    /// Acquisition has THREE triggers, and the census must name which one fired:
    ///  (a) retrieveConnectedPeripherals at scan start — riding a link D2W already holds
    ///  (b) connectionEventDidOccur — the OS reporting D2W (or anyone) connecting to a sensor
    ///  (c) advertisement scan — the only path that needs active scanning
    private static func census(_ line: String) { G7RadioCensus.sink?(line) }
    /// didDiscover fires many times per transmit window; log each peripheral at most
    /// once per 30 s. managerQueue-confined.
    private var lastDiscoveryLog: [UUID: Date] = [:]

    override init() {
        super.init()

        managerQueue.sync {
#if os(iOS) // watchOS has no CoreBluetooth state restoration; the watch host owns reconnect policy
            self.centralManager = CBCentralManager(delegate: self, queue: managerQueue, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.loudnate.CGMBLEKit"])
#else
            self.centralManager = CBCentralManager(delegate: self, queue: managerQueue, options: nil)
#endif
        }
    }

    // MARK: - Actions

    func scanForPeripheral() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            self.managerQueue_scanForPeripheral()
        }
    }

    func forgetPeripheral() {
        managerQueue.sync {
            self.activePeripheralManager = nil
        }
    }

    func stopScanning() {
        managerQueue.sync {
            managerQueue_stopScanning()
        }
    }

    private func managerQueue_stopScanning() {
        if centralManager.isScanning {
            log.default("Stopping scan")
            centralManager.stopScan()
            delegate?.bluetoothManagerScanningStatusDidChange(self)
        }
    }

    /// One-shot override: the NEXT re-arm scans even under ride-only, and issues a connect
    /// for an already-adopted sensor. Set only by the user's own "Reconnect CGM" button
    /// (Jeremy, 2026-09-08: "we can violate ride only when it's a button that I push").
    ///
    /// Ride-only exists to keep OUR radio out of the sensor's extended-phase tail
    /// AUTOMATICALLY — that is where a scan of ours earned the -70 floor. A deliberate tap is
    /// not the automatic case: someone is standing there watching a stuck CGM, and the
    /// alternative is waiting up to a full 5-minute window for Dexcom's next link. One scan,
    /// once, on demand. It does NOT change the policy: the flag is consumed by the first pass
    /// that uses it, so the very next re-arm is ride-only again.
    private let forceAcquireLock = NSLock()
    private var _forceAcquireOnce = false
    private func consumeForceAcquireOnce() -> Bool {
        forceAcquireLock.lock(); defer { forceAcquireLock.unlock() }
        let was = _forceAcquireOnce
        _forceAcquireOnce = false
        return was
    }

    /// Drop the current link and re-acquire the SAME sensor. Keeps the adopted identity
    /// (`disconnect()` cancels the connection but never clears `activePeripheralIdentifier`),
    /// so this is the cheap first move for a stuck client — strictly less disruptive than
    /// "Re-acquire Sensor", which forgets the sensor and rebuilds cold.
    func recycleConnectForLab() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))
        let before = managerQueue.sync {
            "peripheral=\(activePeripheral.map { "\($0.state.rawValue)" } ?? "none") adopted=\(activePeripheralIdentifier != nil) scanning=\(centralManager.isScanning)"
        }
        forceAcquireLock.lock(); _forceAcquireOnce = true; forceAcquireLock.unlock()
        Self.census("lab: RECONNECT requested by the user — forcing one acquisition pass (ride-only bypassed for this pass only) — before: \(before)")
        disconnect()
        // NOT an immediate re-issue: cancelPeripheralConnection is non-blocking and the #101
        // guard in handleDiscoveredPeripheral drops a re-issue while the peripheral still reads
        // `.connecting`. The 2 s settle lets the cancel resolve first.
        scanAfterDelay()
    }

    func disconnect() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            if centralManager.isScanning {
                log.default("Stopping scan on disconnect")
                centralManager.stopScan()
                delegate?.bluetoothManagerScanningStatusDidChange(self)
            }

            if let peripheral = activePeripheral {
                centralManager.cancelPeripheralConnection(peripheral)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        managerQueue.async {
            // Trigger (b): the OS saw a connection event on a sensor-service peripheral —
            // in practice, D2W connecting for its reading. Log ALWAYS (even when we have an
            // active peripheral and ignore it): the census needs D2W's rhythm either way.
            if event == .peerConnected { G7RadioCensus.noteRideSignal() }
            self.lastDeliveryAt = Date()
            Self.census("connection-event \(event.rawValue == 1 ? "CONNECT" : "disconnect") \(peripheral.name ?? "unnamed") — \(self.activePeripheralIdentifier == nil ? "handling (trigger b)" : "ignored, have active")")
            if let name = peripheral.name { G7RadioCensus.sensorSighted?(name) }
            if G7TimedConnect.enabled { return }   // timed mode: observe only, never connect from here
            if self.activePeripheralIdentifier == nil {
                self.log.default("Discovered peripheral from connectionEventDidOccur %{public}@", peripheral.identifier.uuidString)
                self.handleDiscoveredPeripheral(peripheral, viaLinkUp: event == .peerConnected)
            } else if G7RidePolicy.shouldJoin(rideOnly: Self.rideOnly,
                                             connected: event == .peerConnected,
                                             isAdoptedPeripheral: peripheral.identifier == self.activePeripheralIdentifier,
                                             alreadyConnected: self.activePeripheral?.state == .connected) {
                // RIDE-ONLY: we keep NO request of our own on the bond; Dexcom's link just came
                // up, so join it now — connect() on an already-linked peripheral completes at
                // once. Trigger (b), promoted from "ignored, have active" to the only path.
                Self.census("ride-only: Dexcom's link is up — joining \(peripheral.name ?? "unnamed")")
                self.handleDiscoveredPeripheral(peripheral, viaLinkUp: true)
            }
        }
    }

    private func managerQueue_scanForPeripheral() {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        guard centralManager.state == .poweredOn else {
            return
        }

        let currentState = activePeripheral?.state ?? .disconnected
        guard currentState != .connected else {
            return
        }

        // Consumed here, after the early-outs: a pass that returns without acting must not
        // burn the user's tap.
        let userForced = consumeForceAcquireOnce()

        if G7TimedConnect.enabled, !timedReacquirePass {
            // TIMED MODE owns the radio: no connection-event registration, no scan, no standing
            // request. The only thing that touches the sensor is the bounded connect the grid
            // timer issues. (A user-forced pass is deliberately swallowed here.)
            managerQueue_armTimedConnect()
            return
        }

        let sensorServices = [SensorServiceUUID.advertisement.cbUUID, SensorServiceUUID.cgmService.cbUUID]

        if let peripheralID = activePeripheralIdentifier, let peripheral = centralManager.retrievePeripherals(withIdentifiers: [peripheralID]).first {
            // DIRECT AUTH owns the connection: with no Dexcom to piggyback on, ride-only would
            // wait forever. Issue our own connect to the adopted sensor so the handshake can run.
            if !userForced, !G7DirectAuth.enabled, !G7RidePolicy.shouldIssueConnect(rideOnly: Self.rideOnly, adopted: true) {
                // RIDE-ONLY: no request of ours while a sensor is adopted — the pending connect
                // is what the daemon's auto-connection turns into failed establishments in the
                // sensor's tail. Register for connection events and join Dexcom's link when it
                // comes up (connectionEventDidOccur).
                centralManager.registerForConnectionEvents(options: [CBConnectionEventMatchingOption.serviceUUIDs: sensorServices])
                Self.census("ride-only: no request of ours for \(peripheral.name ?? "unnamed") — connection-events registered, waiting for Dexcom's link")
                return
            }
            log.default("Retrieved peripheral %{public}@", peripheral.identifier.uuidString)
            Self.census("scan-start: retrieved KNOWN peripheral \(peripheral.name ?? "unnamed") state=\(peripheral.state.rawValue)")
            handleDiscoveredPeripheral(peripheral)
        } else {
            let systemConnected = centralManager.retrieveConnectedPeripherals(withServices: [
                SensorServiceUUID.advertisement.cbUUID,
                SensorServiceUUID.cgmService.cbUUID
            ])
            // Trigger (a): the literal piggyback. Empty means D2W held no sensor link at this
            // exact moment — its connections last ~10-20 s per 5-min window, so this is a
            // timing lottery and the census must show every draw.
            Self.census("scan-start: system-connected list = [\(systemConnected.map { $0.name ?? "unnamed" }.joined(separator: ","))] (\(systemConnected.count))")
            for peripheral in systemConnected {
                log.default("Found system-connected peripheral: %{public}@", peripheral.identifier.uuidString)
                handleDiscoveredPeripheral(peripheral, viaLinkUp: true)
            }
        }

        // THE 20-40 MINUTE OUTAGE FIX (2026-08-20). This used to be `activePeripheral == nil`, so the
        // known-sensor branch above — which retrieves the peripheral and issues a bare connect() —
        // left NO scan armed. A pending connect depends on bluetoothd's own duty-cycled background
        // scan, which against a 1-4 s advertising burst per 300 s window is a lottery: measured
        // 2026-08-19/20, seven consecutive windows missed, 20-40 min outages ending only when the
        // sensor escalated to ~60 s distress cadence (also measured — the "exact 300 s grid" is the
        // COLLECTED regime only). An armed scan catches the FIRST burst instead. Crude proved the same
        // lesson ("scan is the primitive"). didConnect stops the scan via readied →
        // managerQueue_stopScanning, and handleDiscoveredPeripheral's #101 guard makes a discovery
        // during a pending connect a no-op, so this cannot churn.
        if activePeripheral?.state != .connected {
            centralManager.registerForConnectionEvents(options: [CBConnectionEventMatchingOption.serviceUUIDs: sensorServices])

            if userForced || G7RidePolicy.shouldScanToAcquire(rideOnly: Self.rideOnly) {
                log.default("Scanning for peripherals and listening for connection events")
                centralManager.scanForPeripherals(withServices: [SensorServiceUUID.advertisement.cbUUID], options: nil)
                G7RadioCensus.scanStarted?()
                Self.census("scan STARTED (trigger c armed) + connection-events registered (trigger b armed)")
            } else {
                // RIDE-ONLY: never scan, adopted or not. A scan of ours in the sensor's tail is
                // what earned the −70 floor in every wedge that was not the pod's; the
                // connection-event registration delivers Dexcom's next link and an un-adopted
                // sensor is adopted from the air there.
                Self.census("ride-only: NO scan (peripheral=\(activePeripheral == nil ? "none" : "known")) — connection-events registered, adopting from Dexcom's next link")
            }
            delegate?.bluetoothManagerScanningStatusDidChange(self)
        }
        armScanWatchdog()
    }

    /**

     Persistent connections don't seem to work with the transmitter shutoff: The OS won't re-wake the
     app unless it's scanning.

     The sleep gives the transmitter time to shut down, but keeps the app running.

     */
    /// #101 churn fix: single-flight. Every didFail/didDisconnect used to schedule its own
    /// 2s-delayed rescan; a failed ride produced a burst of them and each rescan re-fired
    /// connection events that produced more failures (2026-08-10 23:31:52-59, ~10 scan
    /// restarts/second). N failures now schedule exactly one rescan.
    private let scanRestartPending = NSLock()
    private var _scanRestartPending = false

    fileprivate func scanAfterDelay() {
        scanRestartPending.lock()
        let alreadyPending = _scanRestartPending
        _scanRestartPending = true
        scanRestartPending.unlock()
        guard !alreadyPending else { return }

        DispatchQueue.global(qos: .utility).async {
            Thread.sleep(forTimeInterval: 2)
            self.scanRestartPending.lock()
            self._scanRestartPending = false
            self.scanRestartPending.unlock()
            self.scanForPeripheral()
        }
    }

    // MARK: - Accessors

    var isScanning: Bool {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        var isScanning = false
        managerQueue.sync {
            isScanning = centralManager.isScanning
        }
        return isScanning
    }

    var isConnected: Bool {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        var isConnected = false
        managerQueue.sync {
            isConnected = activePeripheral?.state == .connected
        }
        return isConnected
    }

    /// `viaLinkUp`: the caller knows another app's link to this peripheral is UP (a CONNECT
    /// connection event, or the system-connected list). The CBPeripheral's own `state` cannot
    /// say so — each app holds its own handle, and ours reads `.disconnected` until WE connect
    /// (her build 170 looped 480 times on exactly that: join → "not connected" → re-register →
    /// the OS re-fires CONNECT → join … never issuing the connect() that IS the join).
    private func handleDiscoveredPeripheral(_ peripheral: CBPeripheral, viaLinkUp: Bool = false) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        // #101 churn fix (2026-08-10 23:31:52-59): during a failed ride, every scan restart
        // re-registers connection events and the OS re-fires CONNECT for the already-linked
        // D2W peripheral — each firing landed here and issued ANOTHER connect() while the
        // first was still pending, minting a fresh G7PeripheralManager per event (~10/s).
        // A pending connect is already doing everything a duplicate would; skip it.
        if peripheral.state == .connecting, managedPeripherals[peripheral.identifier] != nil {
            G7RadioCensus.noteRideSignal()
            return
        }

        if let delegate = delegate {
            switch delegate.bluetoothManager(self, shouldConnectPeripheral: peripheral) {
            case .makeActive:
                log.default("Making peripheral active: %{public}@", peripheral.identifier.uuidString)

                if let peripheralManager = activePeripheralManager {
                    peripheralManager.peripheral = peripheral
                } else {
                    activePeripheralManager = G7PeripheralManager(
                        peripheral: peripheral,
                        configuration: .dexcomG7,
                        centralManager: centralManager
                    )
                    activePeripheralManager?.delegate = self
                }
                self.managedPeripherals[peripheral.identifier] = activePeripheralManager
                // DIRECT AUTH owns the connection: never wait for Dexcom's link (there may be no
                // Dexcom at all) — fall through and issue our own connect so didConnect fires and
                // the J-PAKE handshake runs.
                if !G7DirectAuth.enabled,
                   !G7RidePolicy.shouldRequestOnDiscovery(rideOnly: Self.rideOnly, known: true,
                                                          peripheralConnected: viaLinkUp || peripheral.state == .connected) {
                    // RIDE-ONLY, known-but-unlinked (a connection event that was a disconnect,
                    // or a sighting after a forget): adopt from the air, put NO request of ours
                    // on the bond, and wait for Dexcom's link to come up as a connection event.
                    if centralManager.isScanning {
                        centralManager.stopScan()
                        delegate.bluetoothManagerScanningStatusDidChange(self)
                    }
                    centralManager.registerForConnectionEvents(options: [CBConnectionEventMatchingOption.serviceUUIDs: [
                        SensorServiceUUID.advertisement.cbUUID,
                        SensorServiceUUID.cgmService.cbUUID
                    ]])
                    Self.census("ride-only: adopted \(peripheral.name ?? "unnamed") from the air — no request of ours, waiting for Dexcom's link")
                    return
                }
                G7RadioCensus.noteConnectPending()
                self.centralManager.connect(peripheral)

            case .connect:
                log.default("Connecting to peripheral: %{public}@", peripheral.identifier.uuidString)
                G7RadioCensus.noteConnectPending()
                self.centralManager.connect(peripheral)
                let peripheralManager = G7PeripheralManager(
                    peripheral: peripheral,
                    configuration: .dexcomG7,
                    centralManager: centralManager
                )
                peripheralManager.delegate = self
                self.managedPeripherals[peripheral.identifier] = peripheralManager
            case .ignore:
                break
            }
        }
    }

    override var debugDescription: String {
        return [
            "## BluetoothManager",
            activePeripheralManager.map(String.init(reflecting:)) ?? "No peripheral",
        ].joined(separator: "\n")
    }
}


extension G7BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        activePeripheralManager?.centralManagerDidUpdateState(central)
        log.default("%{public}@: %{public}@", #function, String(describing: central.state.rawValue))

        switch central.state {
        case .poweredOn:
            managerQueue_scanForPeripheral()
        case .resetting, .poweredOff, .unauthorized, .unknown, .unsupported:
            fallthrough
        @unknown default:
            if central.isScanning {
                log.default("Stopping scan on central not powered on")
                central.stopScan()
                delegate?.bluetoothManagerScanningStatusDidChange(self)
            }
        }
    }

#if os(iOS) // watchOS has no CoreBluetooth state restoration (willRestoreState / restored-state keys are iOS-only)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                log.default("Restoring peripheral from state: %{public}@", peripheral.identifier.uuidString)
                handleDiscoveredPeripheral(peripheral)
            }
        }
    }
#endif

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("%{public}@: %{public}@, data = %{public}@", #function, peripheral, String(describing: advertisementData))

        // Trigger (c): an advertisement reached our scan. Rate-limited per peripheral; the
        // interesting signal is PRESENCE vs ABSENCE per window — a held-pod-link arm with no
        // didDiscover lines while D2W reads fine is scan starvation, observed directly.
        G7RadioCensus.noteRideSignal()
        if lastDiscoveryLog[peripheral.identifier].map({ Date().timeIntervalSince($0) > 30 }) ?? true {
            lastDiscoveryLog[peripheral.identifier] = Date()
            lastDeliveryAt = Date()
            Self.census("ad DISCOVERED (trigger c) \(peripheral.name ?? "unnamed") rssi \(RSSI)")
            if let name = peripheral.name { G7RadioCensus.sensorSighted?(name) }
        }

        managerQueue.async {
            self.handleDiscoveredPeripheral(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        G7RadioCensus.noteConnectResolved()
        lastDeliveryAt = Date()
        Self.census("didConnect \(peripheral.name ?? "unnamed")")
        if G7TimedConnect.enabled {
            timedCancelTimer?.cancel(); timedCancelTimer = nil
            let age = timedIssuedAt.map { Date().timeIntervalSince($0) } ?? -1
            timedAnchor = Date()
            timedIssuedAt = nil
            timedMisses = 0
            if timedReacquirePass {
                timedReacquirePass = false
                timedReacquireTimer?.cancel(); timedReacquireTimer = nil
                if centralManager.isScanning { centralManager.stopScan(); delegate?.bluetoothManagerScanningStatusDidChange(self) }
                Self.census("timed: re-acquire pass CONNECTED — re-anchored, scan stopped, back to the grid")
            } else {
                Self.census(String(format: "timed: didConnect at +%.2f s after issue — RE-ANCHORED", age))
            }
        }

        log.default("%{public}@: %{public}@", #function, peripheral)

        if let peripheralManager = managedPeripherals[peripheral.identifier] {
            peripheralManager.centralManager(central, didConnect: peripheral)

            if let delegate = delegate, case .poweredOn = centralManager.state, case .connected = peripheral.state {
                if delegate.bluetoothManager(self, readied: peripheralManager) {
                    managerQueue_stopScanning()
                }
            }
            if G7DirectAuth.enabled, directAuthSession == nil {
                managerQueue_startDirectAuth(peripheralManager, peripheral: peripheral)
            }
        }
    }

    /// Start our own J-PAKE handshake on the just-connected peripheral. Runs inside a perform so
    /// characteristic discovery has completed; the session drives writes through this manager and
    /// is fed inbound notifications by didUpdateValueFor. Diagnostic; gated by G7DirectAuth.enabled.
    private func managerQueue_startDirectAuth(_ pm: G7PeripheralManager, peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        pm.perform { m in
            let discovered = (peripheral.services ?? []).flatMap { $0.characteristics ?? [] }
            func char(_ id: CGMServiceCharacteristicUUID) -> CBCharacteristic? {
                discovered.first { $0.uuid == id.cbUUID }
            }
            guard let auth = char(.authentication),
                  let data = char(.data),
                  let ctrl = char(.control) else {
                Self.census("[direct-auth] cannot start — auth/data/control not all discovered")
                return
            }
            let pin = G7DirectAuth.pin4
            let session = G7DirectAuthSession(peripheralManager: m, authChar: auth, dataChar: data,
                                              ctrlChar: ctrl, pin4: pin, slotByte: G7DirectAuth.slotByte,
                                              log: { Self.census($0) })
            self.directAuthSession = session
            self.directAuthLinkStartedAt = Date()
            Self.census("[direct-auth] starting handshake (\(pin.count)-digit pin, slot 0x\(String(format: "%02x", G7DirectAuth.slotByte)))")
            Task {
                let r = await session.run()
                Self.census("[direct-auth] RESULT auth=\(r.authByte.map { "\($0)" } ?? "-") bond=\(r.bondByte.map { "\($0)" } ?? "-") glucose=\(r.glucose.map { "\($0)" } ?? "nil")\(r.error.map { " error=\($0)" } ?? "")")
                // INGEST: hand the reading to Loop through the STOCK path. Clear the stock
                // observer's pending-auth first (so the sensor's routine hang-up is not misread
                // as end-of-session), then forward the raw 0x4E control notification into
                // didReceiveControlResponse — the same parse → handleGlucoseMessage → delegate
                // chain a Dexcom-authed read takes. Dispatched on managerQueue, where stock's own
                // control responses arrive.
                // A failed handshake under timed connect gets this cycle's one same-burst retry.
                if !r.authenticated {
                    self.managerQueue.async { self.managerQueue_timedRequestRetry(peripheral: m.peripheral) }
                    return
                }
                guard let egv = r.egvRaw else { return }
                self.managerQueue.async {
                    self.delegate?.bluetoothManager(self, directAuthDidAuthenticate: m)
                    self.delegate?.bluetoothManager(self, peripheralManager: m, didReceiveControlResponse: Data(egv))
                    Self.census("[direct-auth] INGEST forwarded \(egv.count)-byte EGV to the stock glucose path")
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        // #101: the failing half of the churn cycle was invisible — the census had
        // didConnect but neither terminal callback, so a ride that died looked identical
        // to one that never started.
        G7RadioCensus.noteConnectResolved()
        G7RadioCensus.sensorClosed?(peripheral.name ?? "unnamed")
        // [domain#code] alongside Apple's prose (from the pure line, where a grep for Code=11
        // returned zero while 34 connection-limit failures sat in the log as text only).
        Self.census("didDisconnect \(peripheral.name ?? "unnamed")\(error.map { " [\(($0 as NSError).domain)#\(($0 as NSError).code)] \($0.localizedDescription)" } ?? "")")
        log.default("%{public}@: %{public}@", #function, peripheral)
        // Ignore errors indicating the peripheral disconnected remotely, as that's expected behavior
        if let error = error as NSError?, CBError(_nsError: error).code != .peripheralDisconnected {
            log.error("%{public}@: %{public}@", #function, error)
            if let peripheralManager = activePeripheralManager {
                self.delegate?.bluetoothManager(self, readyingFailed: peripheralManager, with: error)
            }
        }

        if let peripheralManager = managedPeripherals[peripheral.identifier] {
            let remoteDisconnect: Bool
            if let error = error as NSError?, CBError(_nsError: error).code == .peripheralDisconnected {
                remoteDisconnect = true
            } else {
                remoteDisconnect = false
            }
            self.delegate?.peripheralDidDisconnect(self, peripheralManager: peripheralManager, wasRemoteDisconnect: remoteDisconnect)
        }

        if peripheral != activePeripheral {
            managedPeripherals.removeValue(forKey: peripheral.identifier)
        }

        directAuthSession?.cancel(); directAuthSession = nil

        // A failed handshake deferred its retry to the real close — schedule it from here, timed
        // from this disconnect, in place of the next-grid arm (a retry miss re-arms the grid).
        if timedRetryPending {
            timedRetryPending = false
            managerQueue_scheduleTimedRetry(closeAt: Date())
            return
        }

        if G7TimedConnect.enabled { managerQueue_armTimedConnect(); return }
        scanAfterDelay()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        G7RadioCensus.noteConnectResolved()
        Self.census("didFailToConnect \(peripheral.name ?? "unnamed")\(error.map { " [\(($0 as NSError).domain)#\(($0 as NSError).code)] \($0.localizedDescription)" } ?? "")")

        log.error("%{public}@: %{public}@", #function, String(describing: error))
        if G7TimedConnect.enabled {
            timedCancelTimer?.cancel(); timedCancelTimer = nil
            let age = timedIssuedAt.map { Date().timeIntervalSince($0) } ?? -1
            // THE MOVE UNDER TEST: withdraw the request the instant it fails, before the daemon's
            // own "Connection failed, Retrying" re-adds the device and lands a late attempt in the
            // sensor's tail. Whether this beats that retry is what the sysdiagnose will show.
            centralManager.cancelPeripheralConnection(peripheral)
            Self.census(String(format: "timed: didFailToConnect at +%.2f s — CANCELLED IMMEDIATELY (does the daemon still retry? read the capture)", age))
            timedIssuedAt = nil
            managerQueue_timedNoteMissAndRearm()
            return
        }
        if let error = error, let peripheralManager = activePeripheralManager {
            self.delegate?.bluetoothManager(self, readyingFailed: peripheralManager, with: error)
        }

        if peripheral != activePeripheral {
            managedPeripherals.removeValue(forKey: peripheral.identifier)
        }

        scanAfterDelay()
    }
}


extension G7BluetoothManager: G7PeripheralManagerDelegate {
    func peripheralManager(_ manager: G7PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?) {

    }

    func peripheralManagerDidUpdateName(_ manager: G7PeripheralManager) {
    }

    func peripheralManagerDidConnect(_ manager: G7PeripheralManager) {
    }

    func completeConfiguration(for manager: G7PeripheralManager) throws {
    }

    func peripheralManager(_ manager: G7PeripheralManager, didUpdateValueFor characteristic: CBCharacteristic) {
        guard let value = characteristic.value else {
            return
        }

        // Direct-auth handshake owns auth/data/control until it authenticates; then control
        // notifications fall through to the stock glucose path below.
        if let session = directAuthSession, session.feed(characteristic.uuid, value) {
            return
        }

        switch CGMServiceCharacteristicUUID(rawValue: characteristic.uuid.uuidString.uppercased()) {
        case .none, .communication?, .data?:
            return
        case .control?:
            self.delegate?.bluetoothManager(self, peripheralManager: manager, didReceiveControlResponse: value)
        case .backfill?:
            self.delegate?.bluetoothManager(self, didReceiveBackfillResponse: value)
        case .authentication?:
            self.delegate?.bluetoothManager(self, peripheralManager: manager, didReceiveAuthenticationResponse: value)
        }
    }
}

/// Ride-only (mute record §5, ported by content 2026-09-08): while a sensor is adopted, keep NO
/// pending connect of our own on the bond and no scan; register for connection events and join
/// Dexcom's link when it comes up. Pure so the bench can pin it.
///
/// Why: bluetoothd keeps one accept-list entry per device shared by every app, and a per-device
/// signal-quality tally (5.8-h window, threshold 5). A link that forms and dies before encryption
/// (HCI 0x3E) counts; at count 5 a failure that comes AFTER the daemon's 6-s fast scan makes its
/// retry park a −70 dBm floor on the entry — below wrist-to-arm RSSI — and every app on the bond
/// is mute until a strong burst or a Bluetooth toggle. The counter is fed by Dexcom's own
/// re-subscribe into the sensor's long tails (not ours to prevent); the LATE failure that writes
/// the floor happened, on record, only with our scan or our pod link on the chip in that tail.
/// TIMED, BOUNDED CONNECT — the experiment that decides whether a direct-auth client of OURS
/// could avoid bluetoothd's −70 dBm floor (the G7 mute). Built 2026-09-11 after the Dexcom-alone
/// arm proved the mute is platform-native: departure → the daemon scores failed establishments →
/// count 5 → judgment 1 → the next failure landing >6 s after the connect REQUEST writes −70.
/// Every −70 on record came from the daemon's OWN retry ("Connection failed, Retrying") landing
/// late in the sensor's tail. So the question is whether a client that (a) never scans, (b) never
/// leaves a request standing, (c) connects on the grid just before the burst and (d) withdraws the
/// request at 5 s — or the instant it fails — can keep the daemon from ever making that late retry.
///
/// Watch-only, diagnostic key, default OFF. Meant to run with the Dexcom watch app REMOVED (so ours
/// is the only client) under the CGM-only soak (keepalive, no pod), with the sniffer on the sensor
/// and a sysdiagnose inside 3 h. Without auth the sensor hangs up ~10 s after we connect; that is
/// fine — we are testing the connect PATTERN against the daemon's tally, not reading glucose.
/// Pass = no −70 ever, and no "Retrying" line after one of our cancels. The −70 is measured from
/// the request, not the burst, so `bound` sits under the daemon's 6-s fast scan with margin.
/// DIRECT AUTH — our OWN J-PAKE authentication to the G7 (see G7DirectAuthSession), so the
/// watch/phone reads glucose with no Dexcom app present. Diagnostic, default OFF. The pairing
/// code (J-PAKE PIN) is provided by us; defaults to the current bench sensor.
public enum G7DirectAuth {
    public static let key = "G7Lab.directAuth"
    public static let pinKey = "G7Lab.directAuth.pin"
    public static let slotByte: UInt8 = 0x01   // concurrent slot, proven to coexist with a phone (auth=1)
    public static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
    public static var pin4: [UInt8] {
        let s = UserDefaults.standard.string(forKey: pinKey) ?? "9151"
        return Array(String(s.filter { $0.isNumber }.prefix(4)).utf8)
    }
}

public enum G7TimedConnect {
    public static let key = "G7Lab.timedConnect"
    public static let anchorKey = "G7Lab.timedConnect.anchor"
    /// The sensor's collected cadence, measured 296–311 s across 11 links on 2026-09-09.
    public static let period: TimeInterval = 300
    /// Issue the connect this long BEFORE the expected burst.
    public static let lead: TimeInterval = 2
    /// Withdraw a still-pending request this long after issuing it (< the daemon's 6-s fast scan).
    public static let bound: TimeInterval = 5
    public static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
    /// Pure, pinned by WatchAppTests: the next grid-aligned fire time strictly after `now + margin`.
    /// Grid point n fires at anchor + n·period − lead. Re-anchored on every didConnect, so drift
    /// (≈0.4 s/cycle against a fixed 300) never accumulates.
    public static func nextFire(anchor: Date, now: Date, margin: TimeInterval = 1) -> Date {
        var n = floor(now.timeIntervalSince(anchor) / period)
        var t = anchor.addingTimeInterval(n * period - lead)
        while t <= now.addingTimeInterval(margin) { n += 1; t = anchor.addingTimeInterval(n * period - lead) }
        return t
    }
}

public enum G7RidePolicy {
    public static let key = "G7Lab.rideOnly"
    /// WATCH ONLY. G7SensorKit also compiles into the phone app, whose manager keeps stock
    /// behaviour — the mute is a watch-daemon phenomenon. The key is a diagnostic override.
    public static var rideOnlyEnabled: Bool {
        if let v = UserDefaults.standard.object(forKey: key) as? Bool { return v }
        #if os(watchOS)
        return true
        #else
        return false
        #endif
    }
    /// Should we issue our own connect() for the adopted peripheral?
    public static func shouldIssueConnect(rideOnly: Bool, adopted: Bool) -> Bool {
        !(rideOnly && adopted)
    }
    /// On a connection event: join the link that just came up?
    public static func shouldJoin(rideOnly: Bool, connected: Bool, isAdoptedPeripheral: Bool, alreadyConnected: Bool) -> Bool {
        rideOnly && connected && isAdoptedPeripheral && !alreadyConnected
    }
    /// On DISCOVERY of a peripheral the delegate recognises (`.makeActive`): issue our own
    /// connect()? Only when the link is already up — then connect() completes at once and IS
    /// the join. Otherwise adopt from the air and wait for Dexcom's link.
    public static func shouldRequestOnDiscovery(rideOnly: Bool, known: Bool, peripheralConnected: Bool) -> Bool {
        !(rideOnly && known && !peripheralConnected)
    }
    /// Arm our own acquisition SCAN? Never under ride-only — a scan of ours in the sensor's
    /// tail is the late attempt that writes the floor; adoption from the air needs no scan.
    public static func shouldScanToAcquire(rideOnly: Bool) -> Bool {
        !rideOnly
    }
    /// Stock flags a REMOTE disconnect while auth is still pending as "suspected end of
    /// session" and answers with forget-and-scan. Under ride-only a join the sensor closes
    /// before auth completes is routine and would put our scan into the tail. Keep the
    /// identity; a real replacement sensor arrives on Dexcom's next link.
    public static func shouldForgetOnBareDisconnect(rideOnly: Bool, adopted: Bool) -> Bool {
        !(rideOnly && adopted)
    }
}
