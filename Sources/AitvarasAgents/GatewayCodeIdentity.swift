import Darwin
import Foundation
import MachO
import Security

/// Pins the exact valid code signature at the expected bundle location.
/// Ad-hoc signed development binaries have a CDHash and use the same check.
public struct GatewayCodeIdentity: Sendable {
    private let path: String
    let hashes: Set<Data>

    public init(executable: URL, signingLocation: URL? = nil) throws {
        let url = executable.resolvingSymlinksInPath().standardizedFileURL
        let location = (signingLocation ?? url) as CFURL
        var code: SecStaticCode?
        let validation = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCreateWithPath(location, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, validation, nil) == errSecSuccess else {
            throw GatewayTransportError.untrustedBinary
        }
        self.path = url.path
        self.hashes = try Self.codeHashes(code, location: location, executable: url)
    }

    public func matches(_ peer: GatewaySocketPeer) -> Bool {
        mismatch(peer) == nil
    }

    enum Mismatch: Equatable {
        case guestLookup(OSStatus)
        case validity(OSStatus)
        case pathLookup(OSStatus)
        case path
        case cdhash(OSStatus)
    }

    func mismatch(_ peer: GatewaySocketPeer) -> Mismatch? {
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: peer.auditToken] as CFDictionary
        let lookup = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard lookup == errSecSuccess, let code else { return .guestLookup(lookup) }
        let validity = SecCodeCheckValidity(code, [], nil)
        guard validity == errSecSuccess else { return .validity(validity) }

        var staticCode: SecStaticCode?
        let staticLookup = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticLookup == errSecSuccess, let staticCode else { return .pathLookup(staticLookup) }
        var actual: CFURL?
        let pathLookup = SecCodeCopyPath(staticCode, [], &actual)
        guard pathLookup == errSecSuccess, let actual else { return .pathLookup(pathLookup) }
        let reported = actual as URL
        // For a GUI app Security may report the bundle root instead of its executable.
        let executable = reported.pathExtension == "app" ? Bundle(url: reported)?.executableURL : reported
        guard executable?.resolvingSymlinksInPath().standardizedFileURL.path == path else { return .path }

        let clauses = hashes.map { hash in
            let hex = hash.map { String(format: "%02x", $0) }.joined()
            return "cdhash H\"\(hex)\""
        }
        var requirement: SecRequirement?
        let created = SecRequirementCreateWithString(clauses.joined(separator: " or ") as CFString, [], &requirement)
        guard created == errSecSuccess, let requirement else { return .cdhash(created) }
        let checked = SecCodeCheckValidity(code, [], requirement)
        return checked == errSecSuccess ? nil : .cdhash(checked)
    }

    private static func codeHashes(_ code: SecStaticCode, location: CFURL, executable: URL) throws -> Set<Data> {
        let offsets = try universalSliceOffsets(executable)
        if offsets.isEmpty { return try signingHashes(code) }
        var hashes = Set<Data>()
        for offset in offsets {
            let attributes = [kSecCodeAttributeUniversalFileOffset as String: NSNumber(value: offset)]
            var slice: SecStaticCode?
            guard SecStaticCodeCreateWithPathAndAttributes(location, [], attributes as CFDictionary, &slice) == errSecSuccess,
                  let slice else { throw GatewayTransportError.untrustedBinary }
            hashes.formUnion(try signingHashes(slice))
        }
        return hashes
    }

    private static func signingHashes(_ code: SecStaticCode) throws -> Set<Data> {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let hashes = values[kSecCodeInfoCdHashes as String] as? [Data],
              !hashes.isEmpty, hashes.allSatisfy({ $0.count == 20 }) else {
            throw GatewayTransportError.untrustedBinary
        }
        return Set(hashes)
    }

    // Security reports the digest choices for one slice at a time. Read only the
    // universal header and let Security validate and inspect each code signature.
    private static func universalSliceOffsets(_ executable: URL) throws -> [UInt64] {
        let handle = try FileHandle(forReadingFrom: executable)
        defer { try? handle.close() }
        let headerSize = MemoryLayout<fat_header>.size
        guard let header = try handle.read(upToCount: headerSize), header.count == headerSize else {
            throw GatewayTransportError.untrustedBinary
        }
        let magic = UInt32(bigEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard magic == FAT_MAGIC || magic == FAT_MAGIC_64 else { return [] }
        let count = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }))
        let wide = magic == FAT_MAGIC_64
        let entrySize = wide ? MemoryLayout<fat_arch_64>.size : MemoryLayout<fat_arch>.size
        guard (1...64).contains(count), let table = try handle.read(upToCount: count * entrySize),
              table.count == count * entrySize else { throw GatewayTransportError.untrustedBinary }
        return table.withUnsafeBytes { bytes in
            (0..<count).map { index in
                let field = index * entrySize + 8 // Skip the CPU type and subtype.
                if wide { return UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: field, as: UInt64.self)) }
                return UInt64(UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: field, as: UInt32.self)))
            }
        }
    }

    public static func enclosingApp() throws -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var bytes = [CChar](repeating: 0, count: Int(size))
        guard size > 0, _NSGetExecutablePath(&bytes, &size) == 0 else { throw GatewayTransportError.missingBundle }
        let path = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let binary = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let macOS = binary.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard ["MacOS", "Helpers"].contains(macOS.lastPathComponent), contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { throw GatewayTransportError.missingBundle }
        return app
    }
}
