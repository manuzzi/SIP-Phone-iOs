import AppIntents
import SwiftUI
import WidgetKit

/// Intent minimo il cui unico scopo è aprire l'app quando si tocca il
/// controllo nel Centro di Controllo — `openAppWhenRun` fa tutto il lavoro,
/// non serve altro nella `perform()`.
@available(iOS 18.0, *)
struct OpenHomeSIPIntent: AppIntent {
    static var title: LocalizedStringResource = "Apri HomeSIP"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

@available(iOS 18.0, *)
struct HomeSIPControlValueProvider: ControlValueProvider {
    var previewValue: Bool { true }

    func currentValue() async throws -> Bool {
        SharedStatus.read().isReachable
    }
}

@available(iOS 18.0, *)
struct HomeSIPStatusControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "work.manuzzi.homesip.control.status", provider: HomeSIPControlValueProvider()) { isReachable in
            ControlWidgetButton(action: OpenHomeSIPIntent()) {
                Label(
                    isReachable ? "HomeSIP OK" : "HomeSIP offline",
                    systemImage: isReachable ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
            }
        }
        .displayName("Stato HomeSIP")
        .description("Registrazione SIP e raggiungibilità del centralino Asterisk.")
    }
}
