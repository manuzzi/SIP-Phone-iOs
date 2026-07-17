import Foundation

/// Stato condiviso tra l'app principale e le estensioni widget/controllo
/// (M5.1) tramite App Group. Le estensioni non vedono `UserDefaults.standard`
/// dell'app principale (dominio separato per bundle ID, anche se stessa app):
/// serve un contenitore condiviso esplicito.
enum SharedStatus {
    static let appGroupID = "group.work.manuzzi.homesip"

    private static let registrationStateKey = "shared_registration_state"
    private static let isReachableKey = "shared_is_reachable"
    private static let lastUpdateKey = "shared_last_update"
    private static let domainKey = "shared_sip_domain"

    struct Snapshot {
        let registrationState: String
        let isReachable: Bool
        let lastUpdate: Date?
        let domain: String
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Da chiamare dall'app principale ad ogni cambio di stato registrazione:
    /// `domain` va rispecchiato qui perché le estensioni non possono leggere
    /// SIPSettings (che vive in UserDefaults.standard dell'app principale).
    static func write(registrationState: String, isReachable: Bool, domain: String) {
        guard let defaults else { return }
        defaults.set(registrationState, forKey: registrationStateKey)
        defaults.set(isReachable, forKey: isReachableKey)
        defaults.set(Date(), forKey: lastUpdateKey)
        defaults.set(domain, forKey: domainKey)
    }

    static func read() -> Snapshot {
        guard let defaults else {
            return Snapshot(registrationState: "Sconosciuto", isReachable: false, lastUpdate: nil, domain: "")
        }
        return Snapshot(
            registrationState: defaults.string(forKey: registrationStateKey) ?? "Sconosciuto",
            isReachable: defaults.bool(forKey: isReachableKey),
            lastUpdate: defaults.object(forKey: lastUpdateKey) as? Date,
            domain: defaults.string(forKey: domainKey) ?? ""
        )
    }
}
