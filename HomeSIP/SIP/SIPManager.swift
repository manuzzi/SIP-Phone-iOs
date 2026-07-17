import Foundation
import Network
import os
import WidgetKit
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
                    DebugFileLogger.log("stato registrazione -> \(state) — \(message)")
                    DispatchQueue.main.async {
                        self?.registrationState = "\(state) — \(message)"
                    }

                    // M5.1: lo stato va condiviso con le estensioni
                    // widget/controllo (che non vedono lo stato interno di
                    // SIPManager) e va sollecitato un refresh, perché
                    // WidgetKit non ha modo di sapere da solo che qualcosa
                    // è cambiato nel frattempo.
                    SharedStatus.write(
                        registrationState: "\(state) — \(message)",
                        isReachable: state == .Ok,
                        domain: SIPSettings.domain
                    )
                    WidgetCenter.shared.reloadAllTimelines()
                    if #available(iOS 18.0, *) {
                        ControlCenter.shared.reloadAllControls()
                    }
                    if state == .Ok {
                        self?.hasNotifiedUnreachable = false
                        self?.cancelRegistrationWatchdog()
                        // Sblocca eventuali chiamate che il push relay sta
                        // trattenendo in Stasis in attesa che l'app si
                        // ri-registri dopo un risveglio da VoIP push.
                        PushRelayClient.shared.notifyDeviceReady()
                    } else if state == .Failed {
                        self?.cancelRegistrationWatchdog()
                        if self?.hasNotifiedUnreachable == false {
                            self?.hasNotifiedUnreachable = true
                            CallHistoryStore.log(kind: .serverUnreachable, detail: message)
                            NotificationManager.notifyServerUnreachable(detail: message)
                        }
                    } else if state == .Progress {
                        // Rete su cui la registrazione era in corso il transito
                        // (es. WiFi -> VPN) può lasciarla bloccata su "Progress"
                        // a tempo indeterminato invece di fallire o riuscire: se
                        // non si sblocca da sola entro un tempo ragionevole,
                        // forziamo comunque un nuovo tentativo.
                        self?.scheduleRegistrationWatchdog()
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
                    DebugFileLogger.log("path monitor avviato, percorso iniziale: \(summary)")
                    return
                }
                guard previous != summary else { return }
                logger.notice("percorso di rete cambiato: \(previous, privacy: .public) -> \(summary, privacy: .public), programmo ri-registrazione (debounce)")
                print("SIPManager: percorso di rete cambiato: \(previous) -> \(summary), programmo ri-registrazione (debounce)")
                DebugFileLogger.log("percorso di rete cambiato: \(previous) -> \(summary), programmo ri-registrazione (debounce)")

                self.reregisterDebounceWorkItem?.cancel()
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    logger.notice("debounce scaduto, percorso stabile: verifico raggiungibilità prima di ri-registrare")
                    print("SIPManager: debounce scaduto, percorso stabile: verifico raggiungibilità prima di ri-registrare")
                    DebugFileLogger.log("debounce scaduto, percorso stabile: verifico raggiungibilità prima di ri-registrare")
                    self.triggerReregisterWhenReachable()
                }
                self.reregisterDebounceWorkItem = workItem
                // Il debounce serve solo ad assorbire percorsi transitori
                // multipli ravvicinati (vedi sopra), non più ad "indovinare"
                // il tempo di negoziazione della VPN: di quello si occupa
                // ServerReachabilityProbe, che verifica la raggiungibilità
                // reale del server invece di attendere un tempo fisso.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    /// Il cambio di rete (WiFi ↔ cellulare ↔ VPN) può lasciare Linphone
    /// legato a un socket per un percorso non più valido, che scade solo
    /// dopo minuti con un errore di I/O invece di riprovare su uno nuovo.
    /// `networkReachable` è l'API ufficiale di Linphone per questo esatto
    /// scenario: a `false` chiude tutte le connessioni di rete, a `true` fa
    /// riconnettere; `refreshRegisters()` forza esplicitamente una nuova
    /// REGISTER anche per un account che si considera ancora a metà di una
    /// transazione ormai orfana.
    ///
    /// Un riavvio completo del Core (stopAsync + start, come chiudere e
    /// riaprire l'app) risolveva il blocco su "Progress" ma rompeva anche
    /// transizioni che già funzionavano (es. VPN -> WiFi) — troppo invasivo.
    /// La causa vera del blocco non è che questo meccanismo sia insufficiente
    /// in sé, ma che scattava troppo presto: va invocato solo dopo aver
    /// verificato che il server sia davvero raggiungibile (vedi
    /// triggerReregisterWhenReachable), non su un timer indovinato.
    private func forceReregister() {
        guard let core else { return }
        core.networkReachable = false
        logger.notice("forceReregister: rete segnalata non raggiungibile, chiudo le connessioni")
        print("SIPManager: forceReregister: rete segnalata non raggiungibile, chiudo le connessioni")
        DebugFileLogger.log("forceReregister: rete segnalata non raggiungibile, chiudo le connessioni")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let core = self.core else { return }
            core.networkReachable = true
            core.refreshRegisters()
            logger.notice("forceReregister: rete segnalata raggiungibile, ri-registrazione forzata")
            print("SIPManager: forceReregister: rete segnalata raggiungibile, ri-registrazione forzata")
            DebugFileLogger.log("forceReregister: rete segnalata raggiungibile, ri-registrazione forzata")
        }
    }

    /// Genera un numero univoco per ogni ciclo di verifica-poi-registra: se un
    /// nuovo cambio di percorso arriva mentre un ciclo precedente sta ancora
    /// ritentando la sonda, il vecchio ciclo si riconosce superato e si ferma
    /// da solo, invece di finire per ri-registrare due volte o in ordine sbagliato.
    private var reachabilityRetryGeneration = 0

    /// Punto d'ingresso per qualunque motivo si voglia forzare una
    /// ri-registrazione (cambio di percorso, watchdog): non lo fa subito,
    /// verifica prima che il server sia davvero raggiungibile — questo evita
    /// del tutto la finestra in cui un'interfaccia VPN risulta "up" per il
    /// sistema qualche secondo prima che il tunnel abbia davvero finito di
    /// negoziare (osservato: 2-3s), che è quello che lasciava la
    /// registrazione bloccata su "Progress".
    private func triggerReregisterWhenReachable() {
        reachabilityRetryGeneration += 1
        probeAndReregister(generation: reachabilityRetryGeneration, attempt: 1)
    }

    private func probeAndReregister(generation: Int, attempt: Int) {
        guard generation == reachabilityRetryGeneration else { return } // superato da un cambio più recente
        let domain = SIPSettings.domain
        logger.notice("verifico raggiungibilità di \(domain, privacy: .public):5060 (tentativo \(attempt))")
        print("SIPManager: verifico raggiungibilità di \(domain):5060 (tentativo \(attempt))")
        DebugFileLogger.log("verifico raggiungibilità di \(domain):5060 (tentativo \(attempt))")

        ServerReachabilityProbe.check(host: domain, port: 5060) { [weak self] reachable in
            guard let self, generation == self.reachabilityRetryGeneration else { return }
            DebugFileLogger.log("esito sonda tentativo \(attempt): \(reachable ? "raggiungibile" : "non raggiungibile")")
            if reachable {
                logger.notice("server raggiungibile, forzo ri-registrazione")
                print("SIPManager: server raggiungibile, forzo ri-registrazione")
                self.forceReregister()
                return
            }
            guard attempt < 20 else {
                // ~20s di tentativi (probe da 3s + 1s di pausa ciascuno): se
                // il server non risponde ancora, un prossimo cambio di
                // percorso o il watchdog sotto ritenteranno più avanti.
                logger.notice("server non raggiungibile dopo vari tentativi, abbandono per ora")
                print("SIPManager: server non raggiungibile dopo vari tentativi, abbandono per ora")
                DebugFileLogger.log("server non raggiungibile dopo vari tentativi, abbandono per ora")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.probeAndReregister(generation: generation, attempt: attempt + 1)
            }
        }
    }

    /// Rete di sicurezza per quando la registrazione resta bloccata su
    /// "Progress" più a lungo del ragionevole invece di risolversi in
    /// Ok/Failed — capita anche quando il rilevamento del cambio di percorso
    /// non scatta.
    private var registrationWatchdogWorkItem: DispatchWorkItem?

    private func scheduleRegistrationWatchdog() {
        // Non va ri-programmato ad ogni singola notifica "Progress": Linphone
        // può emetterne più di una per lo stesso tentativo (es. ad ogni
        // ritrasmissione), e se ogni notifica cancellasse e riavviasse il
        // timer, questo non scatterebbe mai finché le notifiche continuano
        // ad arrivare più spesso della finestra di attesa.
        guard registrationWatchdogWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.registrationWatchdogWorkItem = nil
            logger.notice("watchdog registrazione: bloccata su Progress da troppo tempo, verifico raggiungibilità")
            print("SIPManager: watchdog registrazione: bloccata su Progress da troppo tempo, verifico raggiungibilità")
            DebugFileLogger.log("watchdog registrazione: bloccata su Progress da troppo tempo, verifico raggiungibilità")
            self.triggerReregisterWhenReachable()
        }
        registrationWatchdogWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: workItem)
    }

    private func cancelRegistrationWatchdog() {
        registrationWatchdogWorkItem?.cancel()
        registrationWatchdogWorkItem = nil
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
