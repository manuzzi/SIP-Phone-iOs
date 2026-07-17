import Foundation

/// Log di debug persistito su file nella sandbox dell'app, per poterlo
/// recuperare dopo un test in cui il telefono cambia rete (WiFi/VPN): la
/// cattura live della console via devicectl si è dimostrata troppo fragile,
/// tende a interrompersi proprio nel momento del cambio di rete che serve
/// osservare.
enum DebugFileLogger {
    private static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("debug.log")
    }()

    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: fileURL)
        }
    }
}
