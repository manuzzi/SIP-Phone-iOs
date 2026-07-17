import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject private var sipManager = SIPManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var destination: String = ""
    @State private var showHistory = false

    var body: some View {
        Group {
            if sipManager.isIncomingRinging {
                incomingCallView
            } else if sipManager.isCallActive {
                CallView(sipManager: sipManager)
            } else if !sipManager.isConfigured {
                notConfiguredView
            } else {
                idleView
            }
        }
        .onAppear {
            sipManager.start()
        }
        .onChange(of: scenePhase) { phase in
            // Copre il caso in cui l'utente configuri l'account in Impostazioni
            // di sistema e torni nell'app senza doverla riavviare.
            if phase == .active {
                sipManager.start()
            }
        }
    }

    private var idleView: some View {
        VStack(spacing: 12) {
            ZStack {
                VStack(spacing: 2) {
                    Text("HomeSIP — M5")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(sipManager.registrationState)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack {
                    Spacer()
                    Button {
                        showHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 8)

            DialerView(destination: $destination) {
                guard !destination.isEmpty else { return }
                CallManager.shared.startCall(to: destination)
            }

            Spacer(minLength: 8)
        }
        .padding()
        .sheet(isPresented: $showHistory) {
            CallHistoryView()
        }
    }

    private var notConfiguredView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "gearshape.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Configura l'account SIP")
                .font(.title2.bold())
            Text("Vai su Impostazioni > HomeSIP e imposta interno, password e server, poi torna qui.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Apri Impostazioni") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
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
