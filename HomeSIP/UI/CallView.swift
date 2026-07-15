import SwiftUI
import AVFoundation

struct CallView: View {
    @ObservedObject var sipManager: SIPManager
    let callManager = CallManager.shared

    @State private var isMuted = false
    @State private var isSpeakerOn = false
    @State private var showKeypad = false

    private let keypadRows: [[String]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["*", "0", "#"]
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text(sipManager.remoteDisplayName.isEmpty ? "Chiamata in corso" : sipManager.remoteDisplayName)
                .font(.title.bold())

            Text(sipManager.callState)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            if showKeypad {
                keypad
                    .padding(.horizontal, 32)
            }

            HStack(spacing: 32) {
                controlButton(systemImage: isMuted ? "mic.slash.fill" : "mic.fill", active: isMuted) {
                    isMuted.toggle()
                    callManager.setMuted(isMuted)
                }
                controlButton(systemImage: "circle.grid.3x3.fill", active: showKeypad) {
                    showKeypad.toggle()
                }
                controlButton(systemImage: isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill", active: isSpeakerOn) {
                    isSpeakerOn.toggle()
                    setSpeaker(isSpeakerOn)
                }
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
            .padding(.bottom, 40)
        }
        .padding()
    }

    private var keypad: some View {
        VStack(spacing: 12) {
            ForEach(keypadRows, id: \.self) { row in
                HStack(spacing: 12) {
                    ForEach(row, id: \.self) { digit in
                        Button {
                            callManager.sendDTMF(Character(digit))
                        } label: {
                            Text(digit)
                                .font(.title3)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    private func controlButton(systemImage: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(active ? .white : .primary)
                .frame(width: 56, height: 56)
                .background(Circle().fill(active ? Color.accentColor : Color(.secondarySystemBackground)))
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
