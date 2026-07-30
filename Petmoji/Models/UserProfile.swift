import Foundation

// MARK: - User profile (public.profiles)

struct UserProfile: Decodable, Identifiable, Equatable {
    let id: UUID
    var fullName: String
    var email: String
    var phone: String?
    var notificationsEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case email
        case phone
        case notificationsEnabled = "notifications_enabled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        fullName = try container.decode(String.self, forKey: .fullName)
        email = try container.decode(String.self, forKey: .email)
        phone = try container.decodeIfPresent(String.self, forKey: .phone)
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
    }

    init(id: UUID, fullName: String, email: String, phone: String?, notificationsEnabled: Bool = true) {
        self.id = id
        self.fullName = fullName
        self.email = email
        self.phone = phone
        self.notificationsEnabled = notificationsEnabled
    }
}

// MARK: - Sign-up auth errors

enum SignUpAuthError: LocalizedError {
    case noSession
    case invalidCredentials
    case invalidOTP
    case expiredOTP
    case emailAlreadyExists
    case userNotFound
    case rateLimited
    case network
    case emailDeliveryFailed
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .noSession:
            return "You're not signed in. Please sign in again."
        case .invalidCredentials:
            return "Invalid or expired code."
        case .invalidOTP:
            return "That code doesn't look right. Check the email and try again."
        case .expiredOTP:
            return "That code has expired. Request a new one."
        case .emailAlreadyExists:
            return "An account with this email already exists. Sign in instead."
        case .userNotFound:
            return "No account found for this email. Create an account instead."
        case .rateLimited:
            return "Too many attempts. Wait a minute and try again."
        case .network:
            return "Couldn't reach the server. Check your connection and try again."
        case .emailDeliveryFailed:
            return "Couldn't send the verification email. In Supabase, set both Magic Link and Confirm signup templates to your Loops JSON payload, then check Authentication → Logs."
        case .unknown(let message):
            return message
        }
    }

    static func from(_ error: Error) -> SignUpAuthError {
        if let mapped = error as? SignUpAuthError { return mapped }

        let raw = error.localizedDescription
        let message = raw.lowercased()

        if message.contains("already") && (message.contains("registered") || message.contains("exists")) {
            return .emailAlreadyExists
        }
        if message.contains("user not found") || message.contains("signups not allowed")
            || message.contains("user does not exist") {
            return .userNotFound
        }
        if message.contains("expired") || message.contains("otp_expired") {
            return .expiredOTP
        }
        if message.contains("invalid otp") || message.contains("invalid token")
            || message.contains("token is invalid") {
            return .invalidOTP
        }
        if message.contains("invalid login") || message.contains("invalid credentials")
            || message.contains("invalid email or password") {
            return .invalidCredentials
        }
        if message.contains("rate") || message.contains("too many") || message.contains("429") {
            return .rateLimited
        }
        if message.contains("magic link email") || message.contains("confirmation email")
            || message.contains("error sending") || message.contains("450")
            || message.contains("valid json payload") {
            return .emailDeliveryFailed
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                return .network
            default:
                break
            }
        }
        return .unknown(raw)
    }
}
