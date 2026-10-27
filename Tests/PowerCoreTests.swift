import Foundation

actor FakeAccess: PowerAccess {
    var enabled: Bool
    var cancel = false
    var ignoreWrite = false
    var writeFails = false
    var targets: [Bool] = []

    init(enabled: Bool, cancel: Bool = false, ignoreWrite: Bool = false, writeFails: Bool = false) {
        self.enabled = enabled
        self.cancel = cancel
        self.ignoreWrite = ignoreWrite
        self.writeFails = writeFails
    }
    func read() -> Bool { enabled }
    func reset(to value: Bool) { enabled = value }
    func writtenTargets() -> [Bool] { targets }
    func write(enabled: Bool) throws -> AuthorizationResult {
        targets.append(enabled)
        if writeFails { throw PowerError.commandFailed("denied") }
        if cancel { return .cancelled }
        if !ignoreWrite { self.enabled = enabled }
        return .applied
    }
}

@MainActor
final class FakeSession: KeepAwakeSession {
    let access: FakeAccess
    var running = false
    var cancel = false
    var stopFails = false

    init(access: FakeAccess) { self.access = access }
    func start() async throws -> AuthorizationResult {
        if cancel { return .cancelled }
        _ = try await access.write(enabled: true)
        running = true
        return .applied
    }
    func stop() async throws -> Bool {
        guard running else { return false }
        if stopFails { throw PowerError.commandFailed("stop failed") }
        running = false
        _ = try await access.write(enabled: false)
        return true
    }
    func isRunning() async -> Bool { running }
    func detach() { running = false }
}

@main struct PowerCoreTests {
    static func check(_ value: Bool) { precondition(value) }

    @MainActor static func main() async throws {
        check(try SystemPowerAccess.parseStatus("System-wide power settings:\n SleepDisabled\t\t0\n") == false)
        check(try SystemPowerAccess.parseStatus(" SleepDisabled 1\n") == true)
        for invalid in ["", "SleepDisabled 2", "SleepDisabled", "OtherSetting 0", "SleepDisabled 0 1"] {
            do {
                _ = try SystemPowerAccess.parseStatus(invalid)
                fatalError("Invalid status was accepted: \(invalid)")
            } catch PowerError.unknownStatus { }
        }
        check(try SystemPowerAccess.parseAuthorization("CANCELLED\n") == .cancelled)
        check(try SystemPowerAccess.parseAuthorization("APPLIED\n") == .applied)
        check(SystemPowerAccess.authorizationScript(enabled: true).contains("/usr/bin/pmset -a disablesleep 1"))
        check(SystemPowerAccess.authorizationScript(enabled: false).contains("/usr/bin/pmset -a disablesleep 0"))

        let normal = FakeAccess(enabled: false)
        let on = try await PowerSwitch(access: normal).toggle()
        check(on == .applied(true))
        let off = try await PowerSwitch(access: normal).toggle()
        check(off == .applied(false))

        let cancelled = try await PowerSwitch(access: FakeAccess(enabled: false, cancel: true)).toggle()
        check(cancelled == .cancelled(false))
        do {
            _ = try await PowerSwitch(access: FakeAccess(enabled: false, ignoreWrite: true)).toggle()
            fatalError("Verification failure was hidden")
        } catch PowerError.verificationFailed { }
        do {
            _ = try await PowerSwitch(access: FakeAccess(enabled: false, writeFails: true)).toggle()
            fatalError("Authorization failure was hidden")
        } catch PowerError.commandFailed { }

        try check(GuardScript.parsePID("STARTED 123\n") == 123)
        try check(GuardScript.parsePID("CANCELLED\n") == nil)
        for invalid in ["", "STARTED 1", "STARTED -2", "STARTED 42 ignored", "STARTED nope"] {
            do { _ = try GuardScript.parsePID(invalid); fatalError("Invalid helper PID accepted") }
            catch PowerError.commandFailed { }
        }

        let driftAccess = FakeAccess(enabled: false)
        let driftSession = FakeSession(access: driftAccess)
        let model = PowerModel(access: driftAccess, session: driftSession)
        await model.refresh()
        check(model.maintenance == .inactive && model.enabled == false)
        await model.enable()
        check(model.maintenance == .active && model.enabled == true)
        // A reset on AC must not be mistaken for the user's request to switch off.
        await driftAccess.reset(to: false)
        await model.refresh()
        check(model.maintenance == .active && model.enabled == false && model.failed)
        await driftAccess.reset(to: true)
        await model.refresh()
        check(model.maintenance == .active && !model.failed)
        await driftAccess.reset(to: false)
        await model.disable()
        check(model.maintenance == .inactive && model.enabled == false)
        check(await driftAccess.writtenTargets() == [true, false])
        await model.refresh()
        check(model.maintenance == .inactive)

        await model.enable()
        driftSession.running = false
        await model.refresh()
        check(model.maintenance == .interrupted && model.failed)
        await model.enable()
        check(model.maintenance == .active && !model.failed)
        driftSession.stopFails = true
        await model.disable()
        check(model.failed && model.maintenance == .active)
        driftSession.stopFails = false
        await model.disable()
        check(model.enabled == false && model.maintenance == .inactive)

        let cancelledAccess = FakeAccess(enabled: false)
        let cancelledSession = FakeSession(access: cancelledAccess)
        cancelledSession.cancel = true
        let cancelledModel = PowerModel(access: cancelledAccess, session: cancelledSession)
        await cancelledModel.enable()
        check(cancelledModel.maintenance == .inactive && cancelledModel.enabled == false)
        check(await cancelledAccess.writtenTargets().isEmpty)
        // An explicit restore is always a write of 0, even when actual state already is 0.
        await cancelledModel.disable()
        check(await cancelledAccess.writtenTargets() == [false])
        check(cancelledModel.message != nil)
        await cancelledAccess.reset(to: true)
        await cancelledModel.refresh()
        check(cancelledModel.enabled == true && cancelledModel.message == nil)
        check(cancelledModel.maintenance == .inactive)

        try await testWorker()
        print("PASS: parsing, authorization, explicit restore, drift recovery state, interruption, cancellation, stop failure, real worker reset/stop/lifetime regression tests")
    }

    // Run the actual worker shell against a fake pmset. No system setting or
    // administrator authorization is touched by this regression test.
    static func testWorker() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("lidhelper-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let state = base.appendingPathComponent("state")
        let log = base.appendingPathComponent("writes")
        let fake = base.appendingPathComponent("fake pmset")
        _ = try await SystemPowerAccess.run("/usr/bin/osacompile", arguments: [
            "-o", base.appendingPathComponent("authorization.scpt").path,
            "-e", GuardScript.authorizationScript(ownerPID: ProcessInfo.processInfo.processIdentifier,
                                                 directory: base.appendingPathComponent("session").path)
        ])
        let fakeText = """
        #!/bin/sh
        if [ "$1" = "-g" ]; then
            /bin/echo "SleepDisabled $(/bin/cat \(GuardScript.quote(state.path)))"
        elif [ "$1" = "-a" ] && [ "$2" = "disablesleep" ]; then
            /bin/echo "$3" > \(GuardScript.quote(state.path))
            /bin/echo "$3" >> \(GuardScript.quote(log.path))
        else
            exit 1
        fi
        """
        try fakeText.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        try "0\n".write(to: state, atomically: true, encoding: .utf8)

        func value() -> String { (try? String(contentsOf: state, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            fatalError("Worker regression timed out")
        }
        let session = base.appendingPathComponent("session 'quoted'")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
        let output = try await SystemPowerAccess.run("/bin/sh", arguments: ["-c",
            GuardScript.launchCommand(ownerPID: ProcessInfo.processInfo.processIdentifier,
                                      directory: session.path, pmsetPath: fake.path, interval: "0.05")])
        check(try GuardScript.parsePID(output) != nil)
        try await waitFor { value() == "1" }
        for _ in 0..<3 {
            try "0\n".write(to: state, atomically: true, encoding: .utf8)
            try await waitFor { value() == "1" }
        }
        // Stop races with a reset: stop must win, and must never be toggled to 1 again.
        try "0\n".write(to: state, atomically: true, encoding: .utf8)
        try Data().write(to: session.appendingPathComponent("stop"))
        try await waitFor {
            (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").last == "0"
        }
        try await Task.sleep(for: .milliseconds(180))
        check(value() == "0")
        let writes = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        check(writes.filter { $0 == "1" }.count >= 4 && writes.last == "0")

        // Quitting leaves the existing global setting, but stops all future repairs.
        let detached = base.appendingPathComponent("detached")
        try FileManager.default.createDirectory(at: detached, withIntermediateDirectories: false)
        _ = try await SystemPowerAccess.run("/bin/sh", arguments: ["-c",
            GuardScript.launchCommand(ownerPID: ProcessInfo.processInfo.processIdentifier,
                                      directory: detached.path, pmsetPath: fake.path, interval: "0.05")])
        try await waitFor { value() == "1" }
        try FileManager.default.removeItem(at: detached)
        try await Task.sleep(for: .milliseconds(180))
        check(value() == "1")
        try "0\n".write(to: state, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(180))
        check(value() == "0")

        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        owner.arguments = ["10"]
        try owner.run()
        let crashed = base.appendingPathComponent("owner-exited")
        try FileManager.default.createDirectory(at: crashed, withIntermediateDirectories: false)
        _ = try await SystemPowerAccess.run("/bin/sh", arguments: ["-c",
            GuardScript.launchCommand(ownerPID: owner.processIdentifier, directory: crashed.path,
                                      pmsetPath: fake.path, interval: "0.05")])
        try await waitFor { value() == "1" }
        owner.terminate()
        owner.waitUntilExit()
        try await Task.sleep(for: .milliseconds(180))
        try "0\n".write(to: state, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(180))
        check(value() == "0")
    }
}
