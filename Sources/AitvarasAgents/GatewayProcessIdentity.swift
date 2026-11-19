import Darwin
import Foundation
import Security

/// A PID identifies a launch only together with its kernel process start time.
public struct GatewayProcessIdentity: Hashable, Sendable {
    public let pid: pid_t
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    func started(after other: Self) -> Bool {
        (startSeconds, startMicroseconds) > (other.startSeconds, other.startMicroseconds)
    }
}

public struct GatewaySocketPeer: Sendable {
    public let identity: GatewayProcessIdentity
    /// Kernel audit token, available to the listener for launcher code identity checks.
    public let auditToken: Data

    public func startingDirectory() throws -> URL {
        let inspector = GatewayProcessInspector.live
        guard try inspector.snapshot(identity.pid).identity == identity else { throw GatewayProcessInspectionError.invalidPeer }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(identity.pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            throw GatewayProcessInspectionError.system(operation: "PROC_PIDVNODEPATHINFO", code: errno)
        }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes -> String? in
            guard let end = bytes.firstIndex(of: 0) else { return nil }
            return String(bytes: bytes[..<end], encoding: .utf8)
        }
        guard let path, path.hasPrefix("/"), try inspector.snapshot(identity.pid).identity == identity else {
            throw GatewayProcessInspectionError.invalidPeer
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

public enum GatewayProcessInspectionError: Error, Equatable, Sendable {
    case system(operation: String, code: Int32)
    case auditTokenValidation(OSStatus)
    case invalidPeer
    case invalidAncestry
}

struct GatewayProcessSnapshot: Equatable, Sendable {
    let identity: GatewayProcessIdentity
    let parentPID: pid_t
    let effectiveUID: uid_t
}

struct GatewayProcessInspector: Sendable {
    let snapshot: @Sendable (pid_t) throws -> GatewayProcessSnapshot
    let socketPeer: @Sendable (Int32) throws -> GatewaySocketPeer

    static let live = Self(snapshot: readProcess, socketPeer: readSocketPeer)

    private static func readProcess(_ pid: pid_t) throws -> GatewayProcessSnapshot {
        guard pid > 0 else { throw GatewayProcessInspectionError.invalidAncestry }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            throw GatewayProcessInspectionError.system(operation: "proc_pidinfo", code: errno)
        }
        guard info.pbi_pid == UInt32(pid), info.pbi_status != UInt32(SZOMB),
              info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000,
              let parent = pid_t(exactly: info.pbi_ppid) else {
            throw GatewayProcessInspectionError.invalidAncestry
        }
        return .init(identity: .init(pid: pid, startSeconds: info.pbi_start_tvsec,
                                     startMicroseconds: info.pbi_start_tvusec),
                     parentPID: parent, effectiveUID: info.pbi_uid)
    }

    private static func readSocketPeer(_ fd: Int32) throws -> GatewaySocketPeer {
        var pid: pid_t = 0
        var pidSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidSize) == 0 else {
            throw GatewayProcessInspectionError.system(operation: "LOCAL_PEERPID", code: errno)
        }
        var token = audit_token_t()
        var tokenSize = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenSize) == 0 else {
            throw GatewayProcessInspectionError.system(operation: "LOCAL_PEERTOKEN", code: errno)
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            throw GatewayProcessInspectionError.system(operation: "getpeereid", code: errno)
        }
        guard pidSize == MemoryLayout<pid_t>.size, tokenSize == MemoryLayout<audit_token_t>.size,
              pid > 1, uid == geteuid() else { throw GatewayProcessInspectionError.invalidPeer }

        let before = try readProcess(pid)
        let auditToken = withUnsafeBytes(of: &token) { Data($0) }
        // An accepted socket can outlive its original peer. Resolve the kernel
        // token, including its PID generation, before accepting a PID lookup.
        var guest: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest)
        guard status == errSecSuccess, guest != nil else {
            throw GatewayProcessInspectionError.auditTokenValidation(status)
        }
        let after = try readProcess(pid)
        guard before.identity == after.identity, after.effectiveUID == uid else {
            throw GatewayProcessInspectionError.invalidPeer
        }
        return .init(identity: after.identity, auditToken: auditToken)
    }

    /// Checks from the peer upward and rechecks every link before accepting a match.
    /// Stops at init, a changed link, an unreadable process, or a bounded depth.
    func nearestAncestor(of peer: GatewayProcessIdentity,
                         matching: (GatewayProcessIdentity) -> Bool) throws -> GatewayProcessIdentity? {
        var current = try snapshot(peer.pid)
        guard current.identity == peer else { throw GatewayProcessInspectionError.invalidAncestry }
        var path = [current]
        var seen: Set<pid_t> = [peer.pid]
        for _ in 0..<256 {
            let parentPID = current.parentPID
            guard parentPID > 1 else { return nil }
            guard seen.insert(parentPID).inserted else { throw GatewayProcessInspectionError.invalidAncestry }
            let parent = try snapshot(parentPID)
            guard parent.identity.pid == parentPID,
                  !parent.identity.started(after: current.identity) else {
                throw GatewayProcessInspectionError.invalidAncestry
            }
            path.append(parent)
            if matching(parent.identity) {
                for step in path.reversed() {
                    guard try snapshot(step.identity.pid) == step else {
                        throw GatewayProcessInspectionError.invalidAncestry
                    }
                }
                return parent.identity
            }
            current = parent
        }
        throw GatewayProcessInspectionError.invalidAncestry
    }
}
