import Foundation
import Yams
import XUtils

public struct PackSchemaBase: Codable, Sendable {
    public enum Version: Int, Codable, Sendable {
        case v1 = 1
    }

    public var version: Version

    public var orgID: String?
    public var bundleID: String?

    public var product: String?

    public var infoPath: String?
    public var entitlementsPath: String?

    public var iconPath: String?
    public var resources: [String]?

    public var extensions: [Extension]?

    /// Skip auto-creating the LSP support file if it's missing.
    public var skipLSP: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, orgID, bundleID, product, infoPath, entitlementsPath
        case iconPath, resources, extensions, skipLSP
    }

    public struct Extension: Codable, Sendable {
        public var product: String
        public var bundleID: String?
        public var infoPath: String
        public var resources: [String]?
        public var entitlementsPath: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case product, bundleID, infoPath, resources, entitlementsPath
        }
    }
}

@dynamicMemberLookup
public struct PackSchema: Sendable {
    public typealias Extension = PackSchemaBase.Extension

    public enum IDSpecifier: Sendable {
        case orgID(String)
        case bundleID(String)

        func formBundleID(product: String) -> String {
            switch self {
            case .orgID(let orgID): "\(orgID).\(product)"
            case .bundleID(let bundleID): bundleID
            }
        }
    }

    public let base: PackSchemaBase
    public let idSpecifier: IDSpecifier
    /// Problems that don't stop the build, such as unknown keys (likely typos).
    public private(set) var warnings: [String] = []

    public init(validating base: PackSchemaBase) throws {
        self.base = base

        if base.version != .v1 {
            throw StringError("xtool.yml: Unsupported schema version: \(base.version.rawValue)")
        }

        switch (base.bundleID, base.orgID) {
        case (let bundleID?, _):
            idSpecifier = .bundleID(bundleID)
        case (nil, let orgID?):
            idSpecifier = .orgID(orgID)
        case (nil, nil):
            throw StringError("xtool.yml: Must specify either orgID or bundleID")
        }

        if let iconPath = base.iconPath {
            let ext = URL(fileURLWithPath: iconPath).pathExtension
            guard ext == "png" else {
                throw StringError("xtool.yml: iconPath should have a 'png' path extension. Got '\(ext)'.")
            }
        }
    }

    // swiftlint:disable:next force_try
    public static let `default` = try! PackSchema(validating: .init(
        version: .v1,
        orgID: "com.example"
    ))

    public init(url: URL) async throws {
        let data = try await Data(reading: url)
        let base = try YAMLDecoder().decode(PackSchemaBase.self, from: data)
        try self.init(validating: base)
        let yaml = String(decoding: data, as: UTF8.self)
        warnings = Self.unknownKeyWarnings(inYAML: yaml)
    }

    static func unknownKeyWarnings(inYAML yaml: String) -> [String] {
        unknownKeyWarnings(in: (try? Yams.load(yaml: yaml)) ?? nil)
    }

    /// Unknown keys are otherwise dropped silently by Codable, so a typo such as
    /// `entitlements:` for `entitlementsPath:` would build an app without entitlements.
    static func unknownKeyWarnings(in yaml: Any?) -> [String] {
        guard let root = yaml as? [String: Any] else { return [] }
        var warnings = unknownKeyWarnings(
            keys: root.keys,
            known: PackSchemaBase.CodingKeys.allCases.map(\.rawValue),
            location: "xtool.yml"
        )
        if let extensions = root["extensions"] as? [Any] {
            for (index, ext) in extensions.enumerated() {
                guard let ext = ext as? [String: Any] else { continue }
                warnings += unknownKeyWarnings(
                    keys: ext.keys,
                    known: PackSchemaBase.Extension.CodingKeys.allCases.map(\.rawValue),
                    location: "xtool.yml: extensions[\(index)]"
                )
            }
        }
        return warnings
    }

    private static func unknownKeyWarnings(
        keys: some Collection<String>,
        known: [String],
        location: String
    ) -> [String] {
        keys.filter { !known.contains($0) }.sorted().map { key in
            var message = "\(location): unknown key '\(key)' will be ignored."
            if let suggestion = closestKey(to: key, in: known) {
                message += " Did you mean '\(suggestion)'?"
            }
            return message
        }
    }

    static func closestKey(to key: String, in known: [String]) -> String? {
        let lowered = key.lowercased()
        if let match = known.first(where: { $0.lowercased() == lowered }) {
            return match
        }
        // `entitlements` -> `entitlementsPath`, `icon` -> `iconPath`
        let prefixed = known.filter { $0.lowercased().hasPrefix(lowered) }
        if prefixed.count == 1 {
            return prefixed[0]
        }
        let scored = known.map { ($0, editDistance(lowered, $0.lowercased())) }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 <= max(2, key.count / 3) else {
            return nil
        }
        return best.0
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhs = Array(lhs), rhs = Array(rhs)
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        for i in 1...lhs.count {
            var current = [i] + Array(repeating: 0, count: rhs.count)
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[rhs.count]
    }

    public subscript<Subject>(dynamicMember keyPath: KeyPath<PackSchemaBase, Subject>) -> Subject {
        self.base[keyPath: keyPath]
    }
}
