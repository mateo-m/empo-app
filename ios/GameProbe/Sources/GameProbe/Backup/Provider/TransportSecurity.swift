import Foundation

/// The transport rules of SPEC 8.11, for the services the user hosts
/// themselves.
///
/// v1 rides system trust and nothing else. A plain `http` address is
/// refused before a request leaves the device, and a certificate the
/// system does not trust fails with one stated line. S3 is the first
/// target that needs these rules. WebDAV and SFTP take the same ones
/// in tickets 012 and 013, which is why they live here and not in
/// `S3`.
public enum TransportSecurity {

    /// What a plain `http` address earns, per 8.11.
    public static let plainAddressMessage =
        "Empo takes an https address only. Type the address again with https."

    /// What a certificate the system does not trust earns, per 8.11.
    /// The add sheet of 13.7 adds this line to the failing step.
    public static let systemTrustMessage =
        "This device does not trust the certificate of the server."
        + " Empo takes a certificate that the system trusts."
        + " It takes no self-signed certificate and no certificate authority of your own."

    /// The line the add form of 13.7 carries beside the host field,
    /// at the moment the user types someone else's host name. The
    /// rule behind it is 5.7: Empo writes the saves as they are.
    public static let storageWarning =
        "Empo stores backups as they are."
        + " A person who can read this storage can read your saves."

    /// Why Empo refuses this address before any request, or `nil`
    /// when the address is one it takes.
    ///
    /// The check runs on the device. A refusal that waited for the
    /// server would already have sent the access key over a link
    /// 8.11 does not allow.
    public static func refusal(forAddress url: URL?) -> BackupProviderError? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host,
            !host.isEmpty
        else {
            return .rejected(message: "Empo cannot read that address. Type it again.")
        }
        guard scheme == "https" else { return .rejected(message: plainAddressMessage) }
        return nil
    }

    // MARK: - The certificate failures of URL loading

    /// The URL loading codes that mean the certificate failed.
    ///
    /// The numbers are `NSURLErrorSecureConnectionFailed` and the
    /// five certificate codes beside it. They are written out because
    /// the names live in `FoundationNetworking` on Linux, and this
    /// package builds on both.
    public static let certificateErrorCodes: Set<Int> = [
        -1200,  // NSURLErrorSecureConnectionFailed
        -1201,  // NSURLErrorServerCertificateHasBadDate
        -1202,  // NSURLErrorServerCertificateUntrusted
        -1203,  // NSURLErrorServerCertificateHasUnknownRoot
        -1204,  // NSURLErrorServerCertificateNotYetValid
        -1205,  // NSURLErrorClientCertificateRejected
        -1206,  // NSURLErrorClientCertificateRequired
    ]

    /// Whether this URL loading code is a certificate failure.
    public static func isCertificateFailure(urlErrorCode code: Int) -> Bool {
        certificateErrorCodes.contains(code)
    }

    /// The error a certificate failure earns, per 8.11 and 13.7.
    ///
    /// It is `rejected`, because no later pass fixes an untrusted
    /// certificate. The message carries what the system said and
    /// then the stated line, so the user reads both.
    public static func certificateError(
        urlErrorCode code: Int, description: String
    ) -> BackupProviderError? {
        guard isCertificateFailure(urlErrorCode: code) else { return nil }
        let said = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return .rejected(message: systemTrustMessage) }
        return .rejected(message: "\(said) \(systemTrustMessage)")
    }
}
