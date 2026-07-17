import SwiftUI

/// Tastierino di composizione in stile Telefono di iOS: cifre con lettere,
/// display del numero composto, cancellazione e pulsante di chiamata verde.
struct DialerView: View {
    @Binding var destination: String
    let onCall: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            display

            VStack(spacing: 16) {
                ForEach(Array(PhoneKeypadLayout.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 20) {
                        ForEach(row, id: \.digit) { key in
                            keyButton(key)
                        }
                    }
                }
            }

            Button(action: onCall) {
                Image(systemName: "phone.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(destination.isEmpty ? Color.gray : Color.green))
            }
            .buttonStyle(.plain)
            .disabled(destination.isEmpty)
        }
    }

    private var display: some View {
        HStack {
            Spacer()
            Text(destination.isEmpty ? " " : destination)
                .font(.system(size: 40, weight: .light))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            Spacer()
        }
        .frame(height: 48)
        .overlay(alignment: .trailing) {
            if !destination.isEmpty {
                Button {
                    destination.removeLast()
                } label: {
                    Image(systemName: "delete.left")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func keyButton(_ key: PhoneKeypadLayout.Key) -> some View {
        Button {
            DTMFTonePlayer.play(Character(key.digit))
            destination.append(key.digit)
        } label: {
            VStack(spacing: 2) {
                Text(key.digit)
                    .font(.system(size: 34))
                    .foregroundStyle(.primary)
                Text(key.letters.isEmpty ? " " : key.letters)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 76, height: 76)
            .background(Circle().fill(Color(.systemGray5)))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    DialerView(destination: .constant("101"), onCall: {})
}
