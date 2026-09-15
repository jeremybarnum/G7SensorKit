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
    /// Which request is currently up, so the bounded cancel knows what a miss means.
    private enum TimedAsk { case grid, second, retry }
    private var timedCurrentAsk: TimedAsk = .grid
    /// The grid ask heard nothing → one SECOND ASK (G7TimedConnect.secondAskDelay). Reset on a
    /// grid fire, never by the second ask itself.
    private var timedSecondAskUsedThisCycle = false
    /// A second ask is scheduled and its timer is live in `timedFireTimer`. The bounded cancel's
    /// own didDisconnect arrives a millisecond later and would otherwise re-arm the grid over it —
    /// which is exactly what happened on 2026-09-13 (four "SECOND ASK in 0.5 s" lines, zero
    /// second asks issued). didDisconnect consumes this flag and leaves the timer alone.
    private var timedSecondAskPending = false
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
    private var timedLastConnectAt: Date?
    private var timedReacquirePass = false
    private var timedReacquireTimer: DispatchSourceTimer?
    /// The last reading's SENSOR timestamp (activation + glucoseTimestamp). Persisted so the grid
    /// survives a relaunch; re-anchored on every reading via `noteReading(at:)`, never on connect.
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

    /// A reading arrived: its SENSOR timestamp is the grid. Called by G7Sensor for every glucose
    /// message (stock path and direct auth alike). The burst-offset line is the tuning metric for
    /// `G7TimedConnect.fireOffset`: connect time − reading timestamp, expected ≈ +2 s.
    func noteReading(at readingTimestamp: Date) {
        managerQueue.async { [self] in
            timedAnchor = readingTimestamp
            timedMisses = 0
            if G7TimedConnect.enabled, let c = timedLastConnectAt {
                Self.census(String(format: "timed: anchor ← reading ts %@ · burst offset %+.1f s (connect − ts)",
                                   Self.timedClock.string(from: readingTimestamp), c.timeIntervalSince(readingTimestamp)))
            }
        }
    }

    /// Public entry (off the manager queue). ON: drop any scan or standing request and arm the
    /// grid timer. OFF: tear the timers down and return to the normal posture.
    func setTimedConnect(_ on: Bool, seedAnchor: Date?) {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))
        UserDefaults.standard.set(on, forKey: G7TimedConnect.key)
        managerQueue.async { [self] in
            if on {
                // The anchor is a reading's sensor timestamp — the freshest of the persisted one
                // and the store's latest. Both are on the sensor's own grid, so age costs only
                // crystal drift (≈4 s/day). Nothing known → one normal scan pass finds the sensor
                // and its first reading anchors the grid.
                let candidates: [(String, Date)] = [("the last reading", seedAnchor), ("the persisted anchor", timedAnchor)].compactMap { n, d in d.map { (n, $0) } }
                timedMisses = 0
                if let (label, seed) = candidates.max(by: { $0.1 < $1.1 }) {
                    timedAnchor = seed
                    Self.census(String(format: "timed: anchor = reading ts %@ from %@ (%.0f s old)", Self.timedClock.string(from: seed), label, Date().timeIntervalSince(seed)))
                } else {
                    Self.census("timed: no reading to anchor on — one normal scan+connect pass; its reading anchors the grid")
                }
                if centralManager.isScanning {
                    centralManager.stopScan()
                    delegate?.bluetoothManagerScanningStatusDidChange(self)
                }
                if let p = activePeripheral, p.state == .connecting {
                    centralManager.cancelPeripheralConnection(p)
                    G7RadioCensus.noteConnectResolved()
                    Self.census("timed: ON — withdrew the standing request that was pending")
                }
                if timedAnchor == nil {
                    managerQueue_startTimedReacquirePass(reason: "no anchor yet", scan: true)
                } else {
                    managerQueue_armTimedConnect()
                }
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
        timedSecondAskPending = false
        timedAwakeTimer?.cancel(); timedAwakeTimer = nil
        timedSystemHeldLodged = false
        timedSystemHeldRefusals = 0
        timedSystemHeldDisabled = false
        Self.census("timed: OFF — timers torn down, normal acquisition resumes")
    }

    private func managerQueue_armTimedConnect() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard G7TimedConnect.enabled else { return }
        timedFireTimer?.cancel(); timedFireTimer = nil
        if G7TimedConnect.systemHeld, !timedSystemHeldDisabled { managerQueue_armSystemHeldConnect(); return }
        guard G7TimedConnect.hasRuntime else {
            // No keepalive holder: a suspended app cannot honour the bound. Stand down; the
            // watch app calls timedRuntimeDidChange() when a loan/E1 starts and we re-arm.
            Self.census("timed: no keepalive holder — standing down (no connects until a loan/E1 gives the app runtime)")
            return
        }
        guard let anchor = timedAnchor else {
            // No reading has ever anchored the grid (fresh install, or timed ON by default with
            // nothing persisted). Stock's scan+connect finds the sensor; its first reading
            // anchors the grid and the pass ends. The pass re-arms here on its 90-s cap, so a
            // sensor that is not around yet is retried every 90 s — stock scans continuously.
            managerQueue_startTimedReacquirePass(reason: "no reading to anchor on yet", scan: true)
            return
        }
        let fireAt = G7TimedConnect.nextFire(anchor: anchor, now: Date())
        let t = DispatchSource.makeTimerSource(queue: managerQueue)
        t.schedule(deadline: .now() + max(0.05, fireAt.timeIntervalSinceNow))
        t.setEventHandler { [weak self] in self?.managerQueue_timedFire(scheduled: fireAt) }
        t.resume()
        timedFireTimer = t
        Self.census(String(format: "timed: ARMED for %@ (anchor %@, in %.0f s) — no scan, no standing request",
                           Self.timedClock.string(from: fireAt), Self.timedClock.string(from: anchor), fireAt.timeIntervalSinceNow))
    }

    /// The host's runtime posture changed (a keepalive was acquired or released). Re-arms the
    /// grid timer if timed connect is on: arming re-checks `G7TimedConnect.hasRuntime`, so a
    /// release stands the timer down and an acquire brings it back for the next grid point.
    func timedRuntimeDidChange() {
        managerQueue.async { [self] in
            guard G7TimedConnect.enabled else { return }
            managerQueue_armTimedConnect()
        }
    }

    // MARK: System-held connect — the start-delay arm (Pete's suggestion; EXPERIMENT, default OFF)
    //
    // Same grid, same single request per burst, different holder. Our timer needs the app awake
    // at the burst (hence the keepalive); here the request is lodged with the daemon NOW, with
    // CBConnectPeripheralOptionStartDelayKey = time to the next burst start, and the system
    // starts it whether we are running or not. The central is created with a restore identifier
    // in this mode, so watchOS may relaunch us for the link. Two things are measured, in the log
    // and in the capture: how long after the link came up the app actually ran (the wake latency
    // the 2026-09-03 tape called fatal — measured then on a central that had NOT opted in), and
    // what a miss costs when nobody is awake to withdraw the request before the sensor's tail.
    private var timedAwakeTimer: DispatchSourceTimer?
    private var timedAwakeTick: Date?
    private var timedSystemHeldLodged = false
    private var timedSystemHeldLodgedAt: Date?
    private var timedSystemHeldRefusals = 0
    /// Set after two immediate refusals: the platform declines the option, so the arm yields to
    /// the ordinary timer for the rest of this launch instead of spinning.
    private var timedSystemHeldDisabled = false

    private func managerQueue_armSystemHeldConnect() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        managerQueue_startAwakeTick()
        guard let anchor = timedAnchor else {
            managerQueue_startTimedReacquirePass(reason: "no reading to anchor on yet", scan: true)
            return
        }
        guard centralManager.state == .poweredOn else { Self.census("timed[system-held]: radio not powered on — will arm on power"); return }
        // A relaunch drops the adopted peripheral; under this arm the persisted identifier
        // brings it back without a scan, so the request can be lodged from the first launch.
        let remembered = activePeripheralIdentifier == nil
        let id = activePeripheralIdentifier
            ?? (UserDefaults.standard.string(forKey: G7TimedConnect.adoptedPeripheralKey)).flatMap(UUID.init(uuidString:))
        guard let id = id, let peripheral = centralManager.retrievePeripherals(withIdentifiers: [id]).first else {
            managerQueue_startTimedReacquirePass(reason: "no adopted peripheral and none remembered", scan: true)
            return
        }
        if peripheral.state == .connected { Self.census("timed[system-held]: already connected — the next request is lodged at close"); return }
        if timedSystemHeldLodged { Self.census("timed[system-held]: a request is already lodged — keeping it"); return }
        if let pm = activePeripheralManager { pm.peripheral = peripheral } else {
            activePeripheralManager = G7PeripheralManager(peripheral: peripheral, configuration: .dexcomG7, centralManager: centralManager)
            activePeripheralManager?.delegate = self
        }
        managedPeripherals[peripheral.identifier] = activePeripheralManager
        if remembered { Self.census("timed[system-held]: re-adopted the remembered peripheral \(peripheral.name ?? "unnamed") after a relaunch — no scan") }
        let fireAt = G7TimedConnect.nextFire(anchor: anchor, now: Date())
        let delay = max(0, fireAt.timeIntervalSinceNow)
        timedIssuedAt = fireAt          // "after issue" ages count from the scheduled START
        timedCurrentAsk = .grid
        timedRetryUsedThisCycle = false
        timedSecondAskUsedThisCycle = false
        timedSystemHeldLodged = true
        timedSystemHeldLodgedAt = Date()
        G7RadioCensus.noteConnectPending()
        // Whole seconds: the first field run passed a fractional NSNumber and the daemon answered
        // every request with CBError 1 (invalid parameters) at once. The docs say "number of
        // seconds"; an integer is the one remaining form worth trying before the option is
        // declared unavailable on the watch.
        let wholeSeconds = Int(delay.rounded(.up))
        if G7TimedConnect.standing {
            // No delay: the address goes into the accept list now and the controller connects at
            // the sensor's next advertisement, whichever burst that is. "after the scheduled
            // start" in the link-up line still measures against the 5-min grid, so a minute-burst
            // connect reads as negative and a missed grid point as +300.
            centralManager.connect(peripheral, options: nil)
            Self.census(String(format: "timed[system-held]: STANDING request lodged with the daemon (no start delay) — next grid burst %@ (in %d s, anchor %@); the controller connects at the sensor's next advertisement; no withdrawal, the app may sleep",
                               Self.timedClock.string(from: fireAt), wholeSeconds, Self.timedClock.string(from: anchor)))
        } else {
            centralManager.connect(peripheral, options: [CBConnectPeripheralOptionStartDelayKey: NSNumber(value: wholeSeconds)])
            Self.census(String(format: "timed[system-held]: request LODGED with the daemon — starts %@ (in %d s, anchor %@); no withdrawal, the app may sleep",
                               Self.timedClock.string(from: fireAt), wholeSeconds, Self.timedClock.string(from: anchor)))
        }
        // No bound, by the model under test (Pete, 2026-09-14): the delay is what keeps the
        // request off the air through the sensitive period after our own disconnect, and once
        // it passes the request stands until the system connects it. A missed burst therefore
        // shows up as "link up +300 s" (the next burst) and, if nobody is awake for the
        // handshake, as a failed establishment in the capture — that is the measurement.
        timedCancelTimer?.cancel(); timedCancelTimer = nil
    }

    /// A 2-s heartbeat that only advances while the process runs. On resume the coalesced timer
    /// fires BEFORE the queued Bluetooth callbacks are delivered (field 10:11:40: "last ran 0.0 s"
    /// after a 14-minute sleep), so the staleness of the last tick says nothing at didConnect.
    /// What survives the resume is the GAP the tick just observed: a tick more than 4 s after
    /// its predecessor means the process was asleep in between, and that gap is the sleep.
    private var timedLastSleep: (until: Date, seconds: TimeInterval)?

    private func managerQueue_startAwakeTick() {
        guard timedAwakeTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: managerQueue)
        t.schedule(deadline: .now(), repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = Date()
            if let last = self.timedAwakeTick, now.timeIntervalSince(last) > 4 {
                self.timedLastSleep = (now, now.timeIntervalSince(last))
            }
            self.timedAwakeTick = now
        }
        t.resume()
        timedAwakeTimer = t
    }

    /// "SLEPT 843 s and resumed 0.1 s before this callback" — or awake, with the tick age.
    private var timedSleepSummary: String {
        let now = Date()
        let pid = "pid \(ProcessInfo.processInfo.processIdentifier)"   // same pid across wakes = resumed; new pid = relaunched
        if let s = timedLastSleep, now.timeIntervalSince(s.until) < 3 {
            return String(format: "app SLEPT %.0f s and resumed %.1f s before this callback · %@", s.seconds, now.timeIntervalSince(s.until), pid)
        }
        if let tick = timedAwakeTick { return String(format: "app awake (last tick %.1f s ago) · %@", now.timeIntervalSince(tick), pid) }
        return "app never ticked in this launch (relaunched for it) · \(pid)"
    }

    private func managerQueue_timedFire(scheduled: Date, ask: TimedAsk = .grid) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        timedFireTimer = nil
        guard G7TimedConnect.enabled else { return }
        if ask == .grid {   // a fresh grid cycle earns one retry and one second ask
            timedRetryUsedThisCycle = false
            timedSecondAskUsedThisCycle = false
        }
        if ask == .second { timedSecondAskPending = false }   // the timer has fired; a later close re-arms normally
        let isRetry = ask == .retry
        // Under the system-held arm we are awake by definition when this runs (a retry or second
        // ask is scheduled from a callback), so a bare bounded connect is fine without a holder.
        guard G7TimedConnect.hasRuntime || G7TimedConnect.systemHeld else {
            // The keepalive was released after this timer was armed. A connect issued by a process
            // about to be suspended is exactly the un-cancellable request the bound exists to
            // prevent: stand down instead of arming the next cycle.
            Self.census("timed: fire skipped — no keepalive holder; standing down until a loan/E1 gives the app runtime")
            return
        }
        guard centralManager.state == .poweredOn else { Self.census("timed: fire skipped — radio not powered on"); managerQueue_armTimedConnect(); return }
        if let p = activePeripheral, p.state == .connected { Self.census("timed: fire skipped — already connected"); managerQueue_armTimedConnect(); return }
        guard let id = activePeripheralIdentifier, let peripheral = centralManager.retrievePeripherals(withIdentifiers: [id]).first else {
            // Adoption is the CBCentralManager's, so it dies with the process: every relaunch
            // (install, crash, watchdog kill) starts with no adopted peripheral while sensorID and
            // the anchor persist. Before 2026-09-12 this re-armed forever — 08:44→11:09 of "fire
            // skipped" — and the only way back was toggling timed OFF, tapping Reconnect, and
            // toggling ON. One normal scan+connect pass re-adopts; its reading anchors the grid.
            managerQueue_startTimedReacquirePass(reason: "no adopted peripheral (relaunch drops it)", scan: true)
            return
        }
        if let pm = activePeripheralManager { pm.peripheral = peripheral } else {
            activePeripheralManager = G7PeripheralManager(peripheral: peripheral, configuration: .dexcomG7, centralManager: centralManager)
            activePeripheralManager?.delegate = self
        }
        managedPeripherals[peripheral.identifier] = activePeripheralManager
        let late = Date().timeIntervalSince(scheduled)
        timedIssuedAt = Date()
        timedCurrentAsk = ask
        G7RadioCensus.noteConnectPending()
        centralManager.connect(peripheral)
        // A retry gets the tighter bound: withdrawn 2 s under the daemon's 6-s rule.
        let bound = isRetry ? Self.timedRetryBound : G7TimedConnect.bound
        let label: String
        switch ask { case .grid: label = ""; case .second: label = " [SECOND ASK]"; case .retry: label = " [RETRY]" }
        Self.census(String(format: "timed: connect ISSUED%@ (timer late %+.2f s) — bounded cancel in %.0f s", label, late, bound))
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
        t.setEventHandler { [weak self] in self?.managerQueue_timedFire(scheduled: fireAt, ask: .retry) }
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
        // The grid ask heard nothing: ask once more, half a second later, same bound. The burst is
        // still on the air (7 s with the phone collecting, 25–30 s in a departure), and a request
        // withdrawn inside the fast scan can never write the floor.
        // No second ask under the system-held arm: that arm is one daemon-held request per grid
        // point, and the next one is lodged by the re-arm below.
        timedSystemHeldLodged = false
        if timedCurrentAsk == .grid, !timedSecondAskUsedThisCycle, !G7TimedConnect.systemHeld {
            timedSecondAskUsedThisCycle = true
            timedSecondAskPending = true
            let fireAt = Date().addingTimeInterval(G7TimedConnect.secondAskDelay)
            timedFireTimer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: managerQueue)
            t.schedule(deadline: .now() + G7TimedConnect.secondAskDelay)
            t.setEventHandler { [weak self] in self?.managerQueue_timedFire(scheduled: fireAt, ask: .second) }
            t.resume()
            timedFireTimer = t
            Self.census(String(format: "timed: SECOND ASK in %.1f s — one per cycle, same bound, withdrawn inside the fast scan (a refusal can COUNT, never floor)",
                               G7TimedConnect.secondAskDelay))
            return
        }
        managerQueue_timedNoteMissAndRearm()
    }

    /// A fire ended without a didConnect. Re-arm, or after `timedMissLimit` in a row run the
    /// one-shot re-acquire pass.
    private func managerQueue_timedNoteMissAndRearm() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        timedMisses += 1
        if timedMisses >= Self.timedMissLimit, !timedReacquirePass {
            timedMisses = 0
            // The anchor is a sensor timestamp now, so drift (4 s/day) cannot be the cause: three
            // in a row means the sensor is not where we think it is. One normal pass is the only
            // way back. By then the extended phase (~10 min after a departure) is over, and scans
            // at minute calls score nothing — measured, 17 deliberate collisions.
            managerQueue_startTimedReacquirePass(reason: "\(Self.timedMissLimit) consecutive MISSES — sensor not answering on the grid", scan: true)
            return
        }
        Self.census("timed: miss \(timedMisses)/\(Self.timedMissLimit)")
        managerQueue_armTimedConnect()
    }

    /// ONE normal scan+connect pass while timed mode owns the radio (90-s cap), then back to the
    /// grid. Used by the 3-miss fallback and by a new sensor arriving from the phone. `scan:false`
    /// only arms the pass (the caller issues the scan itself, e.g. as a user-forced one).
    private func managerQueue_startTimedReacquirePass(reason: String, scan: Bool) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard !timedReacquirePass else { return }
        timedReacquirePass = true
        Self.census("timed: \(reason); ONE normal scan+connect pass to re-anchor (contaminates this cycle; 90 s cap)")
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
        if scan { managerQueue_scanForPeripheral() }
    }

    /// A NEW sensor was adopted by identity (handed over from the phone): drop the old
    /// peripheral and go find the new one by name. Ride-only never scans on its own and timed
    /// mode swallows forced passes, so this arms the timed re-acquire pass first and then issues
    /// the acquisition as a user-forced one — the same pair of doors Reconnect CGM opens.
    func reacquireForNewSensor() {
        forgetPeripheral()
        if G7TimedConnect.enabled {
            managerQueue.async { self.managerQueue_startTimedReacquirePass(reason: "new sensor from the phone", scan: false) }
        }
        recycleConnectForLab()
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
            // Remembered across relaunches for the system-held arm only: a relaunch otherwise
            // drops the adopted peripheral and the arm can lodge nothing until a scan pass finds
            // the sensor again — which, with no runtime, it never does (2026-09-14 05:37→06:03).
            if let id = activePeripheralManager?.peripheral.identifier {
                UserDefaults.standard.set(id.uuidString, forKey: G7TimedConnect.adoptedPeripheralKey)
            } else {
                UserDefaults.standard.removeObject(forKey: G7TimedConnect.adoptedPeripheralKey)
            }
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
#if os(iOS)
            self.centralManager = CBCentralManager(delegate: self, queue: managerQueue, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.loudnate.CGMBLEKit"])
#else
            // The watch host owns reconnect policy, so the watch central normally opts OUT of
            // state restoration. The system-held experiment (G7TimedConnect.systemHeld) opts in:
            // the watchOS 9+ SDK documents relaunching an app into the background to finish
            // Bluetooth work (willRestoreState + WKBluetoothAlertRefreshBackgroundTask), and
            // whether that wake is prompt enough for the sensor's window is the question.
            self.centralManager = CBCentralManager(delegate: self, queue: managerQueue,
                options: G7TimedConnect.systemHeld ? [CBCentralManagerOptionRestoreIdentifierKey: "com.loudnate.CGMBLEKit"] : nil)
#endif
        }
    }

    // MARK: - Actions

    // The public actions are fire-and-forget onto the manager queue (FIFO keeps callers'
    // ordering — e.g. disconnect → forget → scan). None of them needs a synchronous result, and
    // a synchronous hop from the main thread is what the 2026-09-12 watchdog kill was made of.
    func scanForPeripheral() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.async {
            self.managerQueue_scanForPeripheral()
        }
    }

    func forgetPeripheral() {
        managerQueue.async {
            self.activePeripheralManager = nil
        }
    }

    func stopScanning() {
        managerQueue.async {
            self.managerQueue_stopScanning()
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
        forceAcquireLock.lock(); _forceAcquireOnce = true; forceAcquireLock.unlock()
        managerQueue.async {
            let before = "peripheral=\(self.activePeripheral.map { "\($0.state.rawValue)" } ?? "none") adopted=\(self.activePeripheralIdentifier != nil) scanning=\(self.centralManager.isScanning)"
            Self.census("lab: RECONNECT requested by the user — forcing one acquisition pass (ride-only bypassed for this pass only) — before: \(before)")
            self.managerQueue_disconnect()
            // NOT an immediate re-issue: cancelPeripheralConnection is non-blocking and the #101
            // guard in handleDiscoveredPeripheral drops a re-issue while the peripheral still reads
            // `.connecting`. The 2 s settle lets the cancel resolve first.
            self.scanAfterDelay()
        }
    }

    func disconnect() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))
        managerQueue.async { self.managerQueue_disconnect() }
    }

    private func managerQueue_disconnect() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        if centralManager.isScanning {
            log.default("Stopping scan on disconnect")
            centralManager.stopScan()
            delegate?.bluetoothManagerScanningStatusDidChange(self)
        }

        if let peripheral = activePeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
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
            // timer issues. The user's own Reconnect is the exception — it used to be swallowed
            // here, which is why recovering adoption needed timed OFF → Reconnect → timed ON.
            if userForced {
                managerQueue_startTimedReacquirePass(reason: "user tapped Reconnect", scan: true)
            } else {
                managerQueue_armTimedConnect()
            }
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

            // DIRECT AUTH: there is no Dexcom app on the wrist to ride, so "wait for Dexcom's
            // next link" waits forever — on 2026-09-12 a relaunch sat in exactly this branch from
            // 13:41 until the user tapped Reconnect. Ride-only is dead once we do our own
            // handshake; acquisition is a scan, and in timed mode this is only ever reached
            // inside the one-shot re-acquire pass.
            if userForced || G7DirectAuth.enabled || G7RidePolicy.shouldScanToAcquire(rideOnly: Self.rideOnly) {
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

    // WATCHDOG KILL 2026-09-12 08:42 (0x8BADF00D, 10 s): the diagnostics page read these on the
    // MAIN thread inside a SwiftUI update, `managerQueue.sync` waited behind a direct-auth
    // handshake (blocking writes, up to 8 s each), and the BLE queue was itself waiting on
    // SwiftUI's lock — a lock inversion. The UI must never block on this queue: wait at most
    // 50 ms, otherwise hand back the last value the queue reported.
    private let readCacheLock = NSLock()
    private var readCache: [String: Bool] = [:]

    private func boundedRead(_ key: String, _ compute: @escaping () -> Bool) -> Bool {
        let done = DispatchSemaphore(value: 0)
        managerQueue.async { [weak self] in
            guard let self = self else { done.signal(); return }
            let value = compute()
            self.readCacheLock.lock(); self.readCache[key] = value; self.readCacheLock.unlock()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 0.05)
        readCacheLock.lock(); defer { readCacheLock.unlock() }
        return readCache[key] ?? false
    }

    var isScanning: Bool {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))
        return boundedRead("scanning") { [unowned self] in self.centralManager.isScanning }
    }

    var isConnected: Bool {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))
        return boundedRead("connected") { [unowned self] in self.activePeripheral?.state == .connected }
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

    // On the watch this fires only under the system-held experiment (the central opts into
    // restoration only then); the watchOS 26.5 SDK declares it alongside the restore keys.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            Self.census("RESTORED by the system — relaunched for Bluetooth with \(peripherals.count) peripheral(s): "
                        + peripherals.map { "\($0.name ?? "unnamed") state=\($0.state.rawValue)" }.joined(separator: ", "))
            for peripheral in peripherals {
                log.default("Restoring peripheral from state: %{public}@", peripheral.identifier.uuidString)
                handleDiscoveredPeripheral(peripheral)
                // An already-connected peripheral gets no second didConnect: run that path now so
                // the handshake starts on the link the system brought us back for.
                if peripheral.state == .connected { self.centralManager(central, didConnect: peripheral) }
            }
        }
    }

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
            timedLastConnectAt = Date()
            timedIssuedAt = nil
            timedMisses = 0
            if timedReacquirePass {
                timedReacquirePass = false
                timedReacquireTimer?.cancel(); timedReacquireTimer = nil
                if centralManager.isScanning { centralManager.stopScan(); delegate?.bluetoothManagerScanningStatusDidChange(self) }
                Self.census("timed: re-acquire pass CONNECTED — scan stopped; this reading anchors the grid")
            } else {
                // The latency after issue says where the burst is: ~0.05 s = already advertising
                // when we asked; ~1 s = it started that long after our fire.
                Self.census(String(format: "timed: didConnect at +%.2f s after issue", age))
            }
            if G7TimedConnect.systemHeld {
                timedSystemHeldLodged = false
                timedSystemHeldRefusals = 0
                Self.census(String(format: "timed[system-held]: link up %+.1f s after the scheduled start · %@", age, timedSleepSummary))
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
            guard let pin = G7DirectAuth.pin4(for: peripheral.name) else {
                // The user has not entered this sensor's pairing code yet (new sensor, or a
                // fresh install). Don't attempt a handshake we know will fail; say so where the
                // user looks. G7CGMManager clears the flag the moment a code arrives.
                G7DirectAuth.needsCodeFor = peripheral.name
                Self.census("[direct-auth] NO PAIRING CODE for \(peripheral.name ?? "sensor") — enter it in Loop ▸ Dexcom G7 on the phone (shown in the Dexcom app). Handshake skipped.")
                return
            }
            G7DirectAuth.needsCodeFor = nil
            let session = G7DirectAuthSession(peripheralManager: m, authChar: auth, dataChar: data,
                                              ctrlChar: ctrl, pin4: pin, slotByte: G7DirectAuth.slotByte,
                                              sensorName: peripheral.name, log: { Self.census($0) })
            self.directAuthSession = session
            self.directAuthLinkStartedAt = Date()
            Self.census("[direct-auth] starting handshake (\(pin.count)-digit pin, slot 0x\(String(format: "%02x", G7DirectAuth.slotByte)))")
            // HOLD OFF SUSPENSION for the handshake (2026-09-14). watchOS resumes a suspended app for
            // a Bluetooth link — measured twice on the system-held arm — but gives it ~1–2 s, and the
            // handshake needs ~6–8: every background handshake was cut off mid-round. This is the
            // documented way to ask for more: the block runs while the system holds the process,
            // and is called again with `expired = true` when the grant runs out. The grant length is
            // undocumented, so both edges are logged for the capture. Under the keepalive the block
            // just returns when the handshake settles; it costs nothing there.
            let hold = DispatchSemaphore(value: 0)
            let holdStarted = Date()
            DispatchQueue.global(qos: .userInitiated).async {
                ProcessInfo.processInfo.performExpiringActivity(withReason: "G7 direct-auth handshake") { expired in
                    if expired {
                        Self.census(String(format: "[direct-auth] suspension hold EXPIRED after %.1f s — the system is suspending us", Date().timeIntervalSince(holdStarted)))
                        return
                    }
                    Self.census("[direct-auth] suspension hold GRANTED — holding the process until the handshake settles (20 s cap)")
                    let outcome = hold.wait(timeout: .now() + 20)
                    Self.census(String(format: "[direct-auth] suspension hold released after %.1f s (%@)", Date().timeIntervalSince(holdStarted), outcome == .success ? "handshake settled" : "cap"))
                }
            }
            Task {
                let r = await session.run()
                hold.signal()
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
        // This is the disconnect the bounded cancel itself produced and a second ask is already
        // scheduled: leave its timer alone. Re-arming here cancelled it every time (2026-09-13).
        if timedSecondAskPending {
            timedSecondAskPending = false
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
            if G7TimedConnect.systemHeld, timedSystemHeldLodged {
                // The daemon answered the LODGED request itself. An immediate refusal — within a
                // second or two of the call, "One or more parameters were invalid" — is the
                // platform declining the start-delay option, and it must never be re-lodged
                // synchronously (2026-09-14 08:58: 26,558 spins in one wake). Two refusals in a
                // launch disable the arm; a LATE failure (the request went live and could not
                // connect) re-lodges for the next grid point through the ordinary miss path.
                timedSystemHeldLodged = false
                timedCancelTimer?.cancel(); timedCancelTimer = nil
                timedIssuedAt = nil
                let sinceLodge = timedSystemHeldLodgedAt.map { Date().timeIntervalSince($0) } ?? -1
                let code = (error as NSError?).map { "\($0.domain)#\($0.code) \($0.localizedDescription)" } ?? "no error"
                if sinceLodge < 2 {
                    timedSystemHeldRefusals += 1
                    Self.census(String(format: "timed[system-held]: REFUSED by the daemon %.2f s after lodging — %@ (%d of 2)", sinceLodge, code, timedSystemHeldRefusals))
                    if timedSystemHeldRefusals >= 2 {
                        timedSystemHeldDisabled = true
                        Self.census("timed[system-held]: arm DISABLED for this launch — the platform declines the start-delay option; back to our own timer under the keepalive")
                        managerQueue_armTimedConnect()
                        return
                    }
                    let t = DispatchSource.makeTimerSource(queue: managerQueue)
                    t.schedule(deadline: .now() + 30)
                    t.setEventHandler { [weak self] in self?.managerQueue_armTimedConnect() }
                    t.resume()
                    timedFireTimer = t
                    Self.census("timed[system-held]: one more lodge in 30 s, then the arm stands down")
                    return
                }
                Self.census(String(format: "timed[system-held]: request failed %.0f s after lodging — %@; re-lodging for the next grid point", sinceLodge, code))
                managerQueue_timedNoteMissAndRearm()
                return
            }
            timedCancelTimer?.cancel(); timedCancelTimer = nil
            timedSystemHeldLodged = false
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
/// watch reads glucose with no Dexcom app present. Default ON on watchOS since 2026-09-13; the
/// per-sensor pairing code is entered once on the phone and rides to the watch in the context.
public enum G7DirectAuth {
    public static let key = "G7Lab.directAuth"
    /// Per-sensor pairing codes keyed by sensor name (DXCM…): the BLE layer's mirror of
    /// G7CGMManagerState.directAuthPins, installed by G7CGMManager (which also carries them
    /// phone→watch inside the context's cgmManagerState). A code only ever works with its own
    /// sensor, so old entries are harmless and kept.
    public static let pinsKey = "G7Lab.directAuth.pins"
    /// Pre-2026-09-12 single code; G7CGMManager migrates it to `pins[current sensor]` once.
    public static let legacyPinKey = "G7Lab.directAuth.pin"
    /// Set when a connect reached a sensor we have no code for; cleared as soon as one exists.
    /// Surfaced by the glance and the diagnostics screen — the user's cue to enter it on the phone.
    public static let needsCodeKey = "G7Lab.directAuth.needsCode"
    public static let slotByte: UInt8 = 0x01   // concurrent slot, proven to coexist with a phone (auth=1)
    /// FAST PATH (2026-09-14): after one full handshake per sensor the derived shared key is
    /// stored and later connections replay only the AES challenge (no J-PAKE, no certificate
    /// exchange) — Juggluco's once-per-bond behaviour; ~1.2 s instead of 7.0. ON by default;
    /// the key is the diagnostic kill switch. A rejected challenge clears the stored key.
    public static let fastPathKey = "G7Lab.directAuth.fastPath"
    public static var fastPath: Bool {
        if let v = UserDefaults.standard.object(forKey: fastPathKey) as? Bool { return v }
        return true
    }
    /// WATCH: ON by default since 2026-09-13 — the watch reads the sensor with its own handshake
    /// (no Dexcom watch app). PHONE: OFF — the phone keeps stock acquisition. The key remains a
    /// diagnostic override on the watch's diagnostics screen.
    public static var enabled: Bool {
        if let v = UserDefaults.standard.object(forKey: key) as? Bool { return v }
        #if os(watchOS)
        return true
        #else
        return false
        #endif
    }

    public static var pins: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: pinsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: pinsKey) }
    }

    /// The 4 ASCII digits for this sensor, or nil if the user has not entered its code yet.
    public static func pin4(for sensorName: String?) -> [UInt8]? {
        guard let name = sensorName, let code = pins[name] else { return nil }
        let digits = String(code.filter { $0.isNumber }.prefix(4))
        return digits.count == 4 ? Array(digits.utf8) : nil
    }

    public static var needsCodeFor: String? {
        get { UserDefaults.standard.string(forKey: needsCodeKey) }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: needsCodeKey) }
            else { UserDefaults.standard.removeObject(forKey: needsCodeKey) }
        }
    }

    /// One-line glance note while a code is missing; nil otherwise.
    public static var needsCodeNote: String? {
        needsCodeFor.map { "Sensor code needed for \($0) — enter it in Loop ▸ Dexcom G7 on the phone (it is shown in the Dexcom app)." }
    }
}

public enum G7TimedConnect {
    public static let key = "G7Lab.timedConnect"
    public static let anchorKey = "G7Lab.timedConnect.anchor"
    /// The sensor's cadence on ITS OWN clock: reading timestamps sit on an exact 300.000-s grid
    /// (14:01:38.6 → 14:06:38.7 on 2026-09-12; crystal drift ≈ 4 s/day against wall clock).
    public static let period: TimeInterval = 300
    /// Issue the connect this long AFTER the grid point. The anchor is the last reading's own
    /// timestamp and the sensor starts advertising +2.0…+3.2 s after it (61 cycles on
    /// 2026-09-12: +2.0–2.2 with no phone, +2.7–3.2 with the phone collecting). Being LATE is
    /// free — a request placed mid-burst completes in ~0.03 s — while every second before the
    /// burst is window wasted, so the request goes up AT the burst start and the whole 5-s bound
    /// sits inside it (burst +0…+5 s). +1 gave only 3–4 s of overlap and 4 misses in 61.
    /// Anchoring on our CONNECT time instead walked the window 1.2 s later every cycle.
    public static let fireOffset: TimeInterval = 3
    /// Withdraw a still-pending request this long after issuing it (< the daemon's 6-s fast scan).
    public static let bound: TimeInterval = 5
    /// SECOND ASK (2026-09-13): a grid request that heard nothing for the whole bound is withdrawn
    /// and, this long later, asked ONCE more with the same bound — burst +5.5…+10.5 s. Misses
    /// cluster in departures, where the sensor advertises 25–30 s, so the second window has adverts
    /// to catch. Exposure: at most one COUNT per miss if the sensor refuses and the link dies —
    /// never the −70 floor, which needs a failure > 6 s after its request and every request of
    /// ours is withdrawn before that. Preregistered: the count in the next capture is the verdict.
    public static let secondAskDelay: TimeInterval = 0.5
    /// WATCH: ON by default since 2026-09-13 — one bounded request per burst is how the watch
    /// acquires. PHONE: OFF (stock). The key remains a diagnostic override on the watch.
    public static var enabled: Bool {
        if let v = UserDefaults.standard.object(forKey: key) as? Bool { return v }
        #if os(watchOS)
        return true
        #else
        return false
        #endif
    }
    /// Does the app currently have background runtime (a keepalive holder: a loan, or E1)?
    /// The watch app installs this. nil = assume yes (iOS, tests). With no runtime a suspended
    /// app cannot honour the 5-s bound — on 2026-09-12 its timers fired +234…+468 s late and a
    /// request the app believed it had withdrawn had in fact been served and closed minutes
    /// earlier — so timed fires stand down until a holder exists, and re-arm when one appears.
    public static var runtimeAvailable: (() -> Bool)?
    static var hasRuntime: Bool { runtimeAvailable?() ?? true }
    /// EXPERIMENT (2026-09-13, Pete's suggestion): lodge each grid request with the daemon via
    /// CBConnectPeripheralOptionStartDelayKey instead of firing it from our own timer, and opt the
    /// watch central into state restoration so the system may relaunch us for the link. No
    /// keepalive needed by design — that is what it tests. Default OFF; the central is created
    /// once, so flipping it needs an app relaunch.
    public static let systemHeldKey = "G7Lab.timedConnect.systemHeld"
    public static var systemHeld: Bool { UserDefaults.standard.bool(forKey: systemHeldKey) }
    /// STANDING request (2026-09-14): under the arm, lodge the connect with NO start delay, so the
    /// sensor's address sits in the controller's accept list from the moment of our disconnect
    /// and the radio connects at the sensor's very next advertisement. The delayed form depends
    /// on a timer inside bluetoothd that the event run showed is only checked when the daemon's
    /// scan manager re-evaluates for some other client — 5–20 min late with the app asleep. The
    /// price is the one the timed design was built to avoid: a request standing through the
    /// sensor's tail can fail at low RSSI and count toward the daemon's per-device tally. That
    /// risk is accepted for this arm (Jeremy, 2026-09-14) and measured. ON by default under the
    /// arm; OFF restores the start-delay form.
    public static let standingKey = "G7Lab.timedConnect.standing"
    public static var standing: Bool {
        if let v = UserDefaults.standard.object(forKey: standingKey) as? Bool { return v }
        return true
    }
    /// The adopted peripheral's CoreBluetooth identifier, remembered so the system-held arm can
    /// re-adopt it at launch without a scan (cleared when the peripheral is forgotten).
    public static let adoptedPeripheralKey = "G7Lab.timedConnect.adoptedPeripheral"
    /// Pure, pinned by WatchAppTests: the next grid-aligned fire time strictly after `now + margin`.
    /// Grid point n fires at anchor + n·period + fireOffset, where `anchor` is a reading's own
    /// sensor timestamp. Every reading re-anchors, so wall-clock drift never accumulates.
    public static func nextFire(anchor: Date, now: Date, margin: TimeInterval = 1) -> Date {
        var n = floor(now.timeIntervalSince(anchor) / period)
        var t = anchor.addingTimeInterval(n * period + fireOffset)
        while t <= now.addingTimeInterval(margin) { n += 1; t = anchor.addingTimeInterval(n * period + fireOffset) }
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
