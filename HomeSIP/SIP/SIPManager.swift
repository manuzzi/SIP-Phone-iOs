import Foundation
import Network
import os
import linphonesw

private let logger = Logger(subsystem: "work.manuzzi.homesip", category: "SIPManager")

/// Registrazione SIP e gestione delle chiamate. Le decisioni sull'interfaccia
/// di sistema (schermata di chiamata, Recenti) sono delegate a CallManager:
/// qui viviamo solo il livello SIP/RTP. Parametri account in SIPSettings
/// (Impostazioni di sistema > HomeSIP, vedi Settings.bundle).
final class SIPManager: ObservableObject {

    /// Singleton: deve poter essere avviato da AppDelegate (risveglio in
    /// background su VoIP push) indipendentemente dal ciclo di vita delle view.
    static let shared = SIPManager()

    @Published var registrationState: String = "Non avviato"
    @Published var callState: String = "Nessuna chiamata"
    @Published var isCallActive: Bool = false
    @Published var isIncomingRinging: Bool = false
    @Published var remoteDisplayName: String = ""
    @Published var isConfigured: Bool = SIPSettings.isConfigured
    /// Istante in cui la chiamata corrente è diventata attiva (per il timer
    /// di durata nella UI); nil finché non si esce dallo stato di squillo.
    @Published var callConnectedAt: Date?

    private var core: Core!
    private var coreDelegate: CoreDelegateStub!
    private var iterateTimer: Timer?

    // Linphone non si accorge da solo dei cambi di rete (WiFi ↔ cellulare ↔
    // VPN): senza essere avvisato esplicitamente, resta legato al vecchio
    // socket finché non scade con un errore di I/O (osservato: ~2 minuti
    // bloccato su "Refreshing" prima di fallire). Il path monitor forza un
    // refresh del trasporto/registrazione ad ogni cambio di percorso reale.
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.manuzzi.homesip.pathmonitor")
    private var lastPathSummary: String?

    // All'avvio NWPathMonitor può notificare più percorsi in rapida sequenza
    // (uno transitorio, poi quello definitivo): senza debounce, il secondo
    // evento interpretava questo come "cambio rete" e forzava una
    // ri-registrazione PROPRIO mentre la REGISTER iniziale era ancora in
    // volo, interrompendola a metà (osservato via tcpdump: 401 mai seguito
    // dal retry autenticato). Si agisce solo dopo che il percorso resta
    // stabile per un breve intervallo.
    private var reregisterDebounceWorkItem: DispatchWorkItem?

    /// Evita di rimandare la stessa notifica/lo stesso evento di log ad ogni
    /// singolo tentativo di REGISTER fallito mentre il problema persiste:
    /// si segnala solo alla transizione verso "non raggiungibile", si
    /// azzera non appena la registrazione torna a funzionare.
    private var hasNotifiedUnreachable = false

    /// Da richiamare anche quando l'app torna in primo piano: se al primo
    /// avvio l'account non era ancora configurato (Impostazioni > HomeSIP),
    /// questo permette di agganciare la registrazione non appena l'utente
    /// imposta i parametri e torna nell'app, senza dover riavviarla.
    func start() {
        guard core == nil else { return } // già avviato

        guard SIPSettings.isConfigured else {
            isConfigured = false
            registrationState = "Configura l'account SIP in Impostazioni"
            return
        }
        isConfigured = true

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
                    logger.notice("stato registrazione -> \(String(describing: state), privacy: .public) — \(message, privacy: .public)")
                    print("SIPManager: stato registrazione -> \(state) — \(message)")
                    DispatchQueue.main.async {
                        self?.registrationState = "\(state) — \(message)"
                    }
                    if state == .Ok {
                        self?.hasNotifiedUnreachable = false
                        // Sblocca eventuali chiamate che il push relay sta
                        // trattenendo in Stasis in attesa che l'app si
                        // ri-registri dopo un risveglio da VoIP push.
                        PushRelayClient.shared.notifyDeviceReady()
                    } else if state == .Failed, self?.hasNotifiedUnreachable == false {
                        self?.hasNotifiedUnreachable = true
                        CallHistoryStore.log(kind: .serverUnreachable, detail: message)
                        NotificationManager.notifyServerUnreachable(detail: message)
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
            startNetworkMonitoring()
        } catch {
            registrationState = "Errore avvio: \(error)"
        }
    }

    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // A differenza di "availableInterfaces" (elenca tutto ciò che
            // esiste sul sistema, WiFi e cellulare restano "disponibili"
            // anche quando la VPN è attiva), usesInterfaceType(_:) riflette
            // quali interfacce partecipano DAVVERO al percorso che il
            // sistema sta scegliendo in questo momento — è quello che
            // cambia realmente quando si attiva/disattiva la VPN.
            let summary = [
                "wifi:\(path.usesInterfaceType(.wifi))",
                "cellular:\(path.usesInterfaceType(.cellular))",
                "vpn:\(path.usesInterfaceType(.other))",
                "wired:\(path.usesInterfaceType(.wiredEthernet))",
                "status:\(path.status)",
            ].joined(separator: ",")

            DispatchQueue.main.async {
                defer { self.lastPathSummary = summary }
                guard let previous = self.lastPathSummary else {
                    logger.notice("path monitor avviato, percorso iniziale: \(summary, privacy: .public)")
                    print("SIPManager: path monitor avviato, percorso iniziale: \(summary)")
                    return
                }
                guard previous != summary else { return }
                logger.notice("percorso di rete cambiato: \(previous, privacy: .public) -> \(summary, privacy: .public), programmo ri-registrazione (debounce)")
                print("SIPManager: percorso di rete cambiato: \(previous) -> \(summary), programmo ri-registrazione (debounce)")

                self.reregisterDebounceWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    logger.notice("debounce scaduto, percorso stabile: forzo ri-registrazione")
                    print("SIPManager: debounce scaduto, percorso stabile: forzo ri-registrazione")
                    self.forceReregister()
                }
                self.reregisterDebounceWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    /// Il cambio di rete (WiFi ↔ cellulare ↔ VPN) può lasciare Linphone
    /// legato a un socket per un percorso non più valido, che scade solo
    /// dopo minuti con un errore di I/O invece di riprovare su uno nuovo.
    /// `networkReachable` è l'API ufficiale di Linphone per questo esatto
    /// scenario (vedi doc del wrapper): a `false` chiude tutte le
    /// connessioni di rete, a `true` fa riconnettere e ri-registrare tutti
    /// gli account automaticamente — sostituisce un precedente workaround
    /// (clonare gli AccountParams per disabilitare/riabilitare la
    /// registrazione) che funzionava ma non era il meccanismo previsto.
    private func forceReregister() {
        guard let core else { return }
        core.networkReachable = false
        logger.notice("forceReregister: rete segnalata non raggiungibile, chiudo le connessioni")
        print("SIPManager: forceReregister: rete segnalata non raggiungibile, chiudo le connessioni")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let core = self.core else { return }
            core.networkReachable = true
            logger.notice("forceReregister: rete segnalata raggiungibile, ri-registrazione automatica")
            print("SIPManager: forceReregister: rete segnalata raggiungibile, ri-registrazione automatica")
        }
    }

    private func registerAccount() throws {
        let factory = Factory.Instance
        let username = SIPSettings.username
        let domain = SIPSettings.domain

        let authInfo = try factory.createAuthInfo(
            username: username,
            userid: "",
            passwd: SIPSettings.password,
            ha1: "",
            realm: "",
            domain: domain
        )

        let accountParams = try core.createAccountParams()

        let identity = try factory.createAddress(addr: "sip:\(username)@\(domain)")
        try accountParams.setIdentityaddress(newValue: identity)

        let serverAddress = try factory.createAddress(addr: "sip:\(domain)")
        // UDP fallisce sistematicamente su cellulare+WireGuard: Asterisk invia
        // sempre il 401 correttamente (verificato via pjsip logger), ma la
        // risposta non arriva mai al socket UDP "connesso" di belle-sip una
        // volta attraversato il tunnel utun (causa non isolata con certezza,
        // ipotesi principale: interazione nota tra socket UDP connessi e
        // NEPacketTunnelProvider). TCP evita la classe di problema.
        try serverAddress.setTransport(newValue: .Tcp)
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
            // Va registrato qui (non in .Released, che azzera remoteDisplayName
            // e callConnectedAt subito dopo): è l'ultimo stato in cui i dati
            // di questa chiamata sono ancora quelli giusti.
            if state == .End || state == .Error, call.dir == .Incoming, self.callConnectedAt == nil {
                let name = self.remoteDisplayName.isEmpty ? "Sconosciuto" : self.remoteDisplayName
                CallHistoryStore.log(kind: .missedCall, detail: name)
            }

            switch state {
            case .Released:
                self.isCallActive = false
                self.isIncomingRinging = false
                self.remoteDisplayName = ""
                self.callConnectedAt = nil
            case .IncomingReceived:
                self.isCallActive = true
                self.isIncomingRinging = true
                if let addr = call.remoteAddress {
                    self.remoteDisplayName = addr.displayName ?? addr.username ?? addr.asStringUriOnly()
                }
            case .Connected, .StreamsRunning:
                self.isCallActive = true
                self.isIncomingRinging = false
                if let addr = call.remoteAddress {
                    self.remoteDisplayName = addr.displayName ?? addr.username ?? addr.asStringUriOnly()
                }
                if self.callConnectedAt == nil {
                    self.callConnectedAt = Date()
                    if let addr = call.remoteAddress {
                        let handle = addr.username ?? addr.asStringUriOnly()
                        let displayName = addr.displayName ?? handle
                        CallDonationManager.donateCall(handle: handle, displayName: displayName)
                    }
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
            let address = try Factory.Instance.createAddress(addr: "sip:\(destination)@\(SIPSettings.domain)")
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
