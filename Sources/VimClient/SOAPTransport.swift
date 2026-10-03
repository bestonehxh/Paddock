import CryptoKit
import Foundation
import Security

/// HTTPS to `/sdk` with the host's self-signed certificate pinned by thumbprint, the session
/// cookie kept per transport, SOAP faults turned into `VimError.fault`.
public final class SOAPTransport: Sendable {
    public let baseURL: URL
    public let host: String
    private let session: URLSession
    private let delegate: TrustDelegate
    public let apiVersion: String

    /// SHA-1 (`AA:BB:…`, the form ESXi shows) and SHA-256 thumbprints of a certificate.
    public struct Thumbprint: Sendable, Hashable, Codable {
        public var sha1: String
        public var sha256: String
    }

    /// - Parameters:
    ///   - host: address or name of the ESXi host.
    ///   - expectedThumbprint: SHA-1 thumbprint accepted on first connection, nil to accept
    ///     whatever the host presents (the caller then reads `observedThumbprint` and pins it).
    public init(host: String, port: Int = 443, expectedThumbprint: String?, apiVersion: String = "8.0.2.0") {
        self.host = host
        self.apiVersion = apiVersion
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.port = port == 443 ? nil : port
        c.path = "/sdk"
        baseURL = c.url!
        delegate = TrustDelegate(expectedSHA1: expectedThumbprint)
        let config = URLSessionConfiguration.ephemeral
        // The session cookie is handled by hand (below): Foundation's cookie jar is unreliable
        // for hosts given as bare IP addresses.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        config.httpAdditionalHeaders = ["User-Agent": "Paddock/1.0"]
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private let cookieLock = NSLock()
    private nonisolated(unsafe) var sessionCookie: String?

    /// The `vmware_soap_session` cookie from Login, sent on every later call.
    private var cookie: String? {
        get { cookieLock.lock(); defer { cookieLock.unlock() }; return sessionCookie }
        set { cookieLock.lock(); defer { cookieLock.unlock() }; sessionCookie = newValue }
    }

    /// The thumbprint the host presented on the last TLS handshake.
    public var observedThumbprint: Thumbprint? { delegate.observed }

    /// The certificate's subject summary as macOS renders it ("CN=localhost, …"), for the
    /// Add host sheet.
    public var observedSubject: String? { delegate.observedSubject }

    /// Replaces the pinned thumbprint (after the user accepts a changed certificate).
    public func pin(sha1: String?) { delegate.setExpected(sha1) }

    /// The URLSession, for file transfers that share the pinned trust (guest file URLs).
    public var urlSession: URLSession { session }

    /// Calls a vim25 method and returns the `<MethodResponse>` element.
    public func call(_ method: String, this: MoRef, _ arguments: [XMLOut.Element] = []) async throws -> XMLNode {
        let body = XMLOut.envelope(method: method, this: this, arguments: arguments)
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:vim25/\(apiVersion)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = body
        if let cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let e as VimError {
            throw e
        } catch {
            if let pinned = delegate.pinFailure { throw pinned }
            throw VimError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let setCookie = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Set-Cookie"),
           let pair = setCookie.split(separator: ";").first, pair.contains("vmware_soap_session") {
            cookie = String(pair).trimmingCharacters(in: .whitespaces)
        }
        let root = try XMLNode.parse(data)
        guard let bodyNode = root["Body"] else { throw VimError.malformedResponse("no SOAP body") }
        if let fault = bodyNode["Fault"] {
            let message = fault.string("faultstring") ?? ""
            let type = fault["detail"]?.children.first.flatMap { $0.xsiType ?? $0.name } ?? "Fault"
            throw VimError.fault(type: stripFault(type), message: message)
        }
        guard status == 200 else { throw VimError.httpStatus(status) }
        guard let responseNode = bodyNode.children.first else { throw VimError.malformedResponse("empty body") }
        return responseNode
    }

    /// `InvalidLoginFault` → `InvalidLogin`; `NotAuthenticated` stays.
    private func stripFault(_ s: String) -> String {
        s.hasSuffix("Fault") && s.count > 5 ? String(s.dropLast(5)) : s
    }

    // MARK: - Trust

    /// `@unchecked Sendable`: every mutable field is read and written under `lock`; URLSession
    /// calls the delegate on its own queue and the transport reads the results from any thread.
    final class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var expectedSHA1: String?
        /// The pin as given (colons kept), for the "expected" half of a mismatch message.
        private var expectedDisplay: String?
        private var _observed: Thumbprint?
        private var _observedSubject: String?
        private var _pinFailure: VimError?

        var observed: Thumbprint? { lock.lock(); defer { lock.unlock() }; return _observed }
        var observedSubject: String? { lock.lock(); defer { lock.unlock() }; return _observedSubject }
        /// The last mismatch, handed out once: a later plain network error must not be reported
        /// as a certificate change.
        var pinFailure: VimError? {
            lock.lock(); defer { lock.unlock() }
            let f = _pinFailure
            _pinFailure = nil
            return f
        }

        init(expectedSHA1: String?) {
            self.expectedSHA1 = expectedSHA1.map(Self.normalize)
            self.expectedDisplay = expectedSHA1.map(Self.display)
        }

        func setExpected(_ sha1: String?) {
            lock.lock(); defer { lock.unlock() }
            expectedSHA1 = sha1.map(Self.normalize)
            expectedDisplay = sha1.map(Self.display)
            _pinFailure = nil
        }

        /// `2a9053…` → `2A:90:53:…`, the form ESXi shows.
        static func display(_ s: String) -> String {
            let hex = Array(normalize(s))
            guard hex.count % 2 == 0 else { return s.uppercased() }
            return stride(from: 0, to: hex.count, by: 2).map { String(hex[$0..<$0 + 2]) }.joined(separator: ":")
        }

        static func normalize(_ s: String) -> String {
            s.uppercased().filter { $0.isHexDigit }
        }

        static func thumbprint(of trust: SecTrust) -> Thumbprint? {
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
            let der = SecCertificateCopyData(leaf) as Data
            let sha1 = Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
            let sha256 = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
            return Thumbprint(sha1: sha1, sha256: sha256)
        }

        static func subject(of trust: SecTrust) -> String? {
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
            return SecCertificateCopySubjectSummary(leaf) as String?
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
            -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                return (.performDefaultHandling, nil)
            }
            guard let tp = Self.thumbprint(of: trust) else { return (.cancelAuthenticationChallenge, nil) }
            switch evaluate(tp, subject: Self.subject(of: trust)) {
            case .accept: return (.useCredential, URLCredential(trust: trust))
            case .reject: return (.cancelAuthenticationChallenge, nil)
            }
        }

        private enum Verdict { case accept, reject }

        /// Synchronous so the lock stays out of the async context.
        private func evaluate(_ tp: Thumbprint, subject: String?) -> Verdict {
            lock.lock(); defer { lock.unlock() }
            _observed = tp
            _observedSubject = subject
            guard let expected = expectedSHA1 else { return .accept }   // first connection: the caller pins what it sees
            if Self.normalize(tp.sha1) == expected { return .accept }
            _pinFailure = .certificateChanged(expected: expectedDisplay ?? expected, actual: tp.sha1)
            return .reject
        }
    }
}
