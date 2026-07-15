import SwiftUI

struct ContentView: View {
    @StateObject private var sipManager = SIPManager()
    @State private var destination: String = "100"

    var body: some View {
        Group {
            if sipManager.isIncomingRinging {
                incomingCallView
            } else if sipManager.isCallActive {
                CallView(sipManager: sipManager)
            } else {
                idleView
            }
        }
        .onAppear {
            sipManager.start()
        }
    }

    private var idleView: some View {
        VStack(spacing: 20) {
            Text("HomeSIP — M1")
                .font(.title2.bold())

            GroupBox("Stato registrazione") {
                Text(sipManager.registrationState)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Stato chiamata") {
                Text(sipManager.callState)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextField("Interno o numero da chiamare", text: $destination)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.phonePad)

            Button("Chiama") {
                CallManager.shared.startCall(to: destination)
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding()
    }

    private var incomingCallView: some View {
        VStack(spacing: 24) {
            Spacer()
            Text(sipManager.remoteDisplayName.isEmpty ? "Chiamata in arrivo" : sipManager.remoteDisplayName)
                .font(.title.bold())
            Text("Chiamata in arrivo")
                .foregroundStyle(.secondary)
            Spacer()

            HStack(spacing: 60) {
                Button {
                    CallManager.shared.endCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(.red))
                }

                Button {
                    sipManager.answerIncomingCall()
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(.green))
                }
            }
            .padding(.bottom, 40)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
