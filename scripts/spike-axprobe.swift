//
//  spike-axprobe.swift
//  探针：AX 逐帧驱动第三方窗口的开销。结论见 spec 11.4。
//
//  **必须包成 .app 从 ~/Applications 里跑。** 辅助功能授权按 TCC 的 responsible
//  process 算：直接 `swiftc` 出来在终端里跑，算的是终端的账；/private/tmp 底下的
//  .app 即便手动勾了开关也不生效。构建：
//
//      swiftc -O scripts/spike-axprobe.swift -o ~/Applications/AXProbe.app/Contents/MacOS/AXProbe
//      codesign --force --sign "Apple Development: ..." ~/Applications/AXProbe.app
//
//  Info.plist 要 CFBundleIdentifier = com.notchagent.axprobe（源码按它判断自己是不是
//  被 bundle 起来的）、LSUIElement = true。跑：
//
//      open -n ~/Applications/AXProbe.app --args drive 60 3 both   # 单项
//      open -n ~/Applications/AXProbe.app                          # 不带参数 = 跑全套
//
//  没有终端可打印，输出在 /tmp/axprobe-report.txt。**第 3 阶段做完要连 app 带授权
//  一起删掉**，见 plan 的「第 3 阶段完成标准」。
//

import Cocoa
import ApplicationServices

// ---------- helpers ----------

// 被 `open` 起来时没有终端可打印，输出重定向到固定文件，主进程回头读。
let reportPath = "/tmp/axprobe-report.txt"
let bundled = Bundle.main.bundleIdentifier == "com.notchagent.axprobe"
if bundled {
    freopen(reportPath, "w", stdout)
    freopen(reportPath, "a", stderr)
}

func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }
func say(_ s: String) { print(s); fflush(stdout) }

func axCopy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(el, attr as CFString, &v)
    return e == .success ? v : nil
}

func axPoint(_ el: AXUIElement, _ attr: String) -> CGPoint? {
    guard let v = axCopy(el, attr) else { return nil }
    var p = CGPoint.zero
    guard AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
    return p
}

func axSize(_ el: AXUIElement, _ attr: String) -> CGSize? {
    guard let v = axCopy(el, attr) else { return nil }
    var s = CGSize.zero
    guard AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
    return s
}

@discardableResult
func setPos(_ el: AXUIElement, _ p: CGPoint) -> AXError {
    var pp = p
    let v = AXValueCreate(.cgPoint, &pp)!
    return AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
}

@discardableResult
func setSize(_ el: AXUIElement, _ s: CGSize) -> AXError {
    var ss = s
    let v = AXValueCreate(.cgSize, &ss)!
    return AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
}

func stats(_ xs: [Double]) -> (med: Double, p95: Double, mx: Double, mean: Double) {
    let s = xs.sorted()
    func q(_ f: Double) -> Double { s[min(s.count - 1, max(0, Int((Double(s.count) * f).rounded(.down))))] }
    return (q(0.5), q(0.95), s.last ?? 0, xs.reduce(0,+) / Double(xs.count))
}

func fmt(_ d: Double) -> String { String(format: "%.2f", d) }

// ---------- target ----------

let args = CommandLine.arguments
let bundleID = ProcessInfo.processInfo.environment["AXPROBE_BUNDLE"] ?? "com.openai.codex"
let mode = args.count > 1 ? args[1] : (bundled ? "all" : "recon")

say("bundlePath=\(Bundle.main.bundlePath)")
say("execPath=\(Bundle.main.executablePath ?? "nil")")
say("trusted=\(AXIsProcessTrusted())")

let force = ProcessInfo.processInfo.environment["AXPROBE_FORCE"] == "1"
if !AXIsProcessTrusted() {
    say("AXIsProcessTrusted() == false")
    if bundled {
        // 弹系统那个「要在辅助功能里允许」的框。这一下会把本 app 自动加进
        // 系统设置的列表里（默认不勾），用户只需把开关打开，再起一次。
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        say("已弹出授权请求，请在「系统设置 → 隐私与安全性 → 辅助功能」里打开 AXProbe 的开关，然后重新运行。")
    }
    if !force { die("停下，需要辅助功能授权") }
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    die("找不到 \(bundleID)")
}
let pid = app.processIdentifier
let axApp = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(axApp, 5.0)

guard let winsRef = axCopy(axApp, kAXWindowsAttribute), let wins = winsRef as? [AXUIElement], !wins.isEmpty else {
    die("拿不到 \(bundleID) 的窗口列表")
}

// pick target window: prefer AXMain, else the largest
func winTitle(_ w: AXUIElement) -> String { (axCopy(w, kAXTitleAttribute) as? String) ?? "" }
var target = wins[0]
var best = -1.0
for w in wins {
    guard let s = axSize(w, kAXSizeAttribute) else { continue }
    let main = (axCopy(w, kAXMainAttribute) as? Bool) ?? false
    let score = Double(s.width * s.height) + (main ? 1e9 : 0)
    if score > best { best = score; target = w }
}

guard let origPos = axPoint(target, kAXPositionAttribute), let origSize = axSize(target, kAXSizeAttribute) else {
    die("读不到原始 frame")
}

// ---------- restore guard ----------
enum Guard {
    static var win: AXUIElement? = nil
    static var pos = CGPoint.zero
    static var size = CGSize.zero
    static var done = false
    static func restore() {
        if done { return }
        done = true
        guard let w = win else { return }
        setSize(w, size); setPos(w, pos)
        setSize(w, size); setPos(w, pos)
        let p = axPoint(w, kAXPositionAttribute) ?? .zero
        let s = axSize(w, kAXSizeAttribute) ?? .zero
        say("RESTORE want=(\(fmt(pos.x)),\(fmt(pos.y)) \(fmt(size.width))x\(fmt(size.height))) now=(\(fmt(p.x)),\(fmt(p.y)) \(fmt(s.width))x\(fmt(s.height)))")
    }
}
Guard.win = target
Guard.pos = origPos
Guard.size = origSize
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, { _ in Guard.restore(); exit(130) })
}
atexit { Guard.restore() }
func restore() { Guard.restore() }
var restored: Bool {
    get { Guard.done }
    set { Guard.done = newValue }
}

say("target pid=\(pid) title=\"\(winTitle(target))\" windows=\(wins.count)")
say("orig pos=(\(fmt(origPos.x)),\(fmt(origPos.y))) size=\(fmt(origSize.width))x\(fmt(origSize.height))")

// ---------- modes ----------

func benchPos(_ n: Int, jitter: Bool = true) -> [Double] {
    var out: [Double] = []
    for i in 0..<n {
        let p = CGPoint(x: origPos.x + Double(i % 2 == 0 ? 1 : 0), y: origPos.y)
        let t0 = DispatchTime.now().uptimeNanoseconds
        setPos(target, p)
        out.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    return out
}

func benchSize(_ n: Int) -> [Double] {
    var out: [Double] = []
    for i in 0..<n {
        let s = CGSize(width: origSize.width - Double(i % 2), height: origSize.height)
        let t0 = DispatchTime.now().uptimeNanoseconds
        setSize(target, s)
        out.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    return out
}

func benchBoth(_ n: Int) -> [Double] {
    var out: [Double] = []
    for i in 0..<n {
        let p = CGPoint(x: origPos.x + Double(i % 2), y: origPos.y)
        let s = CGSize(width: origSize.width - Double(i % 2), height: origSize.height)
        let t0 = DispatchTime.now().uptimeNanoseconds
        setPos(target, p)
        setSize(target, s)
        out.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    return out
}

func report(_ label: String, _ xs: [Double]) {
    let s = stats(xs)
    say("\(label): n=\(xs.count) med=\(fmt(s.med)) p95=\(fmt(s.p95)) max=\(fmt(s.mx)) mean=\(fmt(s.mean))")
}

// AXPROBE_WAIT=8 → 先倒数，给人时间让 ChatGPT 开始出字/滚动，制造负载
if let w = ProcessInfo.processInfo.environment["AXPROBE_WAIT"], let secs = Int(w), secs > 0 {
    for i in stride(from: secs, to: 0, by: -1) { say("  等待 \(i)s ...") ; sleep(1) }
}

func runRecon() {
    // list windows
    for (i, w) in wins.enumerated() {
        let p = axPoint(w, kAXPositionAttribute), s = axSize(w, kAXSizeAttribute)
        let main = (axCopy(w, kAXMainAttribute) as? Bool) ?? false
        say("  win[\(i)] main=\(main) \"\(winTitle(w))\" pos=\(p.map{"(\(fmt($0.x)),\(fmt($0.y)))"} ?? "nil") size=\(s.map{"\(fmt($0.width))x\(fmt($0.height))"} ?? "nil")")
    }
    // attribute names + settability
    var names: CFArray?
    AXUIElementCopyAttributeNames(target, &names)
    let attrs = (names as? [String]) ?? []
    say("attrs: \(attrs.joined(separator: ", "))")
    for a in [kAXPositionAttribute, kAXSizeAttribute, kAXMinValueAttribute, kAXMaxValueAttribute] {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(target, a as CFString, &settable)
        say("  \(a) settable=\(settable.boolValue) value=\(String(describing: axCopy(target, a)))")
    }
}

func runMinsize() {
    // binary search the honored minimum for width and height independently
    func probe(_ w: Double, _ h: Double) -> CGSize {
        setSize(target, CGSize(width: w, height: h))
        usleep(60_000)
        return axSize(target, kAXSizeAttribute) ?? .zero
    }
    _ = probe(200, 200)
    let clamped = axSize(target, kAXSizeAttribute)!
    say("ask 200x200 -> got \(fmt(clamped.width))x\(fmt(clamped.height))")
    _ = probe(100, 100)
    say("ask 100x100 -> got \(fmt(axSize(target, kAXSizeAttribute)!.width))x\(fmt(axSize(target, kAXSizeAttribute)!.height))")
    // width binary search at generous height
    var lo = 100.0, hi = 1200.0
    for _ in 0..<12 {
        let mid = (lo + hi) / 2
        let got = probe(mid, 900)
        if abs(got.width - mid) < 1.5 { hi = mid } else { lo = mid }
    }
    say("min width ~ \(fmt(hi)) (lo=\(fmt(lo)))")
    lo = 100; hi = 1200
    for _ in 0..<12 {
        let mid = (lo + hi) / 2
        let got = probe(1000, mid)
        if abs(got.height - mid) < 1.5 { hi = mid } else { lo = mid }
    }
    say("min height ~ \(fmt(hi)) (lo=\(fmt(lo)))")
}

func runLatency(_ n: Int, tag: String = "") {
    _ = benchPos(20) // warm
    report("POS  \(tag)", benchPos(n))
    report("SIZE \(tag)", benchSize(n))
    report("BOTH \(tag)", benchBoth(n))
}

func runDrive(_ hz: Double, _ secs: Double, _ what: String) {
    let period = 1.0 / hz
    let total = Int(secs * hz)
    var call: [Double] = []
    var applied = 0
    var lastH = 0.0
    let start = DispatchTime.now().uptimeNanoseconds
    var deadline = Double(start) / 1e9
    for i in 0..<total {
        // animate height like a drag: 400..900
        let phase = Double(i) / Double(total)
        let h = 620 + 280 * (0.5 - 0.5 * cos(phase * 2 * .pi))
        let w = origSize.width
        let y = origPos.y
        let t0 = DispatchTime.now().uptimeNanoseconds
        switch what {
        case "pos":  setPos(target, CGPoint(x: origPos.x, y: y + (h - 620) * 0.2))
        case "size": setSize(target, CGSize(width: w, height: h))
        default:
            setPos(target, CGPoint(x: origPos.x, y: y + (h - 620) * 0.2))
            setSize(target, CGSize(width: w, height: h))
        }
        call.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        applied += 1
        lastH = h
        deadline += period
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        if deadline > now { usleep(useconds_t((deadline - now) * 1e6)) }
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    let s = stats(call)
    say("DRIVE \(what) target=\(fmt(hz))Hz frames=\(applied) elapsed=\(fmt(elapsed))s actual=\(fmt(Double(applied)/elapsed))fps callMed=\(fmt(s.med)) p95=\(fmt(s.p95)) max=\(fmt(s.mx))")
    // 拖尾：松手瞬间窗口离最终值还差多少，多久追上
    let t1 = DispatchTime.now().uptimeNanoseconds
    let immediate = axSize(target, kAXSizeAttribute)?.height ?? -1
    var settleMs = -1.0
    for _ in 0..<400 {
        let h = axSize(target, kAXSizeAttribute)?.height ?? -1
        if abs(h - lastH) < 2 { settleMs = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e6; break }
        usleep(5_000)
    }
    say("  tail \(what)@\(fmt(hz))Hz: commanded=\(fmt(lastH)) atRelease=\(fmt(immediate)) lagPx=\(fmt(abs(immediate - lastH))) settleMs=\(fmt(settleMs)) (~\(fmt(settleMs / (1000/hz))) frames)")
}

switch mode {
case "recon":
    runRecon()
    restored = true // recon touches nothing
case "minsize":
    runMinsize()
case "latency":
    runLatency(args.count > 2 ? Int(args[2])! : 200)
case "drive":
    runDrive(args.count > 2 ? Double(args[2])! : 60,
             args.count > 3 ? Double(args[3])! : 3,
             args.count > 4 ? args[4] : "both")

// 被 `open` 起来时没法传参，一趟把整套跑完。
case "all":
    say("=== 1 recon ===");            runRecon()
    say("=== 2 latency 空闲 ===");      runLatency(200, tag: "idle")
    say("=== 3 drive 60Hz both ===");  runDrive(60, 3, "both")
    say("=== 4 drive 30Hz both ===");  runDrive(30, 3, "both")
    say("=== 5 drive 60Hz 只挪位置 ==="); runDrive(60, 3, "pos")
    say("=== 6 minsize ===");          runMinsize()
    // 让目标 app 忙起来再测一遍：这 12 秒里人去 ChatGPT 里发一个会长篇输出的问题。
    say("=== 7 等 12s，请让 ChatGPT 开始输出长回答 ===")
    for i in stride(from: 12, to: 0, by: -1) { say("  \(i)s"); sleep(1) }
    say("=== 8 latency 忙时 ===");      runLatency(200, tag: "busy")
    say("=== 9 drive 60Hz both 忙时 ==="); runDrive(60, 3, "both")
    say("=== 跑完 ===")

default:
    die("unknown mode \(mode)")
}

restore()
