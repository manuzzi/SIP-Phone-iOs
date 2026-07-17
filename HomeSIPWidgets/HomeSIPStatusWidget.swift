import WidgetKit
import SwiftUI

struct HomeSIPStatusEntry: TimelineEntry {
    let date: Date
    let isReachable: Bool
    let registrationState: String
    /// true se lo stato viene dall'app (confermato di recente), false se
    /// il widget stesso ha dovuto verificarlo con una sonda di riserva
    /// perché l'app non aggiornava lo stato condiviso da troppo tempo.
    let isFromApp: Bool
}

struct HomeSIPStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> HomeSIPStatusEntry {
        HomeSIPStatusEntry(date: Date(), isReachable: true, registrationState: "Ok", isFromApp: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (HomeSIPStatusEntry) -> Void) {
        completion(entryFromSharedStatus())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeSIPStatusEntry>) -> Void) {
        Task {
            let entry = await resolvedEntry()
            // L'app stessa sollecita un refresh immediato ad ogni cambio di
            // stato (WidgetCenter.reloadAllTimelines()): questa scadenza è
            // solo un fallback per il caso in cui l'app resti a lungo senza
            // aggiornare nulla.
            let nextRefresh = Date().addingTimeInterval(15 * 60)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }

    private func entryFromSharedStatus() -> HomeSIPStatusEntry {
        let snapshot = SharedStatus.read()
        return HomeSIPStatusEntry(date: Date(), isReachable: snapshot.isReachable, registrationState: snapshot.registrationState, isFromApp: true)
    }

    /// Se l'app ha aggiornato lo stato di recente ci si fida di quello
    /// (riflette la registrazione SIP reale, non solo la raggiungibilità di
    /// rete). Altrimenti — app sospesa da tempo, nessun motivo di
    /// risvegliarsi — il widget prova da solo una sonda diretta al server.
    private func resolvedEntry() async -> HomeSIPStatusEntry {
        let snapshot = SharedStatus.read()
        let staleThreshold: TimeInterval = 8 * 60
        let isStale = snapshot.lastUpdate.map { Date().timeIntervalSince($0) > staleThreshold } ?? true

        guard isStale, !snapshot.domain.isEmpty else {
            return HomeSIPStatusEntry(date: Date(), isReachable: snapshot.isReachable, registrationState: snapshot.registrationState, isFromApp: true)
        }

        let reachable = await withCheckedContinuation { continuation in
            ServerReachabilityProbe.check(host: snapshot.domain, port: 5060) { result in
                continuation.resume(returning: result)
            }
        }
        return HomeSIPStatusEntry(date: Date(), isReachable: reachable, registrationState: snapshot.registrationState, isFromApp: false)
    }
}

struct HomeSIPStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HomeSIPStatusEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            accessoryCircularView
        case .accessoryRectangular:
            accessoryRectangularView
        default:
            homeScreenView
        }
    }

    private var homeScreenView: some View {
        VStack(spacing: 6) {
            Image(systemName: entry.isReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title)
                .foregroundStyle(entry.isReachable ? .green : .red)
            Text(entry.isReachable ? "HomeSIP OK" : "HomeSIP offline")
                .font(.caption.bold())
                .multilineTextAlignment(.center)
            if !entry.isFromApp {
                Text("verificato ora")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .widgetBackground()
    }

    private var accessoryCircularView: some View {
        Image(systemName: entry.isReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.title2)
            .widgetBackground()
    }

    private var accessoryRectangularView: some View {
        HStack {
            Image(systemName: entry.isReachable ? "checkmark.circle.fill" : "xmark.circle.fill")
            Text(entry.isReachable ? "HomeSIP OK" : "HomeSIP offline")
                .font(.caption)
        }
        .widgetBackground()
    }
}

private extension View {
    /// `containerBackground(for:.widget)` serve dall'iOS 17 in poi; sulle
    /// versioni precedenti WidgetKit applica da solo uno sfondo di sistema.
    @ViewBuilder
    func widgetBackground() -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(.fill.tertiary, for: .widget)
        } else {
            self
        }
    }
}

struct HomeSIPStatusWidget: Widget {
    let kind = "HomeSIPStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HomeSIPStatusProvider()) { entry in
            HomeSIPStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Stato HomeSIP")
        .description("Registrazione SIP e raggiungibilità del centralino Asterisk.")
        .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        if #available(iOS 16.0, *) {
            return [.systemSmall, .accessoryCircular, .accessoryRectangular]
        } else {
            return [.systemSmall]
        }
    }
}

@available(iOS 17.0, *)
#Preview(as: .systemSmall) {
    HomeSIPStatusWidget()
} timeline: {
    HomeSIPStatusEntry(date: .now, isReachable: true, registrationState: "Ok", isFromApp: true)
    HomeSIPStatusEntry(date: .now, isReachable: false, registrationState: "Failed", isFromApp: false)
}
