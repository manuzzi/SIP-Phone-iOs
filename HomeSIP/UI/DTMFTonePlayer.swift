import AudioToolbox

/// Riproduce il tono locale del tastierino (feedback udibile alla pressione
/// di un tasto, come nel tastierino dell'app Telefono di iOS). Usa
/// AudioServices invece di AVAudioPlayer perché è quello che rispetta
/// automaticamente l'interruttore fisico suoneria/silenzioso per gli effetti
/// sonori brevi dell'interfaccia, senza dover interrogare noi stessi lo
/// stato dell'interruttore (l'API pubblica di iOS non lo espone).
enum DTMFTonePlayer {
    private static var soundIDs: [String: SystemSoundID] = [:]

    private static func fileName(for digit: Character) -> String {
        switch digit {
        case "*": return "dtmf_star"
        case "#": return "dtmf_pound"
        default: return "dtmf_\(digit)"
        }
    }

    static func play(_ digit: Character) {
        let name = fileName(for: digit)

        if let existing = soundIDs[name] {
            AudioServicesPlaySystemSound(existing)
            return
        }

        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            return
        }
        var soundID: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &soundID) == kAudioServicesNoError else {
            return
        }
        soundIDs[name] = soundID
        AudioServicesPlaySystemSound(soundID)
    }
}
