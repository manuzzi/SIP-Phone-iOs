import Foundation
import linphonesw

/// Spike M0: registrazione SIP e chiamata di base verso l'interno di test (101),
/// per validare che l'audio funzioni end-to-end contro l'Asterisk di casa prima
/// di costruire CallKit/PushKit (M1/M2) sopra questa base.
///
/// Credenziali hardcoded volutamente: verranno spostate in una schermata di
/// configurazione persistita in una milestone successiva (vedi PIANO_SVILUPPO.md).
final class SIPManager: ObservableObject {

    @Published var registrationState: String = "Non avviato"
    @Published var callState: String = "Nessuna chiamata"

    private let sipUsername = SIPCredentials.username
    private let sipPassword = SIPCredentials.password
    private let sipDomain = SIPCredentials.domain

    private var core: Core!
    private var coreDelegate: CoreDelegateStub!
    private var iterateTimer: Timer?

    func start() {
        do {
            let factory = Factory.Instance
            core = try factory.createCore(configPath: "", factoryConfigPath: "", systemContext: nil)

            coreDelegate = CoreDelegateStub(
                onCallStateChanged: { [weak self] _, _, state, message in
                    DispatchQueue.main.async {
                        self?.callState = "\(state) — \(message)"
                    }
                },
                onAccountRegistrationStateChanged: { [weak self] _, account, state, message in
                    DispatchQueue.main.async {
                        self?.registrationState = "\(state) — \(message)"
                    }
                }
            )
            core.addDelegate(delegate: coreDelegate)

            try core.start()

            // core.iterate() deve essere chiamato periodicamente per processare
            // gli eventi SIP/RTP: nessun meccanismo automatico senza shared core.
            iterateTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
                self?.core.iterate()
            }

            try registerAccount()
        } catch {
            registrationState = "Errore avvio: \(error)"
        }
    }

    private func registerAccount() throws {
        let factory = Factory.Instance

        let authInfo = try factory.createAuthInfo(
            username: sipUsername,
            userid: "",
            passwd: sipPassword,
            ha1: "",
            realm: "",
            domain: sipDomain
        )

        let accountParams = try core.createAccountParams()

        let identity = try factory.createAddress(addr: "sip:\(sipUsername)@\(sipDomain)")
        try accountParams.setIdentityaddress(newValue: identity)

        let serverAddress = try factory.createAddress(addr: "sip:\(sipDomain)")
        try serverAddress.setTransport(newValue: .Udp)
        try accountParams.setServeraddress(newValue: serverAddress)

        accountParams.registerEnabled = true

        let account = try core.createAccount(params: accountParams)
        core.addAuthInfo(info: authInfo)
        try core.addAccount(account: account)
        core.defaultAccount = account
    }

    /// Chiama un altro interno (es. "100") o un numero esterno via trunk Vodafone.
    func call(to destination: String) {
        guard let core else { return }
        do {
            let address = try Factory.Instance.createAddress(addr: "sip:\(destination)@\(sipDomain)")
            let params = try core.createCallParams(call: nil)
            _ = core.inviteAddressWithParams(addr: address, params: params)
        } catch {
            callState = "Errore chiamata: \(error)"
        }
    }

    func hangup() {
        try? core?.currentCall?.terminate()
    }
}
