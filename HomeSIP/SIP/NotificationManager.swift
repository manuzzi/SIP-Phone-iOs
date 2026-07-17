import UserNotifications

/// Notifica localmente l'utente quando il centralino SIP non è raggiungibile,
/// senza richiedere che l'app sia aperta per accorgersene.
enum NotificationManager {
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                print("NotificationManager: autorizzazione notifiche fallita: \(error)")
            }
        }
    }

    static func notifyServerUnreachable(detail: String) {
        let content = UNMutableNotificationContent()
        content.title = "HomeSIP"
        content.body = "Impossibile registrarsi al centralino SIP (\(detail)). Verifica la connessione di rete."
        content.sound = .default

        // Stesso identifier ad ogni invio: se per qualche motivo ne partisse
        // più di una prima che l'utente la veda, la sostituisce invece di
        // accumulare notifiche duplicate.
        let request = UNNotificationRequest(identifier: "sip-unreachable", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("NotificationManager: invio notifica fallito: \(error)")
            }
        }
    }
}
