import AppKit
import Foundation
import VoiceCore

/// The log the user keeps while trying the wake-word mode, to count false wakes and missed « OK Maé »: one line per
/// sentence Maé heard while she waited for the phrase or spoke (did it wake her?), or while she listened after an
/// answer (taken for the user). Only the start of each sentence is written. It stays on this Mac; Settings › Advanced
/// shows it and deletes it.
enum WakeLog {
    static var url: URL {
        AppIdentity.modelsDirectory.deletingLastPathComponent().appending(path: "Wake word log.txt")
    }

    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func append(_ decision: WakeDecision) {
        let line = [decision.date.formatted(date: .numeric, time: .standard), moment(decision.moment),
                    verdict(decision), decision.heard].joined(separator: "\t") + "\n"
        do {
            if !exists {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let header = [String(localized: "Date and time"), "Maé", String(localized: "Decision"),
                              String(localized: "What she heard")].joined(separator: "\t") + "\n"
                try Data(header.utf8).write(to: url)
            }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: Data(line.utf8))
        } catch {
            DebugLog.log("wake log: \(error)")
        }
    }

    static func show() {
        NSWorkspace.shared.open(url)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }

    private static func moment(_ moment: WakeDecision.Moment) -> String {
        switch moment {
        case .asleep: String(localized: "Asleep")
        case .busy: String(localized: "Speaking")
        case .awake: String(localized: "Awake")
        }
    }

    private static func verdict(_ decision: WakeDecision) -> String {
        switch (decision.moment, decision.accepted) {
        case (_, false): String(localized: "Ignored")
        case (.asleep, true): String(localized: "Woke up")
        case (.busy, true): String(localized: "Interrupted")
        case (.awake, true): String(localized: "Taken for you")
        }
    }
}
