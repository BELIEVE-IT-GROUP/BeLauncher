import Foundation
import Testing
@testable import BeLauncherCore

/// Exercises the process lifecycle against a stand-in shell script rather than the real Bazel-built
/// bridge: the real binary needs the upstream LiteRT-LM checkout and a multi-gigabyte model file,
/// neither of which belongs in a unit test. What is under test here is `LiteRTLMService` itself —
/// that it launches the given executable, waits for the ready line, and fails closed when the
/// process cannot produce one — not the C++ bridge's model-loading code.
@Suite("LiteRT-LM service lifecycle")
struct LiteRTLMServiceTests {
    private func makeExecutableScript(_ body: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("litertlm-fake-\(UUID().uuidString).sh").path
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func makeExistingFile() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("litertlm-fake-model-\(UUID().uuidString).litertlm").path
        try Data().write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test("fails closed when the binary path does not exist")
    func binaryMissing() async throws {
        let service = LiteRTLMService()
        let modelPath = try makeExistingFile()
        await #expect(throws: LiteRTLMService.ServiceError.binaryMissing("/no/such/binary")) {
            try await service.start(binaryPath: "/no/such/binary", modelPath: modelPath)
        }
    }

    @Test("fails closed when the model path does not exist")
    func modelMissing() async throws {
        let service = LiteRTLMService()
        let binaryPath = try makeExecutableScript("#!/bin/sh\nexit 0\n")
        await #expect(throws: LiteRTLMService.ServiceError.modelMissing("/no/such/model.litertlm")) {
            try await service.start(binaryPath: binaryPath, modelPath: "/no/such/model.litertlm")
        }
    }

    @Test("start suspends until the ready line, then reports running")
    func readyLineUnblocksStart() async throws {
        let service = LiteRTLMService()
        let modelPath = try makeExistingFile()
        let binaryPath = try makeExecutableScript("""
            #!/bin/sh
            echo '{"ready":true,"port":8998,"speculative_decoding":true}'
            sleep 5
            """)

        try await service.start(binaryPath: binaryPath, modelPath: modelPath)
        #expect(await service.isRunning)

        await service.stop()
        #expect(await service.isRunning == false)
    }

    @Test("a process that exits before signalling ready fails the start call")
    func exitBeforeReadyFails() async throws {
        let service = LiteRTLMService()
        let modelPath = try makeExistingFile()
        let binaryPath = try makeExecutableScript("""
            #!/bin/sh
            echo 'not the ready line'
            exit 1
            """)

        await #expect(throws: LiteRTLMService.ServiceError.didNotBecomeReady) {
            try await service.start(binaryPath: binaryPath, modelPath: modelPath)
        }
        #expect(await service.isRunning == false)
    }

    @Test("starting twice without stopping is rejected")
    func alreadyRunningIsRejected() async throws {
        let service = LiteRTLMService()
        let modelPath = try makeExistingFile()
        let binaryPath = try makeExecutableScript("""
            #!/bin/sh
            echo '{"ready":true}'
            sleep 5
            """)

        try await service.start(binaryPath: binaryPath, modelPath: modelPath)
        await #expect(throws: LiteRTLMService.ServiceError.alreadyRunning) {
            try await service.start(binaryPath: binaryPath, modelPath: modelPath)
        }
        await service.stop()
    }
}
