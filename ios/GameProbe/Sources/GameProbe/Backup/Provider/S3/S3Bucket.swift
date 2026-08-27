import Foundation

/// The bucket one S3 target writes to, per SPEC 9.4.
///
/// The root of 8.7 is a bucket and a path the user types. The path
/// rides `TargetDescriptor.root`, because the engine joins it into
/// every key. The rest is here: where the service answers, which
/// region signs, and which bucket holds the keys.
///
/// This value and the access key travel together in the Keychain, as
/// one `S3Connection`, per 6.7. A device that syncs the descriptor
/// without the secret shows the target placeholder of 8.8 until the
/// user types the bucket again.
public struct S3Bucket: Codable, Equatable, Sendable {

    /// Where the service answers, such as
    /// `https://s3.eu-west-1.amazonaws.com`. 8.11 takes https alone.
    public var address: URL
    /// The region the signature names. R2 takes `auto`.
    public var region: String
    /// The bucket name.
    public var name: String
    /// Whether the bucket name goes in the path.
    ///
    /// AWS takes the name in the host, such as
    /// `bucket.s3.eu-west-1.amazonaws.com`. MinIO takes it in the
    /// path. R2 and B2 take both.
    public var usesPathStyle: Bool

    public init(address: URL, region: String, name: String, usesPathStyle: Bool) {
        self.address = address
        self.region = region
        self.name = name
        self.usesPathStyle = usesPathStyle
    }

    /// What the add form of 13.7 offers before the user changes it.
    ///
    /// AWS reads the bucket from the host, and every other service in
    /// 9.4 takes the path form. The host decides, and the user may
    /// turn it either way.
    public static func prefersPathStyle(address: URL) -> Bool {
        guard let host = address.host?.lowercased() else { return true }
        return !host.hasSuffix("amazonaws.com")
    }

    /// The host a request goes to. It carries the bucket name unless
    /// the bucket rides the path.
    public var host: String? {
        guard let host = address.host, !host.isEmpty else { return nil }
        guard !usesPathStyle, !name.isEmpty else { return host }
        return "\(name).\(host)"
    }

    public var scheme: String? { address.scheme?.lowercased() }
    public var port: Int? { address.port }

    /// The part of the path the address itself carries, such as the
    /// `/s3` of a MinIO behind a reverse proxy. It never ends with a
    /// separator.
    var basePath: String {
        var path = address.path
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The path of one key, encoded once, as both the URL and the
    /// signature read it.
    ///
    /// The key is the whole provider path of 8.1. Empo adds no
    /// prefix here, because the root of 8.7 is already inside the
    /// path the engine hands over.
    public func canonicalPath(key: String) -> String {
        var parts = basePath
        if usesPathStyle, !name.isEmpty {
            parts += "/" + S3SigV4.uriEncode(name)
        }
        let trimmed = key.hasPrefix("/") ? String(key.dropFirst()) : key
        guard !trimmed.isEmpty else { return parts.isEmpty ? "/" : parts }
        return parts + "/" + S3SigV4.encodePath(trimmed)
    }

    /// The URL of one call against this bucket.
    public func url(key: String = "", query: [URLQueryItem] = []) -> URL? {
        guard let scheme, let host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.percentEncodedPath = canonicalPath(key: key)
        if !query.isEmpty {
            components.percentEncodedQuery = S3SigV4.canonicalQuery(query)
        }
        return components.url
    }

    /// Why Empo refuses this bucket, or `nil` when it takes it.
    ///
    /// It runs before the first request of the permission check of
    /// 8.7, so a plain `http` address never carries the access key.
    public var refusal: BackupProviderError? {
        if let refusal = TransportSecurity.refusal(forAddress: address) { return refusal }
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            return .rejected(message: "Type the name of the bucket.")
        }
        if region.trimmingCharacters(in: .whitespaces).isEmpty {
            return .rejected(message: "Type the region of the bucket.")
        }
        return nil
    }
}

/// One S3 target as the Keychain holds it, per SPEC 6.7 and 9.4.
///
/// The bucket is not a secret and the access key is. They stay in one
/// record because a target opens with both or with neither, and 8.8
/// keeps every secret out of `targets.json`.
public struct S3Connection: Codable, Equatable, Sendable {

    public var bucket: S3Bucket
    public var credentials: S3SigV4.Credentials

    public init(bucket: S3Bucket, credentials: S3SigV4.Credentials) {
        self.bucket = bucket
        self.credentials = credentials
    }

    /// What the target row and the target screen show for this
    /// target, per 8.8. It names no key.
    public var accountHint: String {
        guard let host = bucket.address.host else { return bucket.name }
        return "\(bucket.name) at \(host)"
    }

    public func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(json data: Data) throws -> S3Connection {
        try JSONDecoder().decode(S3Connection.self, from: data)
    }
}
