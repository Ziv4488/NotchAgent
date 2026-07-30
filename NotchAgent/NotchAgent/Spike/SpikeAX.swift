//
//  SpikeAX.swift
//  探针 C —— 验证第三方 app 对 AXPosition / AXSize 的响应、窗口最小尺寸、恢复精度。
//
//  同时验证 spec 8 的一条设计：AX 调用放后台队列 + 设置消息超时。
//  这是抛弃型代码，第 0.6 步会删除。
//

import AppKit
import ApplicationServices

struct SpikeAX {

    // MARK: - 权限

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 请求辅助功能权限（会弹系统提示，引导到设置面板）。
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - 候选 app

    struct Candidate: Identifiable {
        var id: pid_t { pid }
        let pid: pid_t
        let name: String
        let bundleID: String
    }

    /// 当前有界面的运行中 app，供探针挑选目标。
    static func candidates() -> [Candidate] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .map { Candidate(pid: $0.processIdentifier,
                             name: $0.localizedName ?? "?",
                             bundleID: $0.bundleIdentifier ?? "?") }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: - 探测

    /// 在后台队列上探测目标 app 的主窗口，报告文本回到主线程。
    static func probe(pid: pid_t, name: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let report = probeSync(pid: pid, name: name)
            DispatchQueue.main.async { completion(report) }
        }
    }

    private static func probeSync(pid: pid_t, name: String) -> String {
        var out = ["### \(name)"]

        let app = AXUIElementCreateApplication(pid)
        // spec 8 要求的超时：目标 app 无响应时不能把调用方拖死。
        AXUIElementSetMessagingTimeout(app, 2.0)

        guard let window = firstWindow(of: app) else {
            out.append("  ✗ 取不到 AXWindows（app 可能没开窗口，或不支持 AX）")
            return out.joined(separator: "\n")
        }

        guard let origPos = point(window, kAXPositionAttribute),
              let origSize = size(window, kAXSizeAttribute) else {
            out.append("  ✗ 读不到 AXPosition / AXSize")
            return out.joined(separator: "\n")
        }
        out.append("  原始 frame: \(fmt(origPos)) \(fmt(origSize))")

        // 1. 压到极小，读回来的就是它的最小尺寸
        set(window, kAXSizeAttribute, size: CGSize(width: 60, height: 60))
        usleep(120_000)
        let minSize = size(window, kAXSizeAttribute) ?? .zero
        out.append("  最小尺寸: \(fmt(minSize))")

        // 2. 设成一个「岛内容区」大小的目标，看它听不听
        let targetPos = CGPoint(x: 400, y: 40)
        let targetSize = CGSize(width: 560, height: 420)
        set(window, kAXPositionAttribute, point: targetPos)
        set(window, kAXSizeAttribute, size: targetSize)
        usleep(120_000)
        let gotPos = point(window, kAXPositionAttribute) ?? .zero
        let gotSize = size(window, kAXSizeAttribute) ?? .zero
        let posOK = near(gotPos, targetPos)
        let sizeOK = near(gotSize, targetSize)
        out.append("  设定 \(fmt(targetPos)) \(fmt(targetSize))")
        out.append("  实得 \(fmt(gotPos)) \(fmt(gotSize))")
        out.append("  位置\(posOK ? "✓ 听" : "✗ 不听")   尺寸\(sizeOK ? "✓ 听" : "✗ 不听")")

        // 3. 恢复原状，检查精度
        set(window, kAXPositionAttribute, point: origPos)
        set(window, kAXSizeAttribute, size: origSize)
        usleep(120_000)
        let backPos = point(window, kAXPositionAttribute) ?? .zero
        let backSize = size(window, kAXSizeAttribute) ?? .zero
        let restored = near(backPos, origPos) && near(backSize, origSize)
        out.append("  恢复原位: \(restored ? "✓ 精确" : "✗ 有偏差 → \(fmt(backPos)) \(fmt(backSize))")")

        return out.joined(separator: "\n")
    }

    // MARK: - AX 小工具

    private static func firstWindow(of app: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement], let first = windows.first
        else { return nil }
        return first
    }

    private static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
              let value = ref as! AXValue? else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &p) ? p : nil
    }

    private static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
              let value = ref as! AXValue? else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(value, .cgSize, &s) ? s : nil
    }

    private static func set(_ el: AXUIElement, _ attr: String, point: CGPoint) {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return }
        AXUIElementSetAttributeValue(el, attr as CFString, v)
    }

    private static func set(_ el: AXUIElement, _ attr: String, size: CGSize) {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return }
        AXUIElementSetAttributeValue(el, attr as CFString, v)
    }

    private static func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 2 && abs(a.y - b.y) < 2
    }

    private static func near(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    private static func fmt(_ p: CGPoint) -> String {
        "(\(Int(p.x)),\(Int(p.y)))"
    }

    private static func fmt(_ s: CGSize) -> String {
        "\(Int(s.width))×\(Int(s.height))"
    }
}
