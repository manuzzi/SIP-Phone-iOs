import Foundation

/// Parametri dell'account SIP, configurabili dall'utente in Impostazioni di
/// sistema (Impostazioni > HomeSIP, vedi Settings.bundle) invece che
/// hardcoded nel codice sorgente.
enum SIPSettings {
    private static let usernameKey = "sip_username"
    private static let passwordKey = "sip_password"
    private static let domainKey = "sip_domain"

    /// Da chiamare all'avvio dell'app: Impostazioni di sistema non popola
    /// UserDefaults con i DefaultValue di Root.plist finché l'utente non
    /// apre almeno una volta quella schermata, quindi registriamo noi stessi
    /// una base coerente per poter distinguere "non configurato" in modo affidabile.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            usernameKey: "",
            passwordKey: "",
            domainKey: "",
        ])
    }

    static var username: String { UserDefaults.standard.string(forKey: usernameKey) ?? "" }
    static var password: String { UserDefaults.standard.string(forKey: passwordKey) ?? "" }
    static var domain: String { UserDefaults.standard.string(forKey: domainKey) ?? "" }

    static var isConfigured: Bool {
        !username.isEmpty && !password.isEmpty && !domain.isEmpty
    }
}
