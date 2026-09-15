//
//  G7AuthCrypto.swift
//  G7SensorKit
//
//  Thin Swift bridge over the prebuilt C library libg7auth (header g7auth.h, vendored
//  beside this file and exposed to the framework module via the umbrella header). This
//  is the ported Juggluco/OpenSSL Dexcom G7 J-PAKE + ECDSA + AES crypto, statically
//  linked from libg7auth.xcframework over openssl.xcframework. It carries NO Bluetooth or
//  session logic — just the math the direct-auth handshake needs. See G7DirectAuthSession
//  for the sequencer that drives it over the sensor's GATT characteristics.
//
//  Provenance: ~/Downloads/Loop/G7Watch/G7watchOS (proven standalone on the SE 3, auth=1,
//  no Dexcom app, phone BT off). Ported verbatim; the on-wire byte flow is identical.
//

import Foundation
import CommonCrypto

enum G7AuthCrypto {
    /// Initialize with the 4-digit pairing code as ASCII bytes (e.g. [0x39,0x31,0x35,0x31]
    /// for "9151"). Loads the embedded partner certs. Returns true if keys + pin are valid.
    /// Call once per session before the J-PAKE rounds.
    @discardableResult
    static func initPIN(_ pin4: [UInt8]) -> Bool {
        precondition(pin4.count == 4, "pin must be 4 ASCII digits")
        return pin4.withUnsafeBufferPointer { g7_init($0.baseAddress) } == 1
    }

    /// J-PAKE round 1/2 output (which = 0 or 1): 160 bytes.
    static func round12(_ which: Int32) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 160)
        out.withUnsafeMutableBufferPointer { _ = g7_round12(which, $0.baseAddress) }
        return out
    }

    /// Feed the sensor's 160-byte round payload (which 0,1,2). Returns true if the sensor's
    /// ZKP validates (which<2) / the shared key derives (which==2).
    @discardableResult
    static func putPubkey(_ which: Int32, _ in160: [UInt8]) -> Bool {
        in160.withUnsafeBufferPointer { g7_put_pubkey(which, $0.baseAddress) } == 1
    }

    /// J-PAKE round 3 output: 160 bytes (nil if the C side reports failure).
    static func round3() -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: 160)
        let ok = out.withUnsafeMutableBufferPointer { g7_round3($0.baseAddress) } == 1
        return ok ? out : nil
    }

    /// ECDSA-P256 proof-of-possession signature over `data`: 64 bytes (r||s).
    static func challenge(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 64)
        data.withUnsafeBufferPointer { inp in
            out.withUnsafeMutableBufferPointer { o in
                _ = g7_challenge(inp.baseAddress, Int32(data.count), o.baseAddress)
            }
        }
        return out
    }

    /// AES-8 over the derived J-PAKE shared key: input 8 bytes -> output 8 bytes.
    static func aes8(_ data8: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 8)
        data8.withUnsafeBufferPointer { inp in
            out.withUnsafeMutableBufferPointer { o in
                _ = g7_aes8(inp.baseAddress, o.baseAddress)
            }
        }
        return out
    }

    /// The 16-byte shared key the last completed J-PAKE derived (all zeros if none has).
    static func sharedKey() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        out.withUnsafeMutableBufferPointer { _ = g7_shared($0.baseAddress) }
        return out
    }

    /// AES-8 under an EXPLICIT key, in Swift: the C side's encrypt8AES verbatim — the 8 bytes
    /// doubled into one 16-byte block, AES-128-ECB, first 8 bytes out. This is what lets a
    /// later connection replay the AES challenge from a stored key without a J-PAKE having run
    /// in this process. Checked against the C result after every full handshake before a key
    /// is ever stored (see G7DirectAuthSession).
    static func aes8(_ data8: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(data8.count == 8 && key.count == 16)
        let block = aesBlock(data8 + data8, key: key)
        return Array(block.prefix(8))
    }

    /// One AES-128-ECB block (16 bytes in, 16 out). Pinned by WatchAppTests against FIPS-197.
    static func aesBlock(_ block16: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(block16.count == 16 && key.count == 16)
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = key.withUnsafeBytes { k in
            block16.withUnsafeBytes { inp in
                out.withUnsafeMutableBytes { o in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            k.baseAddress, kCCKeySizeAES128, nil,
                            inp.baseAddress, 16, o.baseAddress, 16, &moved)
                }
            }
        }
        precondition(status == kCCSuccess && moved == 16, "AES-128-ECB block failed: \(status)")
        return out
    }

    // Nonces (fixed, matching the proven client).
    static let RAND8:  [UInt8] = Array(0x11...0x18)  // AES-auth nonce
    static let RAND16: [UInt8] = Array(0x21...0x30)  // proof-of-possession nonce

    /// The two embedded partner certs, exchanged during the 0x0B step.
    static let certs: [[UInt8]] = [G7AuthCerts.CERT0, G7AuthCerts.CERT1]

    /// Smoke test that the static crypto links and initializes against the embedded certs.
    /// Returns true if g7_init accepts the pin — proves the whole libg7auth+openssl link.
    static func selfTestLinks(pin4: [UInt8] = [0x39, 0x31, 0x35, 0x31]) -> Bool {
        return initPIN(pin4)
    }
}

/// Per-sensor store of the J-PAKE shared key, so the next connection to a sensor we have
/// already bonded can take the fast path. Juggluco keeps the same 16 bytes in the sensor's
/// persistent record and skips J-PAKE whenever they are non-zero. A key only ever matches
/// its own sensor; a mismatch at the AES challenge clears it and the full handshake runs.
enum G7DirectAuthKeyStore {
    static let prefix = "G7Lab.directAuth.sharedKey."

    static func load(for sensorName: String, defaults: UserDefaults = .standard) -> [UInt8]? {
        guard let hex = defaults.string(forKey: prefix + sensorName), hex.count == 32 else { return nil }
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out.contains(where: { $0 != 0 }) ? out : nil
    }

    static func save(_ key: [UInt8], for sensorName: String, defaults: UserDefaults = .standard) {
        guard key.count == 16, key.contains(where: { $0 != 0 }) else { return }
        defaults.set(key.map { String(format: "%02x", $0) }.joined(), forKey: prefix + sensorName)
    }

    static func clear(for sensorName: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: prefix + sensorName)
    }
}
