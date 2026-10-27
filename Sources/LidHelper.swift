import AppKit
import SwiftUI
import IOKit.ps

struct ControlView: View {
    let model: PowerModel
    let quit: () -> Void

    private var tint: Color { model.enabled == true ? Color(red: 0.12, green: 0.53, blue: 0.40) : .accentColor }
    private var title: String {
        if model.maintenance == .active && model.enabled == false { return "正在恢复保持运行" }
        switch model.enabled {
        case true: return "合盖保持运行"
        case false: return "正常睡眠"
        case nil: return model.refreshing ? "正在读取状态" : "状态暂不可用"
        }
    }

    private var explanation: String {
        switch model.enabled {
        case true:
            return model.maintenance == .active
                ? "自动维持已开启；设置被改回时，会重新开启保持运行。"
                : "系统已禁用睡眠。开启自动维持，可在设置被改回时恢复。"
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
                Task {
                    if model.maintenance == .active { await model.disable() }
                    else { await model.enable() }
                }
            } label: {
                HStack(spacing: 8) {
                    if model.busy {
                        ProgressView().controlSize(.small)
                        Text("等待系统授权并核实…")
                    } else {
                        Image(systemName: model.enabled == true ? "moon.fill" : "power")
                        Text(model.maintenance == .active ? "恢复正常睡眠"
                             : model.maintenance == .interrupted ? "重新开启自动维持"
                             : model.enabled == true ? "开启自动维持" : "开启合盖保持运行")
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

            if model.enabled == true && model.maintenance != .active {
                Button("恢复正常睡眠") { Task { await model.disable() } }
                    .frame(maxWidth: .infinity)
                    .disabled(model.busy || model.refreshing)
            }

            if let message = model.message {
                Label(message, systemImage: model.failed ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(model.failed ? Color.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("开启后会增加耗电。首次使用请拔电合盖，确认远程连接和画面正常。")
                Text("退出工具会停止自动维持，但保留系统开关。结束办公请先恢复正常睡眠。")
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
    private var powerSource: CFRunLoopSource?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Different copies of the app must not run competing maintainers.
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "local.lidhelper.mac")
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate()
            NSApp.terminate(nil)
            return
        }
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
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(powerEnvironmentChanged), name: NSWorkspace.didWakeNotification, object: nil)
        powerSource = IOPSCreateLimitedPowerNotification({ context in
            guard let context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in await delegate.model.refresh() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.model.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        showPanel()
    }

    @objc private func powerEnvironmentChanged(_ notification: Notification) {
        Task { await model.refresh() }
    }

    private func updateStatusItem(_ enabled: Bool?) {
        guard statusItem != nil else { return }
        if model.maintenance == .interrupted {
            statusItem.button?.title = " 合盖·!"
            statusItem.button?.toolTip = "自动维持已中断，请点击重新开启。"
            return
        }
        if model.maintenance == .active && enabled != true {
            statusItem.button?.title = " 合盖·恢复中"
            statusItem.button?.toolTip = "正在核实并自动恢复保持运行。"
            return
        }
        switch enabled {
        case true:
            statusItem.button?.title = " 合盖·开"
            statusItem.button?.toolTip = model.maintenance == .active
                ? "合盖保持运行已开启，自动维持中。" : "系统保持运行已开启；点击开启自动维持。"
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
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        model.detach()
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
