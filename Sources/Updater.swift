import AppKit

/// One-click self-update: download the latest GitHub release zip, verify it,
/// swap the app bundle in place, and relaunch. No Sparkle — the same
/// no-third-party rule as the rest of the app. The bundle is ad-hoc signed, so
/// there is no signature chain to pin; integrity relies on the https download
/// from GitHub releases plus a version check on the unpacked bundle.
enum Updater {
    enum UpdateError: LocalizedError {
        case badDownload
        case badBundle(String)
        case swapFailed(String)
        var errorDescription: String? {
            switch self {
            case .badDownload: return "The update download failed."
            case .badBundle(let m): return "The downloaded update looks wrong (\(m))."
            case .swapFailed(let m): return "Couldn't install the update (\(m))."
            }
        }
    }

    /// Download `zipURL`, verify it contains Squat Coach at `expectedVersion`,
    /// and swap it over `appPath`. Completion lands on the main queue.
    /// Relaunching is the caller's move — that keeps this fully testable from
    /// a headless harness.
    static func install(zipURL: URL, expectedVersion: String, appPath: String,
                        completion: @escaping (Error?) -> Void) {
        let done: (Error?) -> Void = { e in DispatchQueue.main.async { completion(e) } }
        URLSession.shared.downloadTask(with: zipURL) { tmp, _, err in
            guard err == nil, let tmp else { done(err ?? UpdateError.badDownload); return }
            // The download's temp file dies with this callback, so claim it
            // first, then do the slow unzip/swap off the shared session's
            // completion queue (it would stall unrelated callbacks otherwise).
            let claimed = FileManager.default.temporaryDirectory
                .appendingPathComponent("squatcoach-download-\(UUID().uuidString).zip")
            do { try FileManager.default.moveItem(at: tmp, to: claimed) }
            catch { done(UpdateError.badDownload); return }
            DispatchQueue.global(qos: .userInitiated).async {
                defer { try? FileManager.default.removeItem(at: claimed) }
                do {
                    try swapInDownloadedBundle(zipAt: claimed, expectedVersion: expectedVersion,
                                               appPath: appPath)
                    done(nil)
                } catch {
                    done(error)
                }
            }
        }.resume()
    }

    /// Everything after the download, synchronously: unzip → validate → swap,
    /// rolling the old bundle back if the final move fails.
    static func swapInDownloadedBundle(zipAt zip: URL, expectedVersion: String,
                                       appPath: String) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("squatcoach-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        try run("/usr/bin/ditto", "-xk", zip.path, work.path)
        let newApp = work.appendingPathComponent("Squat Coach.app")
        let newExe = newApp.appendingPathComponent("Contents/MacOS/SquatCoach")
        guard fm.fileExists(atPath: newExe.path)
        else { throw UpdateError.badBundle("no app executable in the zip") }
        // ditto contains ../ traversal, but extracts symlink entries verbatim —
        // a symlinked bundle would smuggle the swap past the version check.
        for url in [newApp, newExe] {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw UpdateError.badBundle("bundle is a symlink")
            }
        }
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              let version = info["CFBundleShortVersionString"] as? String
        else { throw UpdateError.badBundle("unreadable Info.plist") }
        guard version == expectedVersion
        else { throw UpdateError.badBundle("zip contains v\(version), expected v\(expectedVersion)") }
        try? run("/usr/bin/xattr", "-cr", newApp.path)

        // The backup lives OUTSIDE `work` so the deferred cleanup can never
        // destroy the only remaining copy of a working app.
        let backup = fm.temporaryDirectory
            .appendingPathComponent("squatcoach-previous-\(UUID().uuidString).app")
        try fm.moveItem(atPath: appPath, toPath: backup.path)
        do {
            try fm.moveItem(atPath: newApp.path, toPath: appPath)
            try? fm.removeItem(at: backup)
        } catch {
            try? fm.removeItem(atPath: appPath)   // clear any partial copy first
            if (try? fm.moveItem(atPath: backup.path, toPath: appPath)) == nil {
                throw UpdateError.swapFailed("\(error.localizedDescription) — your previous "
                    + "app was saved at \(backup.path); move it back to \(appPath)")
            }
            throw UpdateError.swapFailed(error.localizedDescription)
        }
    }

    /// Relaunch the (already swapped) bundle from a detached shell that
    /// outlives this process, then quit. The sleep lets termination finish
    /// before `open` starts the new instance.
    @MainActor
    static func relaunch(appPath: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Path travels as $0, never interpolated into the script. Clearing
        // quarantine right before open is a last-ditch guard against a swapped
        // bundle that Gatekeeper would otherwise refuse to launch.
        p.arguments = ["-c",
                       "sleep 1; /usr/bin/xattr -dr com.apple.quarantine \"$0\" 2>/dev/null; /usr/bin/open \"$0\"",
                       appPath]
        try? p.run()
        NSApp.terminate(nil)
    }

    private static func run(_ cmd: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.swapFailed("\(URL(fileURLWithPath: cmd).lastPathComponent) exited \(p.terminationStatus)")
        }
    }
}
