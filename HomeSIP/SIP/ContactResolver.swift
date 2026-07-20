import Contacts

/// Risolve un numero SIP/telefonico contro la rubrica di sistema, per
/// mostrare il nome del contatto invece del solo numero — sia nella UI
/// dell'app che (indirettamente, vedi CXHandle in CallManager) nella
/// schermata di chiamata e nei Recenti di sistema.
enum ContactResolver {
    private static let store = CNContactStore()

    static func requestAccessIfNeeded() {
        CNContactStore().requestAccess(for: .contacts) { _, _ in }
    }

    /// Cerca un contatto il cui numero corrisponda. Usa CNPhoneNumber per il
    /// confronto, che normalizza da solo differenze di formattazione
    /// (spazi, prefisso internazionale, ecc.) — molto più affidabile di un
    /// confronto testuale diretto.
    static func displayName(forNumber number: String) -> String? {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }

        let predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: number))
        let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        guard
            let contacts = try? store.unifiedContacts(matching: predicate, keysToFetch: keys as [CNKeyDescriptor]),
            let contact = contacts.first
        else {
            return nil
        }
        return CNContactFormatter.string(from: contact, style: .fullName)
    }
}
