import BtonCore
import Foundation

/// About's Update, owned by the app: leaving the pane neither forgets an install that runs nor
/// offers a second one.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    /// The release being installed, until the installer quits this Bton and opens the new one.
    private(set) var installing: String?
    private(set) var problem: String?

    /// Runs the bundled installer, its output in Bton's home. It outlives this app: it quits it
    /// once the new one is in place, and opens the new one.
    func install(_ latest: String) {
        guard installing == nil else { return }
        let log = BtonHome().url.appendingPathComponent("update.log")
        guard let installer = Bundle.main.url(forResource: "install", withExtension: "sh"),
              let run = BtonRelease.updateRun(installer: installer.path, latestTag: latest, searchPath: Executables.searchPath)
        else {
            problem = "this build has no installer; run the install line from the README"
            return
        }
        guard let output = Self.openLog(log) else {
            problem = "could not write \(log.path)"
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: run.executable)
        process.arguments = run.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(run.environment) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { process in
            try? output.close()
            let problem = process.terminationStatus == 0 ? nil
                : BtonRelease.updateFailure(log: (try? String(contentsOf: log, encoding: .utf8)) ?? "")
            Task { @MainActor in
                Updater.shared.installing = nil
                Updater.shared.problem = problem
            }
        }
        do {
            try process.run()
            installing = latest
            problem = nil
        } catch {
            try? output.close()
            problem = error.localizedDescription
        }
    }

    /// A fresh log, never through a link, and only a plain file.
    private static func openLog(_ url: URL) -> FileHandle? {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { return nil }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            return nil
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
