import SwiftUI

/// Registro di chiamate perse e problemi di raggiungibilità del server,
/// pensato per essere consultato durante il test sul campo di M5.
struct CallHistoryView: View {
    @State private var events: [CallEvent] = CallHistoryStore.all()

    var body: some View {
        NavigationView {
            Group {
                if events.isEmpty {
                    Text("Nessun evento registrato.")
                        .foregroundStyle(.secondary)
                } else {
                    List(events) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: event.kind == .missedCall ? "phone.down.fill" : "wifi.slash")
                                    .foregroundStyle(event.kind == .missedCall ? .red : .orange)
                                Text(event.kind.rawValue)
                                    .font(.subheadline.bold())
                            }
                            Text(event.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(event.date.formatted(date: .abbreviated, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .navigationTitle("Registro eventi")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Svuota") {
                        CallHistoryStore.clear()
                        events = []
                    }
                    .disabled(events.isEmpty)
                }
            }
        }
    }
}

#Preview {
    CallHistoryView()
}
