import Foundation
import linphonesw

/// Registrazione SIP e gestione delle chiamate verso l'interno di test (101).
/// Le decisioni sull'interfaccia di sistema (schermata di chiamata, Recenti)
/// sono delegate a CallManager: qui viviamo solo il livello SIP/RTP.
///
/// Credenziali hardcoded volutamente in SIPCredentials.swift (non versionato):
/// verranno spostate in una schermata di configurazione persistita in una
/// milestone successiva (vedi PIANO_SVILUPPO.md).
final class SIPManager: ObservableObject {

    /// Singleton: deve poter essere avviato da AppDelegate (risveglio in
    /// background su VoIP push) indipendentemente dal ciclo di vita delle view.
    static let shared = SIPManager()

    @Published var registrationState: String = "Non avviato"
    @Published var callState: String = "Nessuna chiamata"
    @Published var isCallActive: Bool = false
    @Published var isIncomingRinging: Bool = false
    @Published var remoteDisplayName: String = ""

    private let sipUsername = SIPCredentials.username
    private let sipPassword = SIPCredentials.password
    private let sipDomain = SIPCredentials.domain

    private var core: Core!
    private var coreDelegate: CoreDelegateStub!
    private var iterateTimer: Timer?

    func start() {
        guard core == nil else { return } // già avviato (es. da AppDelegate e poi da ContentView)

        CallManager.shared.sipManager = self

        do {
            let factory = Factory.Instance
            core = try factory.createCore(configPath: "", factoryConfigPath: "", systemContext: nil)

            // Lascia che sia CallKit a guidare l'attivazione della sessione audio
            // (vedi CallManager.provider(_:didActivate/didDeactivate:)). Sul simulatore
            // CallKit non viene usato (vedi CallManager), quindi il Core gestisce
            // l'audio session in autonomia come in M0.
            #if !targetEnvironment(simulator)
            core.callkitEnabled = true
            #endif

            coreDelegate = CoreDelegateStub(
                onCallStateChanged: { [weak self] _, call, state, message in
                    self?.handleCallStateChanged(call: call, state: state, message: message)
                },
                onAccountRegistrationStateChanged: { [weak self] _, account, state, message in
                    DispatchQueue.main.async {
                        self?.registrationState = "\(state) — \(message)"
                    }
                    if state == .Ok {
                        // Sblocca eventuali chiamate che il push relay sta
                        // trattenendo in Stasis in attesa che l'app si
                        // ri-registri dopo un risveglio da VoIP push.
                        PushRelayClient.shared.notifyDeviceReady()
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

    // MARK: - Stato chiamata → CallKit

    private func handleCallStateChanged(call: Call, state: Call.State, message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.callState = "\(state) — \(message)"
            switch state {
            case .Released:
                self.isCallActive = false
                self.isIncomingRinging = false
                self.remoteDisplayName = ""
            case .IncomingReceived:
                self.isCallActive = true
                self.isIncomingRinging = true
                if let addr = call.remoteAddress {
                    self.remoteDisplayName = addr.displayName ?? addr.username ?? addr.asStringUriOnly()
                }
            default:
                self.isCallActive = true
                self.isIncomingRinging = false
                if let addr = call.remoteAddress {
                    self.remoteDisplayName = addr.displayName ?? addr.username ?? addr.asStringUriOnly()
                }
            }
        }

        switch state {
        case .IncomingReceived:
            let handle = call.remoteAddress?.asStringUriOnly() ?? "sconosciuto"
            let displayName = call.remoteAddress?.displayName ?? call.remoteAddress?.username ?? handle
            CallManager.shared.reportIncomingCall(handle: handle, displayName: displayName)
        case .StreamsRunning:
            if call.dir == .Outgoing {
                CallManager.shared.reportOutgoingCallConnected()
            }
        case .End, .Error:
            CallManager.shared.reportCallEnded()
        default:
            break
        }
    }

    // MARK: - Azioni richieste da CallManager

    /// Chiama un altro interno (es. "100") o un numero esterno via trunk Vodafone.
    func placeCall(to destination: String) {
        guard let core else { return }
        do {
            let address = try Factory.Instance.createAddress(addr: "sip:\(destination)@\(sipDomain)")
            let params = try core.createCallParams(call: nil)
            _ = core.inviteAddressWithParams(addr: address, params: params)
        } catch {
            callState = "Errore chiamata: \(error)"
        }
    }

    /// Ritorna false se non c'è più una chiamata reale a cui rispondere (es. il
    /// chiamante ha già riagganciato) o se l'accettazione fallisce: in quel caso
    /// CallManager deve dire a CallKit che la risposta è fallita, non fulfillarla
    /// — altrimenti iOS mostra una schermata "in chiamata" con timer che avanza
    /// per una chiamata che non esiste più.
    @discardableResult
    func answerIncomingCall() -> Bool {
        guard let core, let call = core.currentCall else { return false }

        // Se la chiamata è già stata accettata (es. doppio tentativo di risposta),
        // Linphone rifiuta un secondo accept con un errore che termina la sessione:
        // qui trattiamo lo stato "già connessa" come successo, non come richiesta
        // da rieseguire.
        guard call.state == .IncomingReceived else {
            return call.state == .Connected || call.state == .StreamsRunning
        }

        do {
            let params = try core.createCallParams(call: call)
            try call.acceptWithParams(params: params)
            return true
        } catch {
            callState = "Errore risposta: \(error)"
            return false
        }
    }

    func hangup() {
        guard let call = core?.currentCall else { return }
        try? call.terminate()
    }

    func setMuted(_ muted: Bool) {
        core?.micEnabled = !muted
    }

    func sendDTMF(_ digit: Character) {
        guard let call = core?.currentCall, let asciiValue = String(digit).cString(using: .utf8)?.first else { return }
        try? call.sendDtmf(dtmf: asciiValue)
    }

    func configureAudioSession() {
        core?.configureAudioSession()
    }

    func setAudioSessionActive(_ active: Bool) {
        core?.activateAudioSession(activated: active)
    }
}
