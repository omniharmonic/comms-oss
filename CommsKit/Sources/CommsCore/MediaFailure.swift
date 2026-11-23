import CommsClient
import Foundation
import PrismTransport

/// Is a media fetch failure permanent for this token (worth remembering), or transient
/// (offline, timeout, 5xx — try again next time it is needed)?
///
/// Permanent: 404 (most bridged avatars: the homeserver no longer has the file), 410 (the
/// token expired; a refetch of the thread brings a fresh one), and bytes that are not an
/// image (`undecodable`, decided by the caller).
public enum MediaFailure {
    public static func isPermanent(_ error: any Error) -> Bool {
        if let e = error as? CommsError {
            switch e {
            case .mediaExpired, .threadUnavailable: return true
            default: return false
            }
        }
        if let e = error as? PrismError, let status = e.httpStatus { return status == 404 || status == 410 }
        return false
    }
}
