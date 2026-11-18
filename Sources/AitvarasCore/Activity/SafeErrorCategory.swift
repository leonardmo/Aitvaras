import Foundation

/// Metadata only. Neither descriptions nor associated error values enter a
/// category. Owners of error enums supply their case through this contract.
public protocol SafeErrorCategorizing: Error {
    var safeErrorCategory: SafeErrorCategory { get }
}

public struct SafeErrorCategory: Sendable, Equatable, Hashable, Codable {
    public let type: String
    public let errorCase: String
    public var name: String { type + "." + errorCase }

    public init(type: StaticString, errorCase: StaticString) {
        self.init(typeName: String(describing: type), caseName: String(describing: errorCase))
    }
    private init(typeName: String, caseName: String) {
        type = Self.identifier(typeName) ? typeName : "UnknownError"
        errorCase = Self.identifier(caseName) ? caseName : "unknown"
    }
    public static func category(for error: any Error) -> Self {
        if let known = error as? any SafeErrorCategorizing { return known.safeErrorCategory }
        // Reflect the metatype only, never the error, its NSError domain or
        // userInfo. Unrecognized error cases remain explicitly unknown.
        let name = String(reflecting: Swift.type(of: error)).split(separator: ".").last.map(String.init) ?? "UnknownError"
        return Self(typeName: name, caseName: "unknown")
    }
    private static func identifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func letter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 }
        return !bytes.isEmpty && bytes.count <= 128 && letter(bytes[0])
            && bytes.dropFirst().allSatisfy { letter($0) || (48...57).contains($0) }
    }
    private enum CodingKeys: String, CodingKey { case type, errorCase }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(String.self, forKey: .type)
        let errorCase = try values.decode(String.self, forKey: .errorCase)
        guard Self.identifier(type), Self.identifier(errorCase) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid error category"))
        }
        self.init(typeName: type, caseName: errorCase)
    }
}
