import SwiftUI
import AVFoundation

/// Schermata durante la chiamata, in stile simile all'app Telefono di iOS
/// (sfondo scuro, pulsanti circolari traslucidi, tastierino DTMF a schermo
/// intero che sostituisce i controlli invece di comparire sotto di essi).
struct CallView: View {
    @ObservedObject var sipManager: SIPManager
    let callManager = CallManager.shared

    @State private var isMuted = false
    @State private var isSpeakerOn = false
    @State private var showKeypad = false
    @State private var dialedDigits = ""
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 8) {
                Spacer(minLength: 48)

                Text(sipManager.remoteDisplayName.isEmpty ? "Sconosciuto" : sipManager.remoteDisplayName)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text(statusText)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.6))
                    .monospacedDigit()

                Spacer()

                if showKeypad {
                    keypadOverlay
                } else {
                    controlGrid
                }

                Button {
                    callManager.endCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(.red))
                }
                .padding(.bottom, 50)
            }
            .padding(.horizontal, 32)
        }
        .onReceive(ticker) { tick in now = tick }
    }

    private var statusText: String {
        guard let start = sipManager.callConnectedAt else { return "Chiamata in corso..." }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var controlGrid: some View {
        HStack(spacing: 36) {
            iosButton(systemImage: isMuted ? "mic.slash.fill" : "mic.fill", active: isMuted) {
                isMuted.toggle()
                callManager.setMuted(isMuted)
            }
            iosButton(systemImage: "circle.grid.3x3.fill", active: showKeypad) {
                showKeypad = true
            }
            iosButton(systemImage: isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill", active: isSpeakerOn) {
                isSpeakerOn.toggle()
                setSpeaker(isSpeakerOn)
            }
        }
        .padding(.bottom, 32)
    }

    private var keypadOverlay: some View {
        VStack(spacing: 20) {
            Text(dialedDigits)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.white)
                .frame(minHeight: 40)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            VStack(spacing: 14) {
                ForEach(Array(PhoneKeypadLayout.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 20) {
                        ForEach(row, id: \.digit) { key in
                            dtmfKeyButton(key)
                        }
                    }
                }
            }

            Button("Nascondi tastierino") {
                showKeypad = false
            }
            .font(.system(size: 17))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.top, 4)
        }
        .padding(.bottom, 20)
    }

    private func dtmfKeyButton(_ key: PhoneKeypadLayout.Key) -> some View {
        Button {
            dialedDigits.append(key.digit)
            callManager.sendDTMF(Character(key.digit))
        } label: {
            VStack(spacing: 2) {
                Text(key.digit)
                    .font(.system(size: 28))
                Text(key.letters.isEmpty ? " " : key.letters)
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1)
            }
            .frame(width: 68, height: 68)
            .foregroundStyle(.white)
            .background(Circle().fill(Color.white.opacity(0.18)))
        }
    }

    private func iosButton(systemImage: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(active ? .black : .white)
                .frame(width: 68, height: 68)
                .background(Circle().fill(active ? Color.white : Color.white.opacity(0.18)))
        }
    }

    private func setSpeaker(_ on: Bool) {
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
        } catch {
            print("Impossibile cambiare route audio: \(error)")
        }
    }
}

#Preview {
    CallView(sipManager: SIPManager())
}
