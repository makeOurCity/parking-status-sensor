import Foundation

enum AuthError: LocalizedError {
    case notSignedIn
    case invalidResponse
    case cognito(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "サインインしていません。"
        case .invalidResponse:
            return "サーバーから予期しない応答がありました。"
        case .cognito(let message):
            return message
        }
    }
}

struct AWSTemporaryCredentials {
    let accessKeyId: String
    let secretKey: String
    let sessionToken: String
    let expiration: Date
}

/// Handles Cognito User Pool sign-in and Identity Pool credential vending.
///
/// Sign-in happens once (USER_PASSWORD_AUTH, over TLS). After that, the refresh
/// token — stored in the Keychain, valid 3650 days — silently renews the session
/// on every launch via REFRESH_TOKEN_AUTH. The user never signs in again unless
/// they explicitly sign out or the refresh token itself is revoked.
@MainActor
final class CognitoAuthService: ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published private(set) var isBootstrapping = true

    private let keychain = KeychainStore()
    private let refreshTokenKey = "cognito.refreshToken"

    private var idToken: String?
    private var idTokenExpiresAt: Date?
    private var refreshToken: String?

    private var cachedCredentials: AWSTemporaryCredentials?
    private var cachedIdentityId: String?

    private let idpEndpoint = URL(string: "https://cognito-idp.\(AWSConfig.region).amazonaws.com/")!
    private let identityEndpoint = URL(string: "https://cognito-identity.\(AWSConfig.region).amazonaws.com/")!
    private var loginsKey: String { "cognito-idp.\(AWSConfig.region).amazonaws.com/\(AWSConfig.cognitoUserPoolId)" }

    /// Attempts a silent sign-in from a Keychain-stored refresh token. Call once at app launch.
    func bootstrap() async {
        defer { isBootstrapping = false }
        guard let storedRefreshToken = keychain.get(forKey: refreshTokenKey) else { return }
        refreshToken = storedRefreshToken
        do {
            try await refreshSession()
            isSignedIn = true
        } catch {
            // Stored refresh token is no longer valid; fall back to manual sign-in.
            keychain.remove(forKey: refreshTokenKey)
            refreshToken = nil
        }
    }

    func signIn(username: String, password: String) async throws {
        let body: [String: Any] = [
            "AuthFlow": "USER_PASSWORD_AUTH",
            "ClientId": AWSConfig.cognitoAppClientId,
            "AuthParameters": [
                "USERNAME": username,
                "PASSWORD": password,
            ],
        ]
        let response = try await callIdp(action: "InitiateAuth", body: body)
        try applyAuthenticationResult(response)
        if let refreshToken {
            keychain.set(refreshToken, forKey: refreshTokenKey)
        }
        isSignedIn = true
    }

    func signOut() {
        keychain.remove(forKey: refreshTokenKey)
        idToken = nil
        idTokenExpiresAt = nil
        refreshToken = nil
        cachedCredentials = nil
        cachedIdentityId = nil
        isSignedIn = false
    }

    /// A valid CloudWatch Logs-scoped AWS credential, refreshing the ID token and/or
    /// the Cognito Identity credential as needed. Never re-prompts for a password.
    func credentialsForCloudWatch() async throws -> AWSTemporaryCredentials {
        if let cached = cachedCredentials, cached.expiration.timeIntervalSinceNow > 300 {
            return cached
        }

        let token = try await validIdToken()

        let identityId: String
        if let cachedIdentityId {
            identityId = cachedIdentityId
        } else {
            identityId = try await getIdentityId(idToken: token)
            cachedIdentityId = identityId
        }

        let credentials = try await getCredentials(identityId: identityId, idToken: token)
        cachedCredentials = credentials
        return credentials
    }

    // MARK: - Token refresh

    private func validIdToken() async throws -> String {
        if let idToken, let idTokenExpiresAt, idTokenExpiresAt.timeIntervalSinceNow > 120 {
            return idToken
        }
        try await refreshSession()
        guard let idToken else { throw AuthError.notSignedIn }
        return idToken
    }

    private func refreshSession() async throws {
        guard let refreshToken else { throw AuthError.notSignedIn }
        let body: [String: Any] = [
            "AuthFlow": "REFRESH_TOKEN_AUTH",
            "ClientId": AWSConfig.cognitoAppClientId,
            "AuthParameters": [
                "REFRESH_TOKEN": refreshToken,
            ],
        ]
        let response = try await callIdp(action: "InitiateAuth", body: body)
        try applyAuthenticationResult(response, keepExistingRefreshToken: true)
    }

    private func applyAuthenticationResult(_ response: [String: Any], keepExistingRefreshToken: Bool = false) throws {
        guard let result = response["AuthenticationResult"] as? [String: Any],
              let idToken = result["IdToken"] as? String,
              let expiresIn = result["ExpiresIn"] as? Int
        else {
            throw AuthError.invalidResponse
        }
        self.idToken = idToken
        self.idTokenExpiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        // Cognito only returns a new RefreshToken on the initial sign-in, not on
        // every REFRESH_TOKEN_AUTH call — keep the existing one in that case.
        if let newRefreshToken = result["RefreshToken"] as? String {
            self.refreshToken = newRefreshToken
        } else if !keepExistingRefreshToken {
            throw AuthError.invalidResponse
        }
    }

    // MARK: - Identity Pool

    private func getIdentityId(idToken: String) async throws -> String {
        let body: [String: Any] = [
            "IdentityPoolId": AWSConfig.cognitoIdentityPoolId,
            "Logins": [loginsKey: idToken],
        ]
        let response = try await callIdentity(action: "GetId", body: body)
        guard let identityId = response["IdentityId"] as? String else {
            throw AuthError.invalidResponse
        }
        return identityId
    }

    private func getCredentials(identityId: String, idToken: String) async throws -> AWSTemporaryCredentials {
        let body: [String: Any] = [
            "IdentityId": identityId,
            "Logins": [loginsKey: idToken],
        ]
        let response = try await callIdentity(action: "GetCredentialsForIdentity", body: body)
        guard let credentials = response["Credentials"] as? [String: Any],
              let accessKeyId = credentials["AccessKeyId"] as? String,
              let secretKey = credentials["SecretKey"] as? String,
              let sessionToken = credentials["SessionToken"] as? String,
              let expiration = credentials["Expiration"] as? Double
        else {
            throw AuthError.invalidResponse
        }
        return AWSTemporaryCredentials(
            accessKeyId: accessKeyId,
            secretKey: secretKey,
            sessionToken: sessionToken,
            expiration: Date(timeIntervalSince1970: expiration)
        )
    }

    // MARK: - Unsigned Cognito JSON calls

    /// Cognito User Pool (`cognito-idp`) and Identity Pool (`cognito-identity`) public
    /// operations (InitiateAuth, GetId, GetCredentialsForIdentity, ...) are designed to
    /// be called directly from untrusted clients and require no SigV4 signature — only
    /// the plain JSON-1.1 request. CloudWatch Logs is different; see SigV4Signer.
    private func callIdp(action: String, body: [String: Any]) async throws -> [String: Any] {
        try await callCognito(endpoint: idpEndpoint, target: "AWSCognitoIdentityProviderService.\(action)", body: body)
    }

    private func callIdentity(action: String, body: [String: Any]) async throws -> [String: Any] {
        try await callCognito(endpoint: identityEndpoint, target: "AWSCognitoIdentityService.\(action)", body: body)
    }

    private func callCognito(endpoint: URL, target: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue(target, forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (json["message"] as? String) ?? (json["__type"] as? String) ?? "HTTP \(http.statusCode)"
            throw AuthError.cognito(message)
        }
        return json
    }
}
