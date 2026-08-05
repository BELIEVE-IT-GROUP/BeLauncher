import Testing
import Foundation
@testable import BeLauncherCore

/// This code overwrites the running application. Everything here is about refusing to do that for
/// anything we have not proved came from us.
@Suite("Installing an update in place")
struct UpdateInstallerTests {

    static let ourSignature = """
        Executable=/Volumes/BeLauncher/BeLauncher.app/Contents/MacOS/BeLauncher
        Identifier=com.believe.belauncher
        Authority=Developer ID Application: BELIEVE IT GROUP SAS (35R4W3WK5T)
        TeamIdentifier=35R4W3WK5T
        """
    static let notarized = """
        /Volumes/BeLauncher/BeLauncher.app: accepted
        source=Notarized Developer ID
        origin=Developer ID Application: BELIEVE IT GROUP SAS (35R4W3WK5T)
        """

    @Test("our own signed and notarized build installs")
    func happyPath() {
        #expect(UpdateInstaller.verify(codesignOutput: Self.ourSignature,
                                       spctlOutput: Self.notarized) == nil)
    }

    @Test("someone else's Developer ID is refused, however valid it is")
    func otherTeam() {
        let theirs = Self.ourSignature.replacingOccurrences(of: "35R4W3WK5T", with: "ABCDE12345")
        let spctl = Self.notarized.replacingOccurrences(of: "35R4W3WK5T", with: "ABCDE12345")
        #expect(UpdateInstaller.verify(codesignOutput: theirs, spctlOutput: spctl)
                == .notSignedByUs(found: "ABCDE12345"))
    }

    @Test("an unsigned build is refused, and says so")
    func adHoc() {
        let adHoc = "Identifier=com.believe.belauncher\nTeamIdentifier=not set"
        #expect(UpdateInstaller.verify(codesignOutput: adHoc, spctlOutput: Self.notarized)
                == .notSignedByUs(found: ""))
    }

    @Test("signed by us but not notarized is still refused")
    func signedButNotNotarized() {
        // What a build signed on our own Mac looks like: accepted here, notarized nowhere.
        let local = """
            /tmp/BeLauncher.app: accepted
            source=Developer ID
            """
        #expect(UpdateInstaller.verify(codesignOutput: Self.ourSignature, spctlOutput: local)
                == .notNotarized)
        // "accepted" on its own must never be enough.
        #expect(!UpdateInstaller.isNotarized(fromSpctl: "/tmp/x.app: accepted"))
    }

    @Test("a translocated app refuses to update itself instead of updating nothing")
    func translocation() {
        let path = "/private/var/folders/xy/AppTranslocation/ABC/d/BeLauncher.app"
        #expect(UpdateInstaller.isTranslocated(path))

        guard case .failure(let failure) = UpdateInstaller.installTarget(bundlePath: path) else {
            Issue.record("installing into a read-only copy silently updates nothing"); return
        }
        #expect(failure == .translocated)
    }

    @Test("a read-only location is reported before anything is downloaded")
    func readOnly() {
        guard case .failure(let failure) =
                UpdateInstaller.installTarget(bundlePath: "/System/Applications/BeLauncher.app")
        else {
            Issue.record("no debería poder instalar ahí"); return
        }
        #expect(failure == .notWritable("/System/Applications"))
    }

    @Test("a normal install location is accepted")
    func writable() {
        let folder = NSTemporaryDirectory() + "belauncher-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }

        let bundle = (folder as NSString).appendingPathComponent("BeLauncher.app")
        guard case .success(let target) = UpdateInstaller.installTarget(bundlePath: bundle) else {
            Issue.record("una carpeta con permiso de escritura debería servir"); return
        }
        #expect(target == bundle)
    }

    @Test("every failure says what happened and that nothing was installed")
    func messages() {
        let failures: [UpdateInstaller.Failure] = [
            .notWritable("/x"), .translocated, .badArchive,
            .notSignedByUs(found: "ABCDE12345"), .notNotarized, .replaceFailed("disco lleno"),
        ]
        for failure in failures {
            #expect(failure.description.count > 20, "\(failure) no le dice nada a nadie")
        }
        // The two that mean "someone tampered with the download" must be explicit about it.
        #expect(UpdateInstaller.Failure.notNotarized.description.contains("No se instaló nada"))
        #expect(UpdateInstaller.Failure.notSignedByUs(found: "X").description
            .contains("No se instaló nada"))
    }

    @Test("only the busy phases block a second attempt")
    func busy() {
        #expect(UpdateInstaller.Phase.downloading(fraction: 0.5).isBusy)
        #expect(UpdateInstaller.Phase.verifying.isBusy)
        #expect(UpdateInstaller.Phase.installing.isBusy)
        #expect(!UpdateInstaller.Phase.idle.isBusy)
        #expect(!UpdateInstaller.Phase.readyToRelaunch(version: "1.0.0").isBusy)
        #expect(!UpdateInstaller.Phase.failed("x").isBusy, "un fallo debe poder reintentarse")
    }
}
