import Foundation

enum PowerError: LocalizedError, Equatable {
    case commandFailed(String)
    case unknownStatus
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): return message
        case .unknownStatus: return "无法读取系统睡眠状态，请刷新后重试。"
        case .verificationFailed: return "系统返回的状态与目标不一致，请刷新后重试。"
        }
    }
}

enum AuthorizationResult: Equatable, Sendable {
    case applied
    case cancelled
}

protocol PowerAccess: Sendable {
    func read() async throws -> Bool
    func write(enabled: Bool) async throws -> AuthorizationResult
}

struct SystemPowerAccess: PowerAccess {
    static func parseStatus(_ output: String) throws -> Bool {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first == "SleepDisabled" else { continue }
            guard fields.count == 2 else { throw PowerError.unknownStatus }
            switch fields[1] {
            case "0": return false
            case "1": return true
            default: throw PowerError.unknownStatus
            }
        }
        throw PowerError.unknownStatus
    }

    // The privileged command has only two fixed forms. No user input enters it.
    static func authorizationScript(enabled: Bool) -> String {
        let value = enabled ? "1" : "0"
        let purpose = enabled ? "开启合盖保持运行" : "恢复正常睡眠"
        return """
        try
            do shell script "/usr/bin/pmset -a disablesleep \(value)" with prompt "合盖助手需要管理员授权，以\(purpose)。" with administrator privileges
            return "APPLIED"
        on error errorMessage number errorNumber
            if errorNumber is -128 then
                return "CANCELLED"
            end if
            error errorMessage number errorNumber
        end try
        """
    }

    static func parseAuthorization(_ output: String) throws -> AuthorizationResult {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "APPLIED": return .applied
        case "CANCELLED": return .cancelled
        default: throw PowerError.commandFailed("管理员验证未完成，请重试。")
        }
    }

    static func run(_ executable: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            // Both fixed commands emit little output. Keep diagnostics out of parsed stdout.
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw PowerError.commandFailed(detail.isEmpty ? text : detail)
            }
            return text
        }.value
    }

    func read() async throws -> Bool {
        try Self.parseStatus(await Self.run("/usr/bin/pmset", arguments: ["-g"]))
    }

    func write(enabled: Bool) async throws -> AuthorizationResult {
        let output = try await Self.run("/usr/bin/osascript", arguments: ["-e", Self.authorizationScript(enabled: enabled)])
        return try Self.parseAuthorization(output)
    }
}

enum SwitchOutcome: Equatable, Sendable {
    case applied(Bool)
    case cancelled(Bool)
}

struct PowerSwitch: Sendable {
    let access: any PowerAccess

    func set(enabled: Bool) async throws -> SwitchOutcome {
        let result = try await access.write(enabled: enabled)
        let actual = try await access.read()
        if result == .cancelled { return .cancelled(actual) }
        guard actual == enabled else { throw PowerError.verificationFailed }
        return .applied(actual)
    }

    func toggle() async throws -> SwitchOutcome {
        // Read again at click time: another utility may have changed the setting.
        let before = try await access.read()
        return try await set(enabled: !before)
    }
}
