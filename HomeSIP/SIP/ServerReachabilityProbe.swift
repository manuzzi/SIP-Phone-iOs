import Foundation
import Network

/// Verifica che il centralino SIP sia davvero raggiungibile (non solo che
/// l'interfaccia di rete "esista") prima di tentare una ri-registrazione.
///
/// Il motivo per cui serve: un'interfaccia VPN può risultare "up" per
/// NWPathMonitor qualche secondo prima che il tunnel abbia davvero finito di
/// negoziare col server. Tentare la REGISTER in quella finestra non fallisce
/// e basta — resta bloccata su "Progress" perché il connect() TCP sottostante
/// si blocca contro un percorso che non porta ancora da nessuna parte, e
/// né `networkReachable` né `refreshRegisters()` riescono a sbloccarla
/// (osservato: un riavvio completo del Core lo risolveva, ma a costo di
/// rompere anche le transizioni che già funzionavano, es. VPN -> WiFi).
/// Una sonda diretta sul server, invece di indovinare un'attesa fissa,
/// evita del tutto la finestra: si ri-registra solo quando il server
/// risponde davvero.
enum ServerReachabilityProbe {
    static func check(host: String, port: UInt16, timeout: TimeInterval = 3, completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            completion(false)
            return
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "com.manuzzi.homesip.reachabilityprobe")
        var didComplete = false

        func finish(_ result: Bool) {
            guard !didComplete else { return }
            didComplete = true
            connection.cancel()
            DispatchQueue.main.async { completion(result) }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(true)
            case .failed, .cancelled:
                finish(false)
            default:
                break
            }
        }

        queue.asyncAfter(deadline: .now() + timeout) {
            finish(false)
        }

        connection.start(queue: queue)
    }
}
