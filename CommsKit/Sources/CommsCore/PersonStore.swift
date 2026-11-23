import CommsClient
import Foundation
import Observation

/// One contact card: a vault person loaded from `GET /people/:id` (their phones, emails,
/// handles and every conversation shared with them).
@MainActor @Observable
public final class PersonStore {
    public let personID: String
    public private(set) var person: CommsPerson?
    public private(set) var isLoading = false
    public private(set) var error: String?

    @ObservationIgnored private let fetch: @Sendable (String) async throws -> CommsPerson
    @ObservationIgnored private var generation = 0

    public init(personID: String, fetch: @escaping @Sendable (String) async throws -> CommsPerson) {
        self.personID = personID
        self.fetch = fetch
    }

    public convenience init(backend: any ChatBackend, personID: String) {
        self.init(personID: personID, fetch: { [backend] id in try await backend.person(id: id) })
    }

    /// The conversations shared with this person, newest activity first, excluding `except`
    /// (the one already open).
    public func sharedThreads(except threadID: String? = nil) -> [CommsThread] {
        (person?.threads ?? []).filter { $0.id != threadID }.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    public func load() async {
        generation += 1
        let gen = generation
        isLoading = true
        defer { if gen == generation { isLoading = false } }
        do {
            let p = try await fetch(personID)
            guard gen == generation else { return }
            person = p
            error = nil
        } catch {
            guard gen == generation, !(error is CancellationError) else { return }
            if case .personUnavailable? = error as? CommsError {
                // Unknown, merged or superseded: nothing to show any more.
                person = nil
                self.error = "This contact is no longer available."
            } else {
                self.error = "Couldn't load this contact."
            }
        }
    }
}
