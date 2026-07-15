import Foundation
import CallKit
import AVFoundation

/// Integrazione CallKit per M1: gestisce l'interfaccia di sistema (schermata di chiamata
/// nativa, Recenti, indicatore in-chiamata) per UNA sola chiamata alla volta.
/// Niente conferenze/trasferimenti/attesa multi-chiamata: fuori scope per M1
/// (vedi PIANO_SVILUPPO.md).
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
        provider.setDelegate(self, queue: nil)
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
                self?.activeCallUUID = nil
            }
        }
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
        sipManager?.answerIncomingCall()
        action.fulfill()
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
