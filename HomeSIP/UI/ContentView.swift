import SwiftUI

struct ContentView: View {
    @ObservedObject private var sipManager = SIPManager.shared
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
            Text("HomeSIP — M3")
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

            #if targetEnvironment(simulator)
            // Sul simulatore CallKit è bypassato (vedi CallManager): questi
            // pulsanti sono l'unico modo di rispondere/rifiutare.
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
            #else
            // Su device reale la risposta passa SOLO dalla UI di sistema di
            // CallKit: un secondo tentativo di risposta da qui accetterebbe
            // due volte la stessa chiamata (Linphone la termina con un errore
            // "operation not permitted" se già connessa).
            Text("Rispondi dalla schermata di chiamata di iOS")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 40)
            #endif
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
