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
    func write(enabled: Bool) throws -> AuthorizationResult {
        targets.append(enabled)
        if writeFails { throw PowerError.commandFailed("denied") }
        if cancel { return .cancelled }
        if !ignoreWrite { self.enabled = enabled }
        return .applied
    }
}

@main struct PowerCoreTests {
    static func check(_ value: Bool) { precondition(value) }

    static func main() async throws {
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
        print("PASS: status parsing, both toggle directions, cancellation, authorization failure, verification mismatch, fixed commands")
    }
}
