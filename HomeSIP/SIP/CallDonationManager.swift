import Intents

/// Dona un'interazione INStartCallIntent dopo ogni chiamata connessa: è
/// questo storico di donazioni (non un'impostazione statica) che permette a
/// Siri e all'app Contatti di imparare ad associare un numero/interno a
/// HomeSIP e proporlo come opzione di chiamata.
enum CallDonationManager {
    static func donateCall(handle: String, displayName: String) {
        let person = INPerson(
            personHandle: INPersonHandle(value: handle, type: .unknown),
            nameComponents: nil,
            displayName: displayName,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: nil
        )
        let intent = INStartCallIntent(
            callRecordFilter: nil,
            callRecordToCallBack: nil,
            audioRoute: .unknown,
            destinationType: .normal,
            contacts: [person],
            callCapability: .audioCall
        )
        INInteraction(intent: intent, response: nil).donate { error in
            if let error {
                print("CallDonationManager: donazione fallita: \(error)")
            }
        }
    }
}
