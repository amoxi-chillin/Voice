import Foundation
import OSLog
import SQLite3

/// Copies History, dictionary, statistics, recordings, models and settings from VoiceInk, the app
/// Voice was renamed from, the first time Voice launches. VoiceInk's own files and settings are
/// only read. Keychain items (API keys) and privacy permissions belong to VoiceInk's signature and
/// can't be carried over.
enum PreviousAppDataImport {
    struct Locations {
        var previousSupportDirectory: URL
        var supportDirectory: URL
        var previousCustomSoundsDirectory: URL
        var customSoundsDirectory: URL

        static var standard: Locations {
            let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return Locations(
                previousSupportDirectory: applicationSupport.appendingPathComponent(
                    previousBundleIdentifier, isDirectory: true),
                supportDirectory: applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true),
                previousCustomSoundsDirectory: applicationSupport.appendingPathComponent(
                    "VoiceInk/CustomSounds", isDirectory: true),
                customSoundsDirectory: applicationSupport.appendingPathComponent("Voice/CustomSounds", isDirectory: true)
            )
        }
    }

    struct Outcome: Equatable {
        var importedFiles = false
        var importedSettings = false
        var failedItems: [String] = []

        var importedAnything: Bool { importedFiles || importedSettings }
    }

    static let previousBundleIdentifier = "com.prakashjoshipax.VoiceInk"
    static let bundleIdentifier = "com.amoxichillin.Voice"
    static let settingsImportedKey = "PreviousAppSettingsImported"

    /// Records the file import's progress in the support folder, which Voice and Voice Dev share.
    static let fileImportMarkerName = ".previous-app-import"
    private static let fileImportInProgress = "copying"
    private static let fileImportDone = "done"

    private static let logger = Logger(subsystem: "com.amoxichillin.voice", category: "PreviousAppDataImport")

    /// Must run before anything reads settings or opens the data stores.
    static func runIfNeeded(
        locations: Locations = .standard,
        defaults: UserDefaults = .standard,
        settingsDomain: String? = Bundle.main.bundleIdentifier,
        previousSettingsDomain: String? = nil
    ) -> Outcome {
        var outcome = Outcome()
        importFilesIfNeeded(locations: locations, outcome: &outcome)

        if let settingsDomain {
            // Voice Dev imports from VoiceInk Dev, Voice from VoiceInk.
            let previousDomain =
                previousSettingsDomain
                ?? settingsDomain.replacingOccurrences(of: bundleIdentifier, with: previousBundleIdentifier)
            outcome.importedSettings = importSettingsIfNeeded(
                defaults: defaults,
                domain: settingsDomain,
                previousDomain: previousDomain,
                locations: locations
            )
        }

        if outcome.importedAnything || !outcome.failedItems.isEmpty {
            logger.notice(
                "Imported previous app data files=\(outcome.importedFiles, privacy: .public) settings=\(outcome.importedSettings, privacy: .public) failed=\(outcome.failedItems.joined(separator: ","), privacy: .public)"
            )
        }
        return outcome
    }

    // MARK: - Files

    private static func importFilesIfNeeded(locations: Locations, outcome: inout Outcome) {
        let fileManager = FileManager.default
        let supportDirectory = locations.supportDirectory
        let markerURL = supportDirectory.appendingPathComponent(fileImportMarkerName)
        let markerState = (try? String(contentsOf: markerURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard markerState != fileImportDone,
            fileManager.fileExists(atPath: locations.previousSupportDirectory.path)
        else { return }

        // Voice has stored data of its own, so never mix VoiceInk's into it.
        if markerState == nil,
            fileManager.fileExists(atPath: supportDirectory.appendingPathComponent("default.store").path)
        {
            writeMarker(fileImportDone, to: markerURL)
            return
        }

        do {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        } catch {
            logger.error("Could not create the support folder: \(error, privacy: .public)")
            outcome.failedItems.append(supportDirectory.lastPathComponent)
            return
        }
        writeMarker(fileImportInProgress, to: markerURL)

        let items =
            (try? fileManager.contentsOfDirectory(
                at: locations.previousSupportDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
        for item in items {
            let name = item.lastPathComponent
            // SQLite side files are folded into each store's copy.
            if name.hasSuffix("-wal") || name.hasSuffix("-shm") || name.hasSuffix("-journal") || name == ".DS_Store" {
                continue
            }

            let destination = supportDirectory.appendingPathComponent(renamedItemName(name))
            if fileManager.fileExists(atPath: destination.path) { continue }

            do {
                try copyItem(item, to: destination, locations: locations)
            } catch {
                logger.error("Could not import \(name, privacy: .public): \(error, privacy: .public)")
                outcome.failedItems.append(name)
            }
        }

        if fileManager.fileExists(atPath: locations.previousCustomSoundsDirectory.path),
            !fileManager.fileExists(atPath: locations.customSoundsDirectory.path)
        {
            do {
                try fileManager.createDirectory(
                    at: locations.customSoundsDirectory.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: locations.previousCustomSoundsDirectory, to: locations.customSoundsDirectory)
            } catch {
                logger.error("Could not import custom sounds: \(error, privacy: .public)")
                outcome.failedItems.append("CustomSounds")
            }
        }

        // A failed item is retried on the next launch.
        if outcome.failedItems.isEmpty {
            writeMarker(fileImportDone, to: markerURL)
        }
        outcome.importedFiles = true
    }

    /// Copies next to the destination first, so an interrupted launch never leaves a partial copy in place.
    private static func copyItem(_ source: URL, to destination: URL, locations: Locations) throws {
        let fileManager = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".importing-\(destination.lastPathComponent)")
        removeItemAndSQLiteSideFiles(at: staging)

        do {
            if source.pathExtension == "store" {
                try backUpDatabase(from: source, to: staging)
                if source.lastPathComponent == "default.store" {
                    try relinkRecordings(inStoreAt: staging, locations: locations)
                }
                // The copy is closed and in rollback-journal mode, so its side files hold nothing.
                removeSQLiteSideFiles(of: staging)
            } else {
                // On APFS this clones, so large models and recordings take no extra space.
                try fileManager.copyItem(at: source, to: staging)
                renameIntegrityRecords(in: staging)
            }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            removeItemAndSQLiteSideFiles(at: staging)
            throw error
        }
    }

    private static func removeItemAndSQLiteSideFiles(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        removeSQLiteSideFiles(of: url)
    }

    private static func removeSQLiteSideFiles(of url: URL) {
        for suffix in ["-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    static func renamedItemName(_ name: String) -> String {
        name == "VoiceInkRefine" ? "VoiceRefine" : name
    }

    /// Voice Refine checks downloaded models against a record whose file name was renamed.
    private static func renameIntegrityRecords(in directory: URL) {
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        else { return }

        for case let url as URL in enumerator where url.lastPathComponent == ".voiceink-integrity.json" {
            let renamed = url.deletingLastPathComponent().appendingPathComponent(".voice-integrity.json")
            try? fileManager.moveItem(at: url, to: renamed)
        }
    }

    /// Uses SQLite's backup API so the copy is consistent even while VoiceInk is running and writing.
    private static func backUpDatabase(from source: URL, to destination: URL) throws {
        var sourceDatabase: OpaquePointer?
        var destinationDatabase: OpaquePointer?
        defer {
            sqlite3_close(sourceDatabase)
            sqlite3_close(destinationDatabase)
        }

        guard sqlite3_open_v2(source.path, &sourceDatabase, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ImportError.database(message(from: sourceDatabase))
        }
        guard
            sqlite3_open_v2(
                destination.path, &destinationDatabase, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
        else {
            throw ImportError.database(message(from: destinationDatabase))
        }
        guard let backup = sqlite3_backup_init(destinationDatabase, "main", sourceDatabase, "main") else {
            throw ImportError.database(message(from: destinationDatabase))
        }
        let result = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE else {
            throw ImportError.database(message(from: destinationDatabase))
        }

        // Keep the copy in one file so it can be moved into place; the app switches it back to WAL.
        guard sqlite3_exec(destinationDatabase, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw ImportError.database(message(from: destinationDatabase))
        }
    }

    /// History stores absolute recording URLs. Without this, playback, retranscription and History
    /// auto-delete would act on VoiceInk's recordings instead of Voice's copies.
    private static func relinkRecordings(inStoreAt storeURL: URL, locations: Locations) throws {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw ImportError.database(message(from: database))
        }

        let replacements = [
            (locations.previousSupportDirectory.absoluteString, locations.supportDirectory.absoluteString),
            (locations.previousSupportDirectory.path + "/", locations.supportDirectory.path + "/"),
        ]
        for (oldPrefix, newPrefix) in replacements {
            let sql = """
                UPDATE ZTRANSCRIPTION SET ZAUDIOFILEURL = ?1 || substr(ZAUDIOFILEURL, ?2)
                WHERE substr(ZAUDIOFILEURL, 1, ?3) = ?4
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                // A store without History records has no table to update.
                sqlite3_finalize(statement)
                return
            }
            defer { sqlite3_finalize(statement) }

            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, newPrefix, -1, transient)
            // SQLite's substr counts Unicode code points.
            let prefixLength = Int32(oldPrefix.unicodeScalars.count)
            sqlite3_bind_int(statement, 2, prefixLength + 1)
            sqlite3_bind_int(statement, 3, prefixLength)
            sqlite3_bind_text(statement, 4, oldPrefix, -1, transient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ImportError.database(message(from: database))
            }
        }
    }

    private static func message(from database: OpaquePointer?) -> String {
        database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown SQLite error"
    }

    private static func writeMarker(_ state: String, to url: URL) {
        try? state.write(to: url, atomically: true, encoding: .utf8)
    }

    enum ImportError: Error {
        case database(String)
    }

    // MARK: - Settings

    /// Only fills a settings domain Voice hasn't written to yet.
    private static func importSettingsIfNeeded(
        defaults: UserDefaults,
        domain: String,
        previousDomain: String,
        locations: Locations
    ) -> Bool {
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        guard current[settingsImportedKey] == nil else { return false }

        guard current.isEmpty,
            let previous = defaults.persistentDomain(forName: previousDomain),
            !previous.isEmpty
        else {
            if !current.isEmpty {
                defaults.set(true, forKey: settingsImportedKey)
            }
            return false
        }

        var imported: [String: Any] = [:]
        for (key, value) in previous where !isSparkleKey(key) {
            imported[renamedSettingsKey(key)] = renamedSettingsValue(value, locations: locations)
        }
        imported[settingsImportedKey] = true
        defaults.setPersistentDomain(imported, forName: domain)
        return true
    }

    /// Update-check state from the previous app's feed.
    private static func isSparkleKey(_ key: String) -> Bool {
        guard key.hasPrefix("SU"), key.count > 2 else { return false }
        let third = key[key.index(key.startIndex, offsetBy: 2)]
        return third.isUppercase
    }

    /// Mirrors the source rename, so keys built from renamed names still match.
    static func renamedSettingsKey(_ key: String) -> String {
        key.replacingOccurrences(of: "com.prakashjoshipax.VoiceInk", with: "com.amoxichillin.Voice")
            .replacingOccurrences(of: "com.prakashjoshipax.voiceink", with: "com.amoxichillin.voice")
            .replacingOccurrences(of: "VoiceInk", with: "Voice")
            .replacingOccurrences(of: "voiceInk", with: "voice")
            .replacingOccurrences(of: "VOICEINK", with: "VOICE")
            .replacingOccurrences(of: "voiceink", with: "voice")
    }

    /// Renames stored provider names, Local CLI prompt variables and paths into VoiceInk's folders.
    /// Other text, such as prompts the user wrote, is left as it is.
    static func renamedSettingsValue(_ value: Any, locations: Locations) -> Any {
        switch value {
        case let string as String:
            return renamedSettingsString(string, locations: locations)
        case let array as [Any]:
            return array.map { renamedSettingsValue($0, locations: locations) }
        case let dictionary as [String: Any]:
            return dictionary.mapValues { renamedSettingsValue($0, locations: locations) }
        case let data as Data:
            // Codable settings are stored as JSON.
            guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                object is [Any] || object is [String: Any]
            else { return data }
            let renamed = renamedSettingsValue(object, locations: locations)
            guard let original = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                let encoded = try? JSONSerialization.data(withJSONObject: renamed, options: [.sortedKeys]),
                encoded != original
            else { return data }
            return encoded
        default:
            return value
        }
    }

    private static func renamedSettingsString(_ string: String, locations: Locations) -> String {
        if string == "VoiceInk Refine" {
            return "Voice Refine"
        }

        var renamed = string
        let pathReplacements = [
            (locations.previousSupportDirectory, locations.supportDirectory),
            (locations.previousCustomSoundsDirectory, locations.customSoundsDirectory),
        ]
        for (old, new) in pathReplacements {
            renamed = renamed.replacingOccurrences(
                of: old.absoluteString.trimmingTrailingSlash, with: new.absoluteString.trimmingTrailingSlash)
            renamed = renamed.replacingOccurrences(of: old.path, with: new.path)
        }
        return renamed.replacingOccurrences(of: "$VOICEINK_", with: "$VOICE_")
    }
}

private extension String {
    var trimmingTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
