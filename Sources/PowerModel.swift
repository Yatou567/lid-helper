import Foundation
import Observation

enum MaintenanceState: Equatable {
    case inactive, active, interrupted
}

@MainActor @Observable
final class PowerModel {
    private(set) var enabled: Bool?
    private(set) var maintenance: MaintenanceState = .inactive
    private(set) var busy = false
    private(set) var refreshing = false
    private(set) var message: String?
    private(set) var failed = false
    @ObservationIgnored private let access: any PowerAccess
    @ObservationIgnored private let session: any KeepAwakeSession
    @ObservationIgnored var stateChanged: ((Bool?) -> Void)?

    init(access: any PowerAccess = SystemPowerAccess(), session: (any KeepAwakeSession)? = nil) {
        self.access = access
        self.session = session ?? SystemKeepAwakeSession(access: access)
    }

    func refresh() async {
        guard !busy, !refreshing else { return }
        refreshing = true
        defer { refreshing = false; stateChanged?(enabled) }
        do {
            let previous = enabled
            enabled = try await access.read()
            if maintenance == .active {
                if !(await session.isRunning()) {
                    session.detach()
                    maintenance = .interrupted
                    failed = true
                    message = "自动维持已中断，请重新开启。"
                } else if enabled == false {
                    failed = true
                    message = "检测到系统设置被改回，正在自动恢复。"
                } else {
                    failed = false
                    message = "自动维持中，系统设置已核实。"
                }
            } else if maintenance == .inactive && (previous != enabled || failed) {
                // A successful message from an earlier click must not outlive
                // the actual state it described (the old UI could contradict itself).
                failed = false
                message = nil
            }
        } catch {
            enabled = nil
            failed = true
            message = error.localizedDescription
        }
    }

    func enable() async {
        guard !busy, !refreshing else { return }
        busy = true
        failed = false
        message = nil
        defer { busy = false; stateChanged?(enabled) }
        do {
            switch try await session.start() {
            case .applied:
                enabled = try await access.read()
                guard enabled == true, await session.isRunning() else { throw PowerError.verificationFailed }
                maintenance = .active
                message = "已开启自动维持，每 2 秒核实并恢复设置。"
            case .cancelled:
                enabled = try? await access.read()
                message = "已取消操作。"
            }
        } catch {
            session.detach()
            maintenance = .interrupted
            enabled = try? await access.read()
            failed = true
            message = error.localizedDescription
        }
    }

    func disable() async {
        guard !busy, !refreshing else { return }
        busy = true
        failed = false
        message = nil
        defer { busy = false; stateChanged?(enabled) }
        do {
            if try await session.stop() {
                maintenance = .inactive
                enabled = try await access.read()
                guard enabled == false else { throw PowerError.verificationFailed }
                message = "已停止自动维持，恢复正常睡眠。"
            } else {
                maintenance = .inactive
                switch try await PowerSwitch(access: access).set(enabled: false) {
                case .applied(let actual): enabled = actual; message = "已恢复正常睡眠，系统设置已核实。"
                case .cancelled(let actual): enabled = actual; message = "已取消操作。"
                }
            }
        } catch {
            enabled = try? await access.read()
            if !(await session.isRunning()) { maintenance = .inactive }
            failed = true
            message = error.localizedDescription
        }
    }

    func detach() { session.detach() }
}
