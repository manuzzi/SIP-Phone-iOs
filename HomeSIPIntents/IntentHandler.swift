import Intents

/// Gestisce INStartCallIntent per far comparire HomeSIP come opzione di
/// chiamata nell'app Contatti e permettere il comando vocale Siri
/// "Chiama [nome] con HomeSIP".
///
/// L'estensione gira in un processo separato e sandboxato, senza accesso al
/// Core Linphone: risponde sempre con `.continueInApp`, che fa lanciare
/// HomeSIP passando l'intent tramite NSUserActivity — è lì (vedi
/// HomeSIPApp.onContinueUserActivity) che la chiamata SIP viene avviata
/// davvero.
class IntentHandler: INExtension, INStartCallIntentHandling {

    override func handler(for intent: INIntent) -> Any {
        self
    }

    func resolveContacts(for intent: INStartCallIntent, with completion: @escaping ([INStartCallContactResolutionResult]) -> Void) {
        guard let person = intent.contacts?.first, person.personHandle?.value?.isEmpty == false else {
            completion([INStartCallContactResolutionResult.unsupported(forReason: .noContactFound)])
            return
        }
        completion([INStartCallContactResolutionResult(personResolutionResult: .success(with: person))])
    }

    func resolveCallCapability(for intent: INStartCallIntent, with completion: @escaping (INStartCallCallCapabilityResolutionResult) -> Void) {
        completion(INStartCallCallCapabilityResolutionResult(callCapabilityResolutionResult: .success(with: .audioCall)))
    }

    func handle(intent: INStartCallIntent, completion: @escaping (INStartCallIntentResponse) -> Void) {
        let response = INStartCallIntentResponse(code: .continueInApp, userActivity: NSUserActivity(activityType: "INStartCallIntent"))
        completion(response)
    }
}
