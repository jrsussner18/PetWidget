import Foundation
import Supabase

// MARK: - Supabase Service

final class SupabaseService: @unchecked Sendable {
    static let shared = SupabaseService()

    // Replace with your actual Supabase project values
    private let supabaseURL = URL(string: ProcessInfo.processInfo.environment["SUPABASE_URL"] ?? "https://myzcaywwxmjzrsjpcjhh.supabase.co")!
    private let supabaseKey = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"] ?? "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im15emNheXd3eG1qenJzanBjamhoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE5ODY5MTcsImV4cCI6MjA4NzU2MjkxN30.JC275740QikWldaTrMArjpBjdmhdCvXg3cgTGjMakHY"

    lazy var client: SupabaseClient = {
        SupabaseClient(supabaseURL: supabaseURL, supabaseKey: supabaseKey)
    }()

    private init() {}

    // MARK: - Auth

    func signInAnonymously() async throws -> UUID {
        let session = try await client.auth.signInAnonymously()
        return session.user.id
    }

    func currentUserId() async throws -> UUID {
        let session = try await client.auth.session
        return session.user.id
    }

    /// Returns true when a persisted Supabase session exists.
    func restoreSessionIfPresent() async -> Bool {
        (try? await client.auth.session) != nil
    }

    /// Confirms the Keychain session is still valid on the server (not deleted / expired).
    func validatePersistedSession() async -> UUID? {
        guard (try? await client.auth.session) != nil else { return nil }
        do {
            let user = try await client.auth.user()
            return user.id
        } catch {
            try? await client.auth.signOut(scope: .global)
            return nil
        }
    }

    static func isAuthError(_ error: Error) -> Bool {
        if error is SignUpAuthError {
            switch error as? SignUpAuthError {
            case .noSession, .invalidCredentials, .invalidOTP, .expiredOTP:
                return true
            default:
                return false
            }
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("jwt")
            || message.contains("session")
            || message.contains("not authenticated")
            || message.contains("invalid login")
    }

    func requireUserId() async throws -> UUID {
        do {
            return try await currentUserId()
        } catch {
            throw SignUpAuthError.noSession
        }
    }

    func sendEmailOTP(email: String, shouldCreateUser: Bool) async throws {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SignUpAuthError.unknown("Enter a valid email address.")
        }
        do {
            try await client.auth.signInWithOTP(
                email: trimmed,
                redirectTo: nil,
                shouldCreateUser: shouldCreateUser
            )
        } catch {
#if DEBUG
            print("[SupabaseService] sendEmailOTP failed: \(error)")
#endif
            throw SignUpAuthError.from(error)
        }
    }

    @discardableResult
    func verifyEmailOTP(email: String, token: String) async throws -> Session {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SignUpAuthError.unknown("Enter a valid email address.")
        }
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedToken.count == SignUpOTPConfig.length else {
            throw SignUpAuthError.invalidOTP
        }
        do {
            let response = try await client.auth.verifyOTP(
                email: trimmed,
                token: normalizedToken,
                type: .email,
                redirectTo: nil
            )
            switch response {
            case .session(let session):
                return session
            case .user:
                if let session = try? await client.auth.session {
                    return session
                }
                throw SignUpAuthError.noSession
            }
        } catch {
            throw SignUpAuthError.from(error)
        }
    }

    // MARK: - Profiles

    func fetchProfile() async throws -> UserProfile? {
        let userId = try await currentUserId()
        let profiles: [UserProfile] = try await client
            .from("profiles")
            .select()
            .eq("id", value: userId.uuidString)
            .limit(1)
            .execute()
            .value
        return profiles.first
    }

    func upsertProfile(fullName: String, email: String, phone: String?) async throws {
        let userId = try await currentUserId()
        let row = ProfileUpsertRow(
            id: userId,
            fullName: fullName.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            phone: phone
        )
        try await client
            .from("profiles")
            .upsert(row)
            .execute()
    }

    func updateNotificationsEnabled(_ enabled: Bool) async throws {
        let userId = try await currentUserId()
        try await client
            .from("profiles")
            .update(["notifications_enabled": enabled])
            .eq("id", value: userId.uuidString)
            .execute()
    }

    // MARK: - Pet CRUD

    func fetchCurrentPet() async throws -> Pet? {
        try await fetchAllPets(limit: 1).last
    }

    func fetchAllPets(limit: Int = 2) async throws -> [Pet] {
        MockUserSettings.logVerbose("fetchAllPets(limit: \(limit))")
        let userId = try await currentUserId()
        let pets: [Pet] = try await client
            .from("pets")
            .select()
            .eq("user_id", value: userId.uuidString)
            .order("created_at", ascending: true)
            .limit(limit)
            .execute()
            .value
        return pets
    }

    func deletePet(petId: UUID) async throws {
        try await client
            .from("pets")
            .delete()
            .eq("id", value: petId.uuidString)
            .execute()
    }

    /// Permanently deletes the signed-in user and all associated data via edge function.
    func deleteAccount() async throws {
        struct DeleteAccountResponse: Decodable {
            let success: Bool?
            let error: String?
        }

        let response: DeleteAccountResponse = try await client.functions.invoke(
            "delete-account",
            options: FunctionInvokeOptions(method: .post)
        )

        if response.success != true {
            throw SignUpAuthError.unknown(response.error ?? "Could not delete your account.")
        }
    }

    func savePet(_ pet: Pet) async throws -> Pet {
        let saved: Pet = try await client
            .from("pets")
            .upsert(pet)
            .select()
            .single()
            .execute()
            .value
        return saved
    }

    func updatePetExpressions(petId: UUID, expressions: ExpressionMap) async throws {
        try await client
            .from("pets")
            .update(["expressions": expressions])
            .eq("id", value: petId.uuidString)
            .execute()
    }

    func updatePetName(petId: UUID, name: String) async throws {
        try await client
            .from("pets")
            .update(["name": name])
            .eq("id", value: petId.uuidString)
            .execute()
    }

    func updatePetHomeLocation(petId: UUID, lat: Double, lng: Double, address: String?) async throws {
        struct HomeLocationUpdate: Encodable {
            let home_lat: Double
            let home_lng: Double
            let home_address: String?
        }
        let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await client
            .from("pets")
            .update(HomeLocationUpdate(
                home_lat: lat,
                home_lng: lng,
                home_address: (trimmed?.isEmpty == false) ? trimmed : nil
            ))
            .eq("id", value: petId.uuidString)
            .execute()
    }

    func getStoredPhotoURLs(petId: UUID) async throws -> [String] {
        var urls: [String] = []
        for i in 0..<5 {
            let path = "\(petId.uuidString)/photo_\(i).jpg"
            if let url = try? await client.storage
                .from("pet-photos")
                .createSignedURL(path: path, expiresIn: 3600) {
                urls.append(url.absoluteString)
            }
        }
        return urls
    }

    // MARK: - Messages

    func fetchLatestMessage(for petId: UUID) async throws -> PetMessage? {
        let messages: [PetMessage] = try await client
            .from("messages")
            .select()
            .eq("pet_id", value: petId.uuidString)
            .not("sent_at", operator: .is, value: "null")
            .order("sent_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return messages.first
    }

    func fetchMessage(by id: UUID) async throws -> PetMessage? {
        let messages: [PetMessage] = try await client
            .from("messages")
            .select()
            .eq("id", value: id.uuidString)
            .limit(1)
            .execute()
            .value
        return messages.first
    }

    func fetchRecentMessages(for petId: UUID, limit: Int = 20) async throws -> [PetMessage] {
        let messages: [PetMessage] = try await client
            .from("messages")
            .select()
            .eq("pet_id", value: petId.uuidString)
            .not("sent_at", operator: .is, value: "null")
            .order("sent_at", ascending: false)
            .limit(limit)
            .execute()
            .value
        return messages
    }

    func saveMessage(_ message: PetMessage) async throws {
        try await client
            .from("messages")
            .insert(message)
            .execute()
    }

    // MARK: - Storage

    func uploadPetPhoto(petId: UUID, imageData: Data, index: Int) async throws -> String {
        let path = "\(petId.uuidString)/photo_\(index).jpg"
        try await client.storage
            .from("pet-photos")
            .upload(path, data: imageData, options: FileOptions(contentType: "image/jpeg"))
        let publicURL = try client.storage
            .from("pet-photos")
            .getPublicURL(path: path)
        return publicURL.absoluteString
    }

    func downloadSprite(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    // MARK: - Sprite Generation (calls edge function)

    /// Calls the `generate-sprites` edge function. The deployed function
    /// returns synchronously after Stage A (the `happy` base sprite) and then
    /// fills in the remaining 5 expressions in the background, writing them
    /// directly to the `pets.expressions` row.
    ///
    /// Use `observePetExpressions(petId:)` afterwards to pick up Stage B
    /// updates as they land.
    func generateSprites(petId: UUID, photoURLs: [String], petName: String, species: Species) async throws -> ExpressionMap {
        struct GenerateRequest: Encodable {
            let petId: String
            let photoURLs: [String]
            let petName: String
            let species: String
            enum CodingKeys: String, CodingKey {
                case petId = "pet_id"
                case photoURLs = "photo_urls"
                case petName = "pet_name"
                case species
            }
        }
        let response: ExpressionMap = try await client.functions
            .invoke(
                "generate-sprites",
                options: FunctionInvokeOptions(
                    body: GenerateRequest(
                        petId: petId.uuidString,
                        photoURLs: photoURLs,
                        petName: petName,
                        species: species.rawValue
                    )
                )
            )
        return response
    }

    /// Fetches a single pet row by id. Subject to RLS — caller must own the row.
    func fetchPet(by petId: UUID) async throws -> Pet? {
        let pets: [Pet] = try await client
            .from("pets")
            .select()
            .eq("id", value: petId.uuidString)
            .limit(1)
            .execute()
            .value
        return pets.first
    }

    /// Polls the `pets` row for expression updates and yields a fresh
    /// `ExpressionMap` whenever a new expression is written by the edge
    /// function's Stage B. Finishes when all 6 expressions are present or
    /// the timeout elapses.
    func observePetExpressions(
        petId: UUID,
        timeout: TimeInterval = 300,
        pollInterval: TimeInterval = 3
    ) -> AsyncThrowingStream<ExpressionMap, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let deadline = Date().addingTimeInterval(timeout)
                var lastCount = -1
                while Date() < deadline {
                    if Task.isCancelled { break }
                    do {
                        if let pet = try await self.fetchPet(by: petId) {
                            let count = Self.filledExpressionCount(pet.expressions)
                            if count != lastCount {
                                continuation.yield(pet.expressions)
                                lastCount = count
                            }
                            if count >= 6 {
                                continuation.finish()
                                return
                            }
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func filledExpressionCount(_ map: ExpressionMap) -> Int {
        [map.happy, map.sleepy, map.mad, map.excited, map.missesYou, map.judging]
            .compactMap { $0 }.count
    }

    // MARK: - Device token registration (APNs)

    func registerDeviceToken(_ token: String) async throws {
        let userId = try await currentUserId()
        // The APNs token's environment must match how the build is signed: debug installs use the
        // sandbox APNs environment, while Release (TestFlight/App Store) use production. The server
        // routes the push host/topic/key off this value, so a wrong label means pushes never arrive.
        #if DEBUG
        let environment = "development"
        #else
        let environment = "production"
        #endif
        try await client
            .from("device_tokens")
            .upsert([
                "user_id": userId.uuidString,
                "token": token,
                "platform": "ios",
                "environment": environment,
            ], onConflict: "user_id, token")
            .execute()
    }

    // MARK: - Location event (calls edge function)

    func reportLocationEvent(petId: UUID, event: String) async throws -> PetMessage {
        struct LocationRequest: Encodable {
            let petId: String
            let event: String
            enum CodingKeys: String, CodingKey {
                case petId = "pet_id"
                case event
            }
        }
        let response: PetMessage = try await client.functions
            .invoke(
                "location-event",
                options: FunctionInvokeOptions(
                    body: LocationRequest(petId: petId.uuidString, event: event)
                ),
                decoder: PostgrestClient.Configuration.jsonDecoder
            )
        return response
    }
}

// MARK: - Profile upsert payload

private struct ProfileUpsertRow: Encodable {
    let id: UUID
    let fullName: String
    let email: String
    let phone: String?
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case fullName = "full_name"
        case email
        case phone
        case updatedAt = "updated_at"
    }

    init(id: UUID, fullName: String, email: String, phone: String?) {
        self.id = id
        self.fullName = fullName
        self.email = email
        self.phone = phone?.isEmpty == true ? nil : phone
        self.updatedAt = ISO8601DateFormatter().string(from: Date())
    }
}
