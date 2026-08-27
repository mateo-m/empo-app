import Foundation

/// The server one WebDAV target writes to, per SPEC 9.5.
///
/// The root of 9.5 is a path the user types on their own server. It
/// comes in two parts: the address, which reaches the DAV endpoint,
/// and `TargetDescriptor.root`, which the engine joins into every
/// path. This type turns a provider path of 8.1 into an address, and
/// an address the server answered back into a provider path.
///
/// This value and the password travel together in the Keychain, as
/// one `WebDAVConnection`, per 6.7. A device that syncs the
/// descriptor without the password shows the target placeholder of
/// 8.8 until the user types the password again.
public struct WebDAVServer: Codable, Equatable, Sendable {

    /// Where the DAV endpoint answers, such as
    /// `https://cloud.example.com/remote.php/dav/files/alice`. 8.11
    /// takes https alone.
    public var address: URL
    public var username: String

    /// Whether this server answered the space query of RFC 4331 when
    /// the permission check of 8.7 asked it.
    ///
    /// It rides the server and not the provider, because 9.7 states
    /// that WebDAV answers on some servers and not on others. It is
    /// what `canQueryQuota` reads.
    public var answersQuota: Bool

    public init(address: URL, username: String, answersQuota: Bool = false) {
        self.address = address
        self.username = username
        self.answersQuota = answersQuota
    }

    /// The part of the path the address itself carries, such as the
    /// `/remote.php/dav/files/alice` of a Nextcloud. It never ends
    /// with a separator, and it is decoded, as a path the reader
    /// compares against.
    public var basePath: String {
        var path = address.path
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The address of one provider path.
    public func url(path: String = "") -> URL? {
        guard let scheme = address.scheme?.lowercased(), let host = address.host, !host.isEmpty
        else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = address.port
        components.percentEncodedPath = absolutePath(path)
        return components.url
    }

    /// The path of one provider path on this server, encoded once.
    public func absolutePath(_ path: String) -> String {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let base = Self.encode(basePath)
        guard !trimmed.isEmpty else { return base.isEmpty ? "/" : base }
        return base + "/" + Self.encode(trimmed)
    }

    /// The provider path one `href` names, or `nil` when the address
    /// belongs to another server or sits outside the base path.
    ///
    /// A server answers a path on its own, and some answer a whole
    /// URL. RFC 4918 allows both.
    public func relativePath(ofHref href: String) -> String? {
        let path = Self.path(ofHref: href)
        var found = path.removingPercentEncoding ?? path
        while found.hasSuffix("/") { found.removeLast() }

        let base = basePath
        guard !base.isEmpty else {
            return found.hasPrefix("/") ? String(found.dropFirst()) : found
        }
        guard found.hasPrefix(base) else { return nil }
        let rest = found.dropFirst(base.count)
        return rest.hasPrefix("/") ? String(rest.dropFirst()) : String(rest)
    }

    /// The objects of one multistatus answer, per 8.1.
    ///
    /// A collection is not an object, because the engine has no
    /// directory model. A staged upload is not one either, because it
    /// is not the file yet.
    public func objects(fromEntries entries: [WebDAV.Entry]) -> [RemoteObject] {
        entries
            .compactMap { entry -> RemoteObject? in
                guard !entry.isCollection else { return nil }
                guard let path = relativePath(ofHref: entry.href), !path.isEmpty else {
                    return nil
                }
                guard !WebDAV.isTemporaryPath(path) else { return nil }
                return RemoteObject(
                    path: path, sizeBytes: entry.sizeBytes, modifiedAt: entry.modifiedAt)
            }
            .sorted { $0.path < $1.path }
    }

    /// The collections one multistatus answer names, other than the
    /// collection the walk asked about.
    public func collections(fromEntries entries: [WebDAV.Entry], under path: String) -> [String] {
        let asked = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return entries.compactMap { entry -> String? in
            guard entry.isCollection else { return nil }
            guard let found = relativePath(ofHref: entry.href), found != asked, !found.isEmpty
            else { return nil }
            return found
        }
    }

    /// Why Empo refuses this server, or `nil` when it takes it.
    ///
    /// It runs before the first request of the permission check of
    /// 8.7, so a plain `http` address never carries the password.
    public var refusal: BackupProviderError? {
        if let refusal = TransportSecurity.refusal(forAddress: address) { return refusal }
        if username.trimmingCharacters(in: .whitespaces).isEmpty {
            return .rejected(message: "Type the user name of the server.")
        }
        return nil
    }

    /// Every part of a path, encoded once, with the separators kept.
    private static func encode(_ path: String) -> String {
        path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .empoPathSegment) ?? String($0) }
            .joined(separator: "/")
    }

    /// The path part of an `href`, which is a whole URL on some
    /// servers and a path on others.
    private static func path(ofHref href: String) -> String {
        guard href.contains("://"), let parts = URLComponents(string: href) else { return href }
        return parts.percentEncodedPath
    }
}

extension CharacterSet {
    /// The characters RFC 3986 lets a path segment carry unencoded.
    /// A separator is not one of them, because a segment holds no
    /// separator.
    fileprivate static let empoPathSegment: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'()*+,;=:@")
        return allowed
    }()
}

/// One WebDAV target as the Keychain holds it, per SPEC 6.7 and 9.5.
///
/// The server is not a secret and the password is. They stay in one
/// record because a target opens with both or with neither, and 8.8
/// keeps every secret out of `targets.json`.
public struct WebDAVConnection: Codable, Equatable, Sendable {

    public var server: WebDAVServer
    /// The password, per 9.5. An app password of the user's server
    /// fits here.
    public var password: String

    public init(server: WebDAVServer, password: String) {
        self.server = server
        self.password = password
    }

    /// What HTTP Basic sends, per 9.5. TLS carries it, per 8.11.
    public var authorizationHeader: String {
        let pair = Data("\(server.username):\(password)".utf8)
        return "Basic " + pair.base64EncodedString()
    }

    /// What the target row and the target screen show for this
    /// target, per 8.8. It names no password.
    public var accountHint: String {
        guard let host = server.address.host else { return server.username }
        return "\(server.username) at \(host)"
    }

    public func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(json data: Data) throws -> WebDAVConnection {
        try JSONDecoder().decode(WebDAVConnection.self, from: data)
    }
}
