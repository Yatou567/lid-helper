import Foundation
import Darwin
import IOKit.pwr_mgt

// All privileged code is a fixed shell program. The app supplies only its numeric
// PID and a generated session directory; no user-writable executable is run as root.
enum GuardScript {
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func launchCommand(ownerPID: Int32, directory: String,
                              pmsetPath: String = "/usr/bin/pmset", interval: String = "2") -> String {
        let worker = """
        trap '' HUP
        owner_start=$(/bin/ps -p \(ownerPID) -o lstart=)
        [ -n "$owner_start" ] || exit 1
        failures=0
        while [ -d \(quote(directory)) ]; do
            [ "$(/bin/ps -p \(ownerPID) -o lstart=)" = "$owner_start" ] || exit 0
            if [ -f \(quote(directory + "/stop")) ]; then
                \(quote(pmsetPath)) -a disablesleep 0
                exit $?
            fi
            state=$(\(quote(pmsetPath)) -g | /usr/bin/awk '$1 == "SleepDisabled" && NF == 2 && ($2 == "0" || $2 == "1") { print $2; exit }')
            case "$state" in
                0)
                    # Recheck stop and lifetime immediately before a privileged write.
                    [ -d \(quote(directory)) ] || exit 0
                    [ ! -f \(quote(directory + "/stop")) ] || continue
                    [ "$(/bin/ps -p \(ownerPID) -o lstart=)" = "$owner_start" ] || exit 0
                    \(quote(pmsetPath)) -a disablesleep 1 || exit 1
                    failures=0
                    ;;
                1) failures=0 ;;
                *) failures=$((failures + 1)); [ "$failures" -lt 3 ] || exit 1 ;;
            esac
            /bin/sleep \(quote(interval))
        done
        """
        return """
        /bin/sh -c \(quote(worker)) </dev/null >/dev/null 2>&1 &
        /bin/echo "STARTED $!"
        """
    }

    static func authorizationScript(ownerPID: Int32, directory: String) -> String {
        let command = launchCommand(ownerPID: ownerPID, directory: directory)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        try
            return do shell script "\(command)" with prompt "合盖助手需要管理员授权，在本次运行期间自动维持合盖保持运行。" with administrator privileges
        on error errorMessage number errorNumber
            if errorNumber is -128 then
                return "CANCELLED"
            end if
            error errorMessage number errorNumber
        end try
        """
    }

    static func parsePID(_ output: String) throws -> Int32? {
        let fields = output.split(whereSeparator: \.isWhitespace)
        if fields == ["CANCELLED"] { return nil }
        guard fields.count == 2, fields[0] == "STARTED",
              let pid = Int32(fields[1]), pid > 1 else {
            throw PowerError.commandFailed("自动维持未能启动，请重试。")
        }
        return pid
    }
}

@MainActor
protocol KeepAwakeSession: AnyObject {
    func start() async throws -> AuthorizationResult
    // True means this session handled the stop; false requires a normal authorized write.
    func stop() async throws -> Bool
    func isRunning() async -> Bool
    func detach()
}

@MainActor
final class SystemKeepAwakeSession: KeepAwakeSession {
    private struct Handle {
        let directory: String
        let pid: Int32
        let identity: String
    }
    private var handle: Handle?
    private var assertion: IOPMAssertionID?
    private let access: any PowerAccess

    init(access: any PowerAccess = SystemPowerAccess()) { self.access = access }

    private func identity(of pid: Int32) async -> String? {
        guard let output = try? await SystemPowerAccess.run("/bin/ps", arguments: ["-p", String(pid), "-o", "lstart="]),
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return output
    }

    func isRunning() async -> Bool {
        guard let handle else { return false }
        return await identity(of: handle.pid) == handle.identity
    }

    func start() async throws -> AuthorizationResult {
        if await isRunning() { return .applied }
        detach()
        // A fresh UUID prevents a previous session's stop request affecting a new one.
        let directory = NSTemporaryDirectory() + "local.lidhelper." + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let output = try await SystemPowerAccess.run("/usr/bin/osascript", arguments: [
                "-e", GuardScript.authorizationScript(ownerPID: ProcessInfo.processInfo.processIdentifier, directory: directory)
            ])
            guard let pid = try GuardScript.parsePID(output) else {
                try? FileManager.default.removeItem(atPath: directory)
                return .cancelled
            }
            guard let identity = await identity(of: pid) else {
                throw PowerError.commandFailed("自动维持进程已退出，请重新开启。")
            }
            handle = Handle(directory: directory, pid: pid, identity: identity)
            // Startup is asynchronous. Report success only after real state and liveness agree.
            for _ in 0..<30 {
                if (try? await access.read()) == true, await isRunning() {
                    var id: IOPMAssertionID = 0
                    let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "合盖助手自动维持" as CFString, &id)
                    guard result == kIOReturnSuccess else {
                        throw PowerError.commandFailed("无法建立防止空闲睡眠保护，请重新开启。")
                    }
                    assertion = id
                    return .applied
                }
                guard await isRunning() else { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw PowerError.verificationFailed
        } catch {
            detach()
            try? FileManager.default.removeItem(atPath: directory)
            throw error
        }
    }

    func stop() async throws -> Bool {
        guard let handle else { return false }
        guard await isRunning() else { detach(); return false }
        // Keep the stop marker until the worker has exited. It cannot re-enable
        // sleep prevention after this request, even if the observed setting is already 0.
        try Data().write(to: URL(fileURLWithPath: handle.directory + "/stop"), options: .atomic)
        for _ in 0..<100 {
            if !(await isRunning()) {
                detach()
                return true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PowerError.commandFailed("自动维持尚未停止，请稍后再次点击“恢复正常睡眠”。")
    }

    func detach() {
        if let assertion { IOPMAssertionRelease(assertion); self.assertion = nil }
        if let handle { try? FileManager.default.removeItem(atPath: handle.directory) }
        handle = nil
    }
}
