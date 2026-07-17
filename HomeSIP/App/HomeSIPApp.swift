import SwiftUI
import Intents

@main
struct HomeSIPApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onContinueUserActivity("INStartCallIntent") { activity in
                    // L'estensione Intents (IntentHandler) non può avviare la
                    // chiamata SIP da sola (nessun accesso al Core Linphone):
                    // risponde con .continueInApp e questo blocco riceve
                    // l'intent risolto per completare davvero la chiamata.
                    guard
                        let intent = activity.interaction?.intent as? INStartCallIntent,
                        let handle = intent.contacts?.first?.personHandle?.value,
                        !handle.isEmpty
                    else { return }
                    CallManager.shared.startCall(to: handle)
                }
        }
    }
}
