import SwiftUI

struct ContentView: View {
    @StateObject private var sipManager = SIPManager()
    @State private var destination: String = "100"

    var body: some View {
        VStack(spacing: 20) {
            Text("HomeSIP — spike M0")
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

            HStack {
                Button("Chiama") {
                    sipManager.call(to: destination)
                }
                .buttonStyle(.borderedProminent)

                Button("Riaggancia") {
                    sipManager.hangup()
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            sipManager.start()
        }
    }
}

#Preview {
    ContentView()
}
