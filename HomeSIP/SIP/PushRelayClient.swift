import Foundation

/// Comunica con il push relay (repo separato manuzzi/SIP-Phone-PushRelay).
final class PushRelayClient {

    static let shared = PushRelayClient()

    /// Da chiamare ogni volta che PushKit emette un nuovo device token.
    func registerDeviceToken(_ token: String) {
        post(path: "/register-token", body: ["deviceToken": token], successLog: "device token registrato sul relay")
    }

    /// Da chiamare non appena la registrazione SIP ha successo: sblocca
    /// eventuali chiamate che il relay sta trattenendo in Stasis in attesa
    /// che l'app si ri-registri dopo un risveglio da VoIP push.
    func notifyDeviceReady() {
        post(path: "/device-ready", body: nil, successLog: "device pronto segnalato al relay")
    }

    private func post(path: String, body: [String: String]?, successLog: String) {
        guard let url = URL(string: "\(PushRelayConfig.baseURL)\(path)") else {
            print("PushRelayClient: URL relay non valido")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(PushRelayConfig.sharedSecret)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                print("PushRelayClient: richiesta a \(path) fallita: \(error)")
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 204 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("PushRelayClient: risposta inattesa da \(path) (status \(status))")
                return
            }
            print("PushRelayClient: \(successLog)")
        }.resume()
    }
}
