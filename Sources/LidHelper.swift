import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class PowerModel {
    private(set) var enabled: Bool?
    private(set) var busy = false
    private(set) var refreshing = false
    private(set) var message: String?
    private(set) var failed = false
    @ObservationIgnored private let access: any PowerAccess
    @ObservationIgnored var stateChanged: ((Bool?) -> Void)?

    init(access: any PowerAccess = SystemPowerAccess()) { self.access = access }

    func refresh() async {
        guard !busy, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            enabled = try await access.read()
            if failed { failed = false; message = nil }
            stateChanged?(enabled)
        } catch {
            enabled = nil
            stateChanged?(nil)
            failed = true
            message = error.localizedDescription
        }
    }

    func toggle() async {
        guard !busy, !refreshing else { return }
        busy = true
        message = nil
        failed = false
        defer { busy = false }
        do {
            switch try await PowerSwitch(access: access).toggle() {
            case .applied(let actual):
                enabled = actual
                message = actual ? "已开启，系统设置已核实。" : "已恢复，系统设置已核实。"
            case .cancelled(let actual):
                enabled = actual
                message = "已取消操作。"
            }
        } catch {
            // Never display a successful state when authorization or verification fails.
            enabled = try? await access.read()
            failed = true
            message = error.localizedDescription
        }
        stateChanged?(enabled)
    }
}

struct ControlView: View {
    let model: PowerModel
    let quit: () -> Void

    private var tint: Color { model.enabled == true ? Color(red: 0.12, green: 0.53, blue: 0.40) : .accentColor }
    private var title: String {
        switch model.enabled {
        case true: return "合盖保持运行"
        case false: return "正常睡眠"
        case nil: return model.refreshing ? "正在读取状态" : "状态暂不可用"
        }
    }

    private var explanation: String {
        switch model.enabled {
        case true: return "已禁用系统睡眠，可用于合盖远程办公。"
        case false: return "允许系统按原有规则睡眠，电池供电合盖通常会睡眠。"
        case nil: return "读取到系统状态后，才可以切换睡眠设置。"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label("合盖助手", systemImage: "laptopcomputer")
                    .font(.headline)
                Spacer()
                Text("电池 · 插电均适用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 8) {
                    Circle().fill(model.enabled == nil ? Color.secondary : tint).frame(width: 7, height: 7)
                    Text("系统当前状态").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: model.enabled == true ? "bolt.fill" : "moon.zzz.fill")
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                }
                Text(title).font(.system(size: 27, weight: .semibold))
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))

            Button {
                Task { await model.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if model.busy {
                        ProgressView().controlSize(.small)
                        Text("等待系统授权并核实…")
                    } else {
                        Image(systemName: model.enabled == true ? "moon.fill" : "power")
                        Text(model.enabled == true ? "恢复正常睡眠" : "开启合盖保持运行")
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 35)
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .controlSize(.large)
            .disabled(model.busy || model.refreshing || model.enabled == nil)
            .accessibilityIdentifier("power-toggle")
            .help("修改系统电源设置时，macOS 会请求管理员授权。")

            if let message = model.message {
                Label(message, systemImage: model.failed ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(model.failed ? Color.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("开启后会增加耗电。首次使用请拔电合盖，确认远程连接和画面正常。")
                Text("退出工具不会恢复睡眠；结束办公后请点击“恢复正常睡眠”。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Button { Task { await model.refresh() } } label: {
                    Label("刷新状态", systemImage: "arrow.clockwise")
                }
                .disabled(model.busy || model.refreshing)
                Spacer()
                Button("退出", action: quit).disabled(model.busy)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = PowerModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var pollingTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "合盖助手")
            button.image?.isTemplate = true
            button.title = " 合盖"
            button.target = self
            button.action = #selector(showPanel)
        }
        model.stateChanged = { [weak self] enabled in self?.updateStatusItem(enabled) }
        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(rootView: ControlView(model: model) {
            NSApp.terminate(nil)
        })
        hosting.sizingOptions = [.intrinsicContentSize, .preferredContentSize]
        popover.contentViewController = hosting
        popover.contentSize = hosting.view.fittingSize
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.model.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        showPanel()
    }

    private func updateStatusItem(_ enabled: Bool?) {
        switch enabled {
        case true:
            statusItem.button?.title = " 合盖·开"
            statusItem.button?.toolTip = "合盖保持运行已开启；点击恢复正常睡眠。"
        case false:
            statusItem.button?.title = " 合盖·关"
            statusItem.button?.toolTip = "当前允许正常睡眠；点击开启合盖保持运行。"
        case nil:
            statusItem.button?.title = " 合盖·?"
            statusItem.button?.toolTip = "无法确定睡眠设置，请点击刷新。"
        }
    }

    @objc private func showPanel() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await model.refresh() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { showPanel() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.busy ? .terminateCancel : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollingTask?.cancel()
    }
}

@main
struct LidHelper {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--status") {
            do {
                let enabled = try await SystemPowerAccess().read()
                print("SleepDisabled=\(enabled ? 1 : 0)")
            } catch {
                print(error.localizedDescription)
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
