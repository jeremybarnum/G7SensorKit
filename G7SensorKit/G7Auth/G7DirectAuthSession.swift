//
//  G7DirectAuthSession.swift
//  G7SensorKit
//
//  The direct-auth handshake sequencer — our OWN J-PAKE authentication to the Dexcom G7,
//  ported faithfully from the proven G7watchOS client (SE 3: auth=1, live glucose, no Dexcom
//  app, phone BT off). The on-wire byte flow is verbatim; only the transport changed: instead
//  of raw CoreBluetooth it drives G7SensorKit's own G7PeripheralManager (perform/writeValue/
//  setNotifyValue) and is fed inbound notifications by G7BluetoothManager's single CB delegate.
//  One Bluetooth stack — the two-delegate collision (bc3c0978) cannot recur.
//
//  Sequence: subscribe data(3538) + auth(3535) → J-PAKE rounds 0/1/2 → AES auth (02/03/04/05)
//  → cert exchange (0B) + PoP (0C) + authStatus (0D) → KeepAlive (06 19) → bond gate (06 …) →
//  glucose read (4E) on control(3534). The AES-auth slot byte defaults to 0x01, the concurrent
//  slot proven to coexist with an active phone (auth=1).
//
//  The watch's production acquisition path since 2026-09-13 (G7DirectAuth.enabled, default ON on
//  watchOS); Diagnostics ▸ Sensor ▸ Authentication is the override. The fast path (stored shared
//  key, AES challenge only) is unconditional.
//

import Foundation
import CoreBluetooth

struct G7DirectAuthResult {
    var authByte: Int?
    var bondByte: Int?
    var glucose: Int?
    var state: UInt8?
    var deviceListHex: String?
    var error: String?
    /// The raw control notification (opcode 0x4E first) — forwarded verbatim into the stock
    /// didReceiveControlResponse path so Loop parses and ingests it exactly as a Dexcom-authed read.
    var egvRaw: [UInt8]?
    var authenticated: Bool { authByte == 1 || authByte == 2 }
}

final class G7DirectAuthSession: @unchecked Sendable {
    private weak var pm: G7PeripheralManager?
    private let authChar: CBCharacteristic
    private let dataChar: CBCharacteristic
    private let ctrlChar: CBCharacteristic
    private let pin4: [UInt8]
    private let slotByte: UInt8
    private let log: (String) -> Void
    /// The sensor's advertised name (DXCM…), the key under which its shared key is stored.
    private let sensorName: String?
    /// Set when this run authenticated from a stored key (no J-PAKE, no certificates).
    private(set) var usedFastPath = false

    private let authStream = G7DAMessageStream(label: "g7da.auth", name: "auth")
    private let dataStream = G7DAByteStream(label: "g7da.data")
    private let ctrlStream = G7DAMessageStream(label: "g7da.control", name: "control")

    private let opTimeout: TimeInterval = 8.0
    private let recvTimeout: TimeInterval = 12.0
    private let chunkGap: UInt64 = 50_000_000   // 50 ms between 20-byte data chunks
    private let chunkTail: UInt64 = 120_000_000 // settle after the last chunk

    /// True once auth completes — control notifications route back to the stock glucose parser.
    private(set) var authComplete = false

    init(peripheralManager: G7PeripheralManager,
         authChar: CBCharacteristic, dataChar: CBCharacteristic, ctrlChar: CBCharacteristic,
         pin4: [UInt8], slotByte: UInt8 = 0x01, sensorName: String? = nil, log: @escaping (String) -> Void) {
        self.pm = peripheralManager
        self.authChar = authChar; self.dataChar = dataChar; self.ctrlChar = ctrlChar
        self.pin4 = pin4; self.slotByte = slotByte; self.sensorName = sensorName; self.log = log
        authStream.onSkip = { log("[direct-auth] \($0)") }
        ctrlStream.onSkip = { log("[direct-auth] \($0)") }
    }

    /// Route an inbound notification (from G7BluetoothManager's delegate) into the right channel.
    /// Returns true if this session consumed it (caller should NOT run the stock path).
    func feed(_ uuid: CBUUID, _ value: Data) -> Bool {
        let bytes = [UInt8](value)
        switch uuid {
        case dataChar.uuid: dataStream.append(bytes); return true
        case authChar.uuid: authStream.append(bytes); return true
        case ctrlChar.uuid:
            // During the handshake we own control; once authenticated, hand glucose back to stock.
            if authComplete { return false }
            ctrlStream.append(bytes); return true
        default: return false
        }
    }

    func cancel() { authStream.close(); dataStream.close(); ctrlStream.close() }

    // MARK: transport bridges over G7PeripheralManager (single delegate)

    private func write(_ char: CBCharacteristic, _ bytes: [UInt8], response: Bool) async throws {
        guard let pm = pm else { throw G7DirectAuthError.disconnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pm.perform { m in
                do { try m.writeValue(Data(bytes), for: char, type: response ? .withResponse : .withoutResponse, timeout: self.opTimeout); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func setNotify(_ char: CBCharacteristic) async throws {
        guard let pm = pm else { throw G7DirectAuthError.disconnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pm.perform { m in
                do { try m.setNotifyValue(true, for: char, timeout: self.opTimeout); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Bulk write to data(3538) in 20-byte withoutResponse chunks (3538 rejects with-response).
    ///
    /// ROOT CAUSE FIX (2026-09-11): withoutResponse writes are silently DROPPED by CoreBluetooth
    /// when the peripheral's buffer is full, and fire-and-forget chunking lost ~1 in 4 handshakes
    /// (sensor rejected our round after a short payload, or the derived key mismatched). Gate each
    /// chunk on `canSendWriteWithoutResponse` — the proper way — so a chunk is only sent when the
    /// stack will actually deliver it.
    private func writeDataChunks(_ payload: [UInt8]) async throws {
        var i = 0
        while i < payload.count {
            let end = min(i + 20, payload.count)
            await waitUntilCanSendWithoutResponse()
            try await write(dataChar, Array(payload[i..<end]), response: false)
            try? await Task.sleep(nanoseconds: chunkGap)
            i += 20
        }
        try? await Task.sleep(nanoseconds: chunkTail)
    }

    /// Poll the peripheral's without-response readiness (10 ms steps, 500 ms cap). Falls through
    /// on the cap so a stuck flag cannot hang the handshake — the sensor's own timeout bounds it.
    private func waitUntilCanSendWithoutResponse() async {
        guard let peripheral = dataChar.service?.peripheral else { return }
        var waited: UInt64 = 0
        while !peripheral.canSendWriteWithoutResponse, waited < 500_000_000 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 10_000_000
        }
        if waited > 0 { log("[direct-auth] chunk gated \(waited / 1_000_000) ms on canSendWriteWithoutResponse") }
    }

    // MARK: the handshake (byte flow verbatim from the proven client)

    func run() async -> G7DirectAuthResult {
        var result = G7DirectAuthResult()
        do {
            guard G7AuthCrypto.initPIN(pin4) else { throw G7DirectAuthError.cryptoFailed("g7_init (pin/cert)") }
            log("[direct-auth] crypto initialized (slot 0x\(String(format: "%02x", slotByte)))")

            try await setNotify(dataChar)
            try await setNotify(authChar)
            log("[direct-auth] subscribed 3538 notify, 3535 indicate")

            // FAST PATH (2026-09-14, from Juggluco's DexGattCallback: J-PAKE and the certificate
            // exchange are once per bond; a later connection replays the AES challenge under the
            // stored shared key and reads). 7.0 s → ~1.2 s. A mismatch clears the key and the
            // full handshake runs on this same link.
            var fastDone = false
            if let name = sensorName, let stored = G7DirectAuthKeyStore.load(for: name) {
                let started = Date()
                log("[direct-auth] FAST PATH — stored key for \(name): AES challenge only, no J-PAKE, no certs")
                do {
                    let (a, b) = try await doAesAuth { G7AuthCrypto.aes8($0, key: stored) }
                    log(String(format: "[direct-auth] *** statusReply auth=%d bond=%d *** (fast path, %.2f s)", a, b, Date().timeIntervalSince(started)))
                    guard a == 1 || a == 2 else { throw G7DirectAuthError.unexpectedAuth(a) }
                    result.authByte = a; result.bondByte = b
                    fastDone = true
                    usedFastPath = true
                } catch let error as G7DirectAuthError where error.isAesRejection {
                    // The sensor answered and refused the challenge: the key is wrong for it.
                    G7DirectAuthKeyStore.clear(for: name)
                    log("[direct-auth] fast path REJECTED (\(error)) — stored key cleared, full handshake on this link")
                } catch {
                    // A timeout, a dropped link or a notReady write is the WATCH, not the key.
                    // Clearing here forced a full J-PAKE on the next burst, whose round-0 took
                    // 1–5 s to send on the sleeping watch, the sensor hung up at ~3.5 s, and the
                    // cascade began (58 of 77 handshakes, 2026-09-16). The key stays.
                    log("[direct-auth] fast path did not complete (\(error)) — key kept; full handshake on this link")
                }
            }

            if !fastDone {
                try await doJPake()
                log("[direct-auth] J-PAKE complete")

                let (a, b) = try await doAesAuth()
                result.authByte = a; result.bondByte = b
                log("[direct-auth] *** statusReply auth=\(a) bond=\(b) ***")
                guard a == 1 || a == 2 else { throw G7DirectAuthError.unexpectedAuth(a) }

                do {
                    try await doCerts()
                    try await write(authChar, [0x06, 0x19], response: true)
                    let gate = try await authStream.recv(op: 0x06, timeout: recvTimeout)
                    log("[direct-auth] *** BOND-READY gate \(g7authHex(gate)) (bond=\(b)) ***")
                } catch {
                    log("[direct-auth] cert/gate step: \(error) — proceeding to glucose")
                }
            }

            // A failed read after a successful fast auth ("encryption never established", a
            // timeout, notReady) is the link or the watch, not the key: the sensor accepted the
            // challenge. The key stays — see the fast-path catch above for what clearing it cost.
            let egv = try await readEGV()

            // Bank the key for the next connection — only after a read succeeded on it, and only
            // if the Swift AES-8 reproduces the C side's answer under the exported key, so a
            // stored key can never be one the sensor would refuse for our own arithmetic.
            if !fastDone, let name = sensorName {
                let key = G7AuthCrypto.sharedKey()
                let swift = G7AuthCrypto.aes8(G7AuthCrypto.RAND8, key: key)
                let c = G7AuthCrypto.aes8(G7AuthCrypto.RAND8)
                if key.contains(where: { $0 != 0 }), swift == c {
                    G7DirectAuthKeyStore.save(key, for: name)
                    log("[direct-auth] shared key STORED for \(name) (Swift AES-8 == C AES-8) — next connection takes the fast path")
                } else {
                    log("[direct-auth] shared key NOT stored for \(name): \(key.contains(where: { $0 != 0 }) ? "Swift AES-8 != C AES-8" : "key is all zeros")")
                }
            }
            result.egvRaw = egv
            let rawEGV: Int = egv.count >= 14 ? Int(egv[12]) | (Int(egv[13]) << 8) : 0xffff
            result.glucose = rawEGV == 0xffff ? nil : (rawEGV & 0x0fff)
            result.state = egv.count >= 15 ? egv[14] : nil
            log("[direct-auth] *** GLUCOSE = \(result.glucose.map { "\($0)" } ?? "nil") mg/dL  state=0x\(String(format: "%02x", Int(result.state ?? 0))) ***")

            authComplete = true
        } catch {
            result.error = "\(error)"
            log("[direct-auth] *** FAILED: \(error) ***")
        }
        return result
    }

    // J-PAKE — for w in 0,1,2: write [0x0A,w] to auth, recv 160 on data, feed it, send our 160.
    private func doJPake() async throws {
        for w in Int32(0)...Int32(2) {
            // Per-round timing (2026-09-14 21:11: three attempts in one burst were dropped by the
            // sensor ~3.5 s after the last round it answered; which leg was slow was invisible).
            let t0 = Date()
            try await write(authChar, [0x0A, UInt8(w)], response: true)
            let tAsk = Date()
            let sensor160 = try await dataStream.recv(160, timeout: recvTimeout)
            let tGot = Date()
            let ok = G7AuthCrypto.putPubkey(w, sensor160)
            let ours: [UInt8]
            if w < 2 { ours = G7AuthCrypto.round12(w) }
            else { guard let r3 = G7AuthCrypto.round3() else { throw G7DirectAuthError.cryptoFailed("g7_round3") }; ours = r3 }
            try await writeDataChunks(ours)
            let tSent = Date()
            log(String(format: "[direct-auth] round%d putk=%@ · ask acked %.0f ms · sensor 160 B +%.0f ms · ours sent +%.0f ms", w, ok ? "true" : "false",
                       tAsk.timeIntervalSince(t0) * 1000, tGot.timeIntervalSince(tAsk) * 1000, tSent.timeIntervalSince(tGot) * 1000))
        }
    }

    // AES auth: [0x02]+RAND8+[slot]; recv [0x03]+X8+Y8; verify aes8(RAND8)==X8; [0x04]+aes8(Y8); recv [0x05,auth,bond].
    /// `aes` is the AES-8 to use: the C side's (under the key J-PAKE just derived) by default,
    /// or the Swift one under a stored key on the fast path.
    private func doAesAuth(aes: ([UInt8]) -> [UInt8] = { G7AuthCrypto.aes8($0) }) async throws -> (Int, Int) {
        try await write(authChar, [0x02] + G7AuthCrypto.RAND8 + [slotByte], response: true)
        let resp = try await authStream.recv(op: 0x03, timeout: recvTimeout)
        let x8 = Array(resp[1..<9]); let y8 = Array(resp[9..<17])
        guard aes(G7AuthCrypto.RAND8) == x8 else { throw G7DirectAuthError.aesVerifyFailed }
        try await write(authChar, [0x04] + aes(y8), response: true)
        let st = try await authStream.recv(op: 0x05, timeout: recvTimeout)
        return (Int(st[1]), Int(st[2]))
    }

    // Cert exchange (0B ×2) + proof-of-possession (0C) + authStatus (0D).
    private func doCerts() async throws {
        for idx in 0...1 {
            let cert = G7AuthCrypto.certs[idx]
            let n = UInt32(cert.count)
            let lenLE = [UInt8(n & 0xff), UInt8((n >> 8) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 24) & 0xff)]
            try await write(authChar, [0x0B, UInt8(idx)] + lenLE, response: true)
            let cs = try await authStream.recv(op: 0x0B, timeout: recvTimeout)
            let size = Int(cs[3]) | (Int(cs[4]) << 8)
            _ = try await dataStream.recv(size, timeout: recvTimeout)   // sensor cert (unused)
            try await writeDataChunks(cert)
            log("[direct-auth] cert\(idx) exchanged (sensor cert \(size) bytes)")
        }
        try await write(authChar, [0x0C] + G7AuthCrypto.RAND16, response: true)
        _ = try await dataStream.recv(64, timeout: recvTimeout)
        let pc = try await authStream.recv(op: 0x0C, timeout: recvTimeout)
        try await writeDataChunks(G7AuthCrypto.challenge(pc))
        log("[direct-auth] PoP sig sent (challenge \(pc.count) bytes)")
        try await write(authChar, [0x0D, 0x00, 0x02], response: true)
        _ = try? await authStream.recv(timeout: 6.0)
    }

    // Glucose read on control(3534): subscribe, write [0x4E], parse the notification. The control
    // char requires an encrypted link; CoreBluetooth auto-initiates SMP pairing on first touch, so
    // retry while "Encryption is insufficient" resolves.
    private func readEGV() async throws -> [UInt8] {
        for attempt in 1...8 {
            do {
                try await setNotify(ctrlChar)
                try await write(ctrlChar, [0x4E], response: true)
                // Filter on the glucose opcode: stock may write extendedVersionTx (0x52) to
                // control after a read, and its 0x53 reply must not be mistaken for the EGV.
                return try await ctrlStream.recv(op: 0x4E, timeout: recvTimeout)
            } catch {
                log("[direct-auth] glucose attempt \(attempt): \(error) — waiting for pairing/encryption")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        throw G7DirectAuthError.timeout("glucose read — encryption never established")
    }
}
