import Foundation
import AppKit
import BeLauncherCore

/// Does the actual work of an in-app update: download, mount, verify, replace, relaunch.
///
/// The decisions live in `UpdateInstaller` where they can be tested. This is the part that touches
/// the disk, and it is deliberately linear: every step either succeeds or stops with something the
/// person can read. Nothing here retries silently and nothing installs without passing the
/// signature and notarization checks first.
@MainActor
@Observable
final class Updater {
    private(set) var phase: UpdateInstaller.Phase = .idle

    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func install(_ release: Release) {
        guard !phase.isBusy else { return }
        task = Task { await self.run(release) }
    }

    /// Swaps in the new version and reopens the app. Separate from `install` because the person
    /// decides when to be interrupted: an update that quits your launcher mid-sentence is worse
    /// than no update.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - The steps

    private func run(_ release: Release) async {
        do {
            let target = try UpdateInstaller.installTarget(bundlePath: Bundle.main.bundlePath).get()
            let dmg = try await download(release)
            defer { try? FileManager.default.removeItem(at: dmg) }

            phase = .verifying
            let mount = try mount(dmg)
            defer { detach(mount) }

            guard let app = try newApp(in: mount) else { throw UpdateInstaller.Failure.badArchive }
            if let failure = UpdateInstaller.verify(codesignOutput: shell("/usr/bin/codesign",
                                                                         ["-dv", "--verbose=4", app]),
                                                   spctlOutput: shell("/usr/sbin/spctl",
                                                                      ["-a", "-t", "exec", "-vv", app]))
            {
                throw failure
            }

            phase = .installing
            try replace(target, with: app)
            phase = .readyToRelaunch(version: release.version)
        } catch is CancellationError {
            phase = .idle
        } catch let failure as UpdateInstaller.Failure {
            phase = .failed(failure.description)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func download(_ release: Release) async throws -> URL {
        guard let url = URL(string: release.url) else { throw UpdateInstaller.Failure.badArchive }
        phase = .downloading(fraction: 0)

        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        // Cloudflare in front of the bucket rejects unknown clients.
        request.setValue("BeLauncher/\(release.version) (macOS)", forHTTPHeaderField: "User-Agent")

        let (temporary, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateInstaller.Failure.replaceFailed("HTTP \(http.statusCode) al descargar")
        }
        // The downloaded file is deleted when this call returns, so move it somewhere of ours.
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BeLauncher-\(release.version).dmg")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        phase = .downloading(fraction: 1)
        return destination
    }

    /// Mounts the image and returns where it landed.
    ///
    /// Asks for a plist rather than scraping the human-readable table: that output is columns of
    /// tab-separated text whose shape is not a promise, and the first attempt at parsing it also
    /// passed `-quiet`, which suppresses the very lines it was parsing. A `-mountrandom` point
    /// keeps this out of `/Volumes`, so an image already mounted by the person is left alone.
    private func mount(_ dmg: URL) throws -> String {
        let output = shell("/usr/bin/hdiutil",
                           ["attach", "-nobrowse", "-noverify", "-plist", "-mountrandom",
                            NSTemporaryDirectory(), dmg.path])
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let point = entities.compactMap({ $0["mount-point"] as? String })
                .first(where: { !$0.isEmpty })
        else { throw UpdateInstaller.Failure.couldNotMount }
        return point
    }

    private func detach(_ mount: String) {
        _ = shell("/usr/bin/hdiutil", ["detach", mount, "-quiet"])
    }

    private func newApp(in mount: String) throws -> String? {
        let entries = try FileManager.default.contentsOfDirectory(atPath: mount)
        guard let name = entries.first(where: { $0.hasSuffix(".app") }) else { return nil }
        return (mount as NSString).appendingPathComponent(name)
    }

    /// Replaces the running bundle atomically. `replaceItemAt` keeps the old copy until the new
    /// one is in place, so a failure halfway leaves a working app behind rather than a hole.
    private func replace(_ target: String, with new: String) throws {
        let manager = FileManager.default
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BeLauncher-incoming-\(UUID().uuidString).app")
        do {
            try manager.copyItem(at: URL(fileURLWithPath: new), to: staging)
            _ = try manager.replaceItemAt(URL(fileURLWithPath: target), withItemAt: staging)
        } catch {
            try? manager.removeItem(at: staging)
            throw UpdateInstaller.Failure.replaceFailed(error.localizedDescription)
        }
    }

    private func shell(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // codesign and spctl write what we need to stderr.
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
