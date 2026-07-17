import UIKit
import PushKit

/// Necessario per PushKit: il ciclo di vita puramente SwiftUI non garantisce
/// che il codice giri quando l'app viene risvegliata in background da una
/// VoIP push (senza che nessuna view sia mai apparsa a schermo).
final class AppDelegate: NSObject, UIApplicationDelegate {

    private var pushRegistry: PKPushRegistry?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        SIPSettings.registerDefaults()
        SIPManager.shared.start()

        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        pushRegistry = registry

        return true
    }
}

extension AppDelegate: PKPushRegistryDelegate {

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        PushRelayClient.shared.registerDeviceToken(token)
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        // Nessuna azione lato app: il relay scoprirà il token non più valido
        // al prossimo invio (risposta 410 di APNs) e lo scarterà da sé.
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }

        let callerNumber = payload.dictionaryPayload["callerNumber"] as? String ?? ""
        let callerName = payload.dictionaryPayload["callerName"] as? String ?? callerNumber

        // Obbligatorio per policy Apple: ogni VoIP push ricevuta deve tradursi
        // immediatamente in una chiamata riportata a CallKit, altrimenti iOS
        // può arrivare a revocare l'entitlement PushKit dell'app.
        CallManager.shared.reportPushTriggeredIncomingCall(callerNumber: callerNumber, callerName: callerName)

        completion()
    }
}
