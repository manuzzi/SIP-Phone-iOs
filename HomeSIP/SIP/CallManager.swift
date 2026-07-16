import Foundation
import CallKit
import AVFoundation

/// Integrazione CallKit: gestisce l'interfaccia di sistema (schermata di chiamata
/// nativa, Recenti, indicatore in-chiamata) per UNA sola chiamata alla volta.
/// Niente conferenze/trasferimenti/attesa multi-chiamata: fuori scope
/// (vedi PIANO_SVILUPPO.md). Gestisce anche le chiamate innescate da VoIP
/// push (M2): vedi reportPushTriggeredIncomingCall e la correlazione con
/// il vero INVITE in reportIncomingCall.
///
/// Il simulatore iOS ha un supporto CallKit inaffidabile (lo stesso approccio è
/// usato dall'app ufficiale Linphone, che disabilita CallKit su simulatore): le
/// azioni passano quindi direttamente a SIPManager quando `isSimulator` è vero,
/// per continuare a poter validare la registrazione/chiamata come in M0.
final class CallManager: NSObject, ObservableObject {

    static let shared = CallManager()

    weak var sipManager: SIPManager?

    private let provider: CXProvider
    private let callController = CXCallController()

    private var activeCallUUID: UUID?
    private var endReportedToCallKit = false

    /// Vero tra la segnalazione di una chiamata scaturita da una VoIP push
    /// (nessun contesto SIP ancora disponibile) e l'arrivo del vero INVITE.
    private var isPendingFromPush = false
    private var pushTimeoutWorkItem: DispatchWorkItem?

    /// Se l'utente tocca "Rispondi" mentre la chiamata è ancora "fantasma"
    /// (push arrivata, INVITE reale non ancora ricevuto — push e INVITE
    /// viaggiano in parallelo, senza garanzia di ordine), l'azione va tenuta
    /// in sospeso e completata non appena l'INVITE arriva, invece di fallire
    /// subito solo perché non c'è ancora nessuna chiamata Linphone reale.
    private var pendingAnswerAction: CXAnswerCallAction?

    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private override init() {
        provider = CXProvider(configuration: CallManager.providerConfiguration)
        super.init()
        // Sempre sul thread main: SIPManager notifica anch'esso da lì, evita
        // di dover sincronizzare l'accesso allo stato di questa classe tra code diverse.
        provider.setDelegate(self, queue: .main)
    }

    private static var providerConfiguration: CXProviderConfiguration {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.supportedHandleTypes = [.generic]
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        return config
    }

    // MARK: - Chiamata uscente

    func startCall(to destination: String) {
        guard !isSimulator else {
            sipManager?.placeCall(to: destination)
            return
        }

        let uuid = UUID()
        activeCallUUID = uuid
        endReportedToCallKit = false

        let handle = CXHandle(type: .generic, value: destination)
        let startAction = CXStartCallAction(call: uuid, handle: handle)
        callController.request(CXTransaction(action: startAction)) { error in
            if let error {
                print("CallKit: avvio chiamata fallito: \(error)")
            }
        }
    }

    // MARK: - Chiamata entrante (segnalata da SIPManager su .IncomingReceived)

    func reportIncomingCall(handle: String, displayName: String) {
        guard !isSimulator else {
            // Nessuna UI di sistema sul simulatore: la chiamata resta visibile
            // solo nello stato pubblicato da SIPManager (come in M0).
            return
        }

        if isPendingFromPush, let uuid = activeCallUUID {
            // Il vero INVITE SIP è arrivato per una chiamata già segnalata a
            // partire dalla VoIP push: aggiorniamo il CXCall esistente con i
            // dati reali invece di segnalarne uno nuovo (eviterebbe una
            // seconda schermata di chiamata per lo stesso squillo).
            pushTimeoutWorkItem?.cancel()
            isPendingFromPush = false

            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: handle)
            update.localizedCallerName = displayName
            update.hasVideo = false
            provider.reportCall(with: uuid, updated: update)

            // L'utente aveva già toccato "Rispondi" mentre eravamo ancora in
            // attesa dell'INVITE reale: completiamo ora quella risposta.
            if let pendingAction = pendingAnswerAction {
                pendingAnswerAction = nil
                completeAnswer(pendingAction)
            }
            return
        }

        let uuid = UUID()
        activeCallUUID = uuid
        endReportedToCallKit = false

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.localizedCallerName = displayName
        update.hasVideo = false

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                print("CallKit: chiamata in arrivo non segnalabile: \(error)")
                self?.clearActiveCall()
            }
        }
    }

    /// Da chiamare da PKPushRegistryDelegate non appena arriva una VoIP push:
    /// non c'è ancora nessun contesto SIP (il vero INVITE potrebbe non essere
    /// nemmeno arrivato), ma la chiamata va comunque segnalata immediatamente
    /// a CallKit — è un requisito Apple, non rispettarlo per ogni push VoIP
    /// ricevuta espone l'app al rischio che iOS revochi l'entitlement.
    func reportPushTriggeredIncomingCall(callerNumber: String, callerName: String) {
        guard !isSimulator else { return }

        // Il relay invia la push indipendentemente dallo stato dell'app: se
        // l'app era già in primo piano e ha già ricevuto il vero INVITE SIP
        // direttamente (reportIncomingCall ha già impostato activeCallUUID),
        // questa push è ridondante — segnalarla comunque creerebbe una
        // seconda chiamata fantasma per lo stesso squillo.
        guard activeCallUUID == nil else { return }

        let uuid = UUID()
        activeCallUUID = uuid
        endReportedToCallKit = false
        isPendingFromPush = true

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerNumber.isEmpty ? "Sconosciuto" : callerNumber)
        update.localizedCallerName = callerName.isEmpty ? "Chiamata in arrivo" : callerName
        update.hasVideo = false

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if let error {
                print("CallKit: chiamata da push non segnalabile: \(error)")
                self?.clearActiveCall()
            }
        }

        // Se l'INVITE SIP reale non arriva entro un tempo ragionevole (rete
        // irraggiungibile, relay non funzionante), la chiamata "fantasma"
        // va chiusa esplicitamente invece di restare appesa in Recenti.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isPendingFromPush, self.activeCallUUID == uuid else { return }
            if let pendingAction = self.pendingAnswerAction {
                self.pendingAnswerAction = nil
                pendingAction.fail()
            }
            self.reportCallEnded(reason: .failed)
        }
        pushTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: workItem)
    }

    // MARK: - Notifiche di stato dal livello SIP verso CallKit

    func reportOutgoingCallConnected() {
        guard let uuid = activeCallUUID, !isSimulator else { return }
        provider.reportOutgoingCall(with: uuid, connectedAt: nil)
    }

    /// Da chiamare quando SIPManager rileva la fine di una chiamata (locale o remota):
    /// se l'utente aveva già terminato dalla UI di sistema CallKit, non fa nulla
    /// (evita di segnalare due volte la stessa fine chiamata).
    func reportCallEnded(reason: CXCallEndedReason = .remoteEnded) {
        defer { clearActiveCall() }
        guard let uuid = activeCallUUID, !isSimulator, !endReportedToCallKit else { return }
        endReportedToCallKit = true
        provider.reportCall(with: uuid, endedAt: nil, reason: reason)
    }

    // MARK: - Azioni utente dalla UI dell'app

    func endCall() {
        guard !isSimulator, let uuid = activeCallUUID else {
            sipManager?.hangup()
            clearActiveCall()
            return
        }
        let endAction = CXEndCallAction(call: uuid)
        callController.request(CXTransaction(action: endAction)) { _ in }
    }

    func setMuted(_ muted: Bool) {
        guard !isSimulator, let uuid = activeCallUUID else {
            sipManager?.setMuted(muted)
            return
        }
        let action = CXSetMutedCallAction(call: uuid, muted: muted)
        callController.request(CXTransaction(action: action)) { _ in }
    }

    func sendDTMF(_ digit: Character) {
        guard !isSimulator, let uuid = activeCallUUID else {
            sipManager?.sendDTMF(digit)
            return
        }
        let action = CXPlayDTMFCallAction(call: uuid, digits: String(digit), type: .singleTone)
        callController.request(CXTransaction(action: action)) { _ in }
    }

    private func clearActiveCall() {
        activeCallUUID = nil
        isPendingFromPush = false
        pushTimeoutWorkItem?.cancel()
        pushTimeoutWorkItem = nil
        pendingAnswerAction = nil
    }
}

// MARK: - CXProviderDelegate

extension CallManager: CXProviderDelegate {

    func providerDidReset(_ provider: CXProvider) {
        clearActiveCall()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        sipManager?.configureAudioSession()
        sipManager?.placeCall(to: action.handle.value)
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: nil)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        sipManager?.configureAudioSession()

        if isPendingFromPush {
            // L'utente ha risposto prima che il vero INVITE SIP arrivasse
            // (push e INVITE non sono garantiti nello stesso ordine): non
            // fallire subito, la risposta verrà completata da reportIncomingCall
            // non appena il vero INVITE si correla con questa chiamata
            // "fantasma" (o fallita dal timeout in reportPushTriggeredIncomingCall
            // se l'INVITE non arriva mai).
            pendingAnswerAction = action
            return
        }
        completeAnswer(action)
    }

    private func completeAnswer(_ action: CXAnswerCallAction) {
        if sipManager?.answerIncomingCall() ?? false {
            action.fulfill()
        } else {
            // La chiamata non esiste più (es. il chiamante ha riagganciato prima
            // che il tocco su "Rispondi" venisse processato): fallire l'azione
            // evita che CallKit mostri una schermata "in chiamata" vuota con
            // timer che avanza all'infinito.
            action.fail()
            clearActiveCall()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        endReportedToCallKit = true
        sipManager?.hangup()
        clearActiveCall()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        sipManager?.setMuted(action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        if let digit = action.digits.first {
            sipManager?.sendDTMF(digit)
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        sipManager?.setAudioSessionActive(true)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        sipManager?.setAudioSessionActive(false)
    }
}
