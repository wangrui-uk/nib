import Foundation

/// Appends to ~/Library/Logs/GrammarAI.log (and the system log). Never logs the text itself.
func log(_ message: String) {
    NSLog("Nib: %@", message)
    let url = logURL
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.data(using: .utf8)?.write(to: url)
    }
}

/// ~/Library/Logs/Nib.log. The log from before the rename (GrammarAI.log) is moved here once.
let logURL: URL = {
    let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    let url = logs.appendingPathComponent("Nib.log")
    let old = logs.appendingPathComponent("GrammarAI.log")
    if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: old.path) {
        try? FileManager.default.moveItem(at: old, to: url)
    }
    return url
}()
