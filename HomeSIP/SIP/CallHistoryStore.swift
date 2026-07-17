import Foundation

/// Log persistente di chiamate perse e problemi di raggiungibilità del
/// server, pensato per il test sul campo di M5 (poter verificare a posteriori
/// se e quando qualcosa è andato storto, non solo osservarlo mentre succede).
struct CallEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case missedCall = "Chiamata persa"
        case serverUnreachable = "Server irraggiungibile"
    }

    let id: UUID
    let date: Date
    let kind: Kind
    let detail: String
}

enum CallHistoryStore {
    private static let key = "call_history_events"
    private static let maxEntries = 200

    static func log(kind: CallEvent.Kind, detail: String) {
        var events = all()
        events.insert(CallEvent(id: UUID(), date: Date(), kind: kind, detail: detail), at: 0)
        if events.count > maxEntries {
            events = Array(events.prefix(maxEntries))
        }
        save(events)
    }

    static func all() -> [CallEvent] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let events = try? JSONDecoder().decode([CallEvent].self, from: data) else {
            return []
        }
        return events
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(_ events: [CallEvent]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
