import Foundation

/// Layout standard del tastierino telefonico (cifra + lettere), condiviso tra
/// il dialer nella home (DialerView) e il tastierino DTMF in chiamata (CallView).
enum PhoneKeypadLayout {
    struct Key {
        let digit: String
        let letters: String
    }

    static let rows: [[Key]] = [
        [Key(digit: "1", letters: ""), Key(digit: "2", letters: "ABC"), Key(digit: "3", letters: "DEF")],
        [Key(digit: "4", letters: "GHI"), Key(digit: "5", letters: "JKL"), Key(digit: "6", letters: "MNO")],
        [Key(digit: "7", letters: "PQRS"), Key(digit: "8", letters: "TUV"), Key(digit: "9", letters: "WXYZ")],
        [Key(digit: "*", letters: ""), Key(digit: "0", letters: "+"), Key(digit: "#", letters: "")],
    ]
}
