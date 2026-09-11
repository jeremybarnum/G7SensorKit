//
//  G7DirectAuthStreams.swift
//  G7SensorKit
//
//  Async inbound channels for the direct-auth handshake, ported verbatim from the proven
//  G7watchOS client. Fed by G7BluetoothManager's single CBPeripheralDelegate (didUpdateValueFor)
//  when a G7DirectAuthSession is active — so there is exactly one Bluetooth stack, and the
//  two-delegates-one-link collision that sank the earlier attempt (bc3c0978) cannot recur.
//
//  - G7DAByteStream: byte-accumulating channel for the data (3538) characteristic; recv(n)
//    yields the next n bytes across 20-byte notifications.
//  - G7DAMessageStream: message channel for auth (3535) / control (3534); each notification is
//    one discrete message; recv(op:) returns the next, optionally skipping non-matching opcodes.
//

import Foundation

enum G7DirectAuthError: Error, CustomStringConvertible {
    case timeout(String)
    case disconnected
    case cryptoFailed(String)
    case aesVerifyFailed
    case unexpectedAuth(Int)
    case setup(String)

    var description: String {
        switch self {
        case .timeout(let w):        return "timeout waiting for \(w)"
        case .disconnected:          return "peripheral disconnected"
        case .cryptoFailed(let s):   return "crypto failed: \(s)"
        case .aesVerifyFailed:       return "AES challenge verify BAD (dropped chunk?)"
        case .unexpectedAuth(let a): return "auth=\(a) unexpected (not authenticated)"
        case .setup(let s):          return "setup: \(s)"
        }
    }
}

func g7authHex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

final class G7DAByteStream: @unchecked Sendable {
    private let q: DispatchQueue
    private var buffer: [UInt8] = []
    private var closed = false
    private var pending: (need: Int, id: Int, cont: CheckedContinuation<[UInt8], Error>)?
    private var nextId = 0

    init(label: String) { q = DispatchQueue(label: label) }

    func append(_ bytes: [UInt8]) { q.async { self.buffer.append(contentsOf: bytes); self.tryResolve() } }
    func close() { q.async { self.closed = true; if let p = self.pending { self.pending = nil; p.cont.resume(throwing: G7DirectAuthError.disconnected) } } }

    private func tryResolve() {
        guard let p = pending, buffer.count >= p.need else { return }
        let out = Array(buffer.prefix(p.need))
        buffer.removeFirst(p.need)
        pending = nil
        p.cont.resume(returning: out)
    }

    func recv(_ n: Int, timeout: TimeInterval) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { cont in
            q.async {
                if self.closed { cont.resume(throwing: G7DirectAuthError.disconnected); return }
                let id = self.nextId; self.nextId += 1
                self.pending = (n, id, cont)
                self.q.asyncAfter(deadline: .now() + timeout) {
                    if let p = self.pending, p.id == id { self.pending = nil; p.cont.resume(throwing: G7DirectAuthError.timeout("\(n) data bytes")) }
                }
                self.tryResolve()
            }
        }
    }
}

final class G7DAMessageStream: @unchecked Sendable {
    private let q: DispatchQueue
    private let name: String
    private var messages: [[UInt8]] = []
    private var closed = false
    private var pending: (op: UInt8?, id: Int, cont: CheckedContinuation<[UInt8], Error>)?
    private var nextId = 0
    var onSkip: ((String) -> Void)?

    init(label: String, name: String) { q = DispatchQueue(label: label); self.name = name }

    func append(_ msg: [UInt8]) { q.async { self.messages.append(msg); self.tryResolve() } }
    func close() { q.async { self.closed = true; if let p = self.pending { self.pending = nil; p.cont.resume(throwing: G7DirectAuthError.disconnected) } } }

    private func tryResolve() {
        guard let p = pending else { return }
        while !messages.isEmpty {
            let m = messages.removeFirst()
            if p.op == nil || m.first == p.op {
                pending = nil
                p.cont.resume(returning: m)
                return
            } else {
                onSkip?("(skip \(name) \(g7authHex(m)))")
            }
        }
    }

    func recv(op: UInt8? = nil, timeout: TimeInterval) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { cont in
            q.async {
                if self.closed { cont.resume(throwing: G7DirectAuthError.disconnected); return }
                let id = self.nextId; self.nextId += 1
                self.pending = (op, id, cont)
                let what = op.map { String(format: "%@ op 0x%02x", self.name, $0) } ?? "\(self.name) msg"
                self.q.asyncAfter(deadline: .now() + timeout) {
                    if let p = self.pending, p.id == id { self.pending = nil; p.cont.resume(throwing: G7DirectAuthError.timeout(what)) }
                }
                self.tryResolve()
            }
        }
    }
}
