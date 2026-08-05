#!/usr/bin/env swift
// Tersey Дуэль — клон трио + «⚖ судья»: третий (haiku) сравнивает ответы
// CLAUDE и CODEX и показывает победителя в строке-вердикте.
// Каждый чат = пара Claude+Codex со своей историей и своими моделями.
// Истории живут в ~/.terseylite/chats.json и восстанавливаются при запуске.
// Плюс кнопка «права»: разом запрашивает все маковские TCC-пермишены.
// Сборка: ./build2.sh (подпись Apple Development — права переживают ребилд,
// пока bundle id и сертификат те же).
import AppKit
import AVFoundation
import Speech
import Contacts
import EventKit
import Photos
import CoreLocation
import CoreBluetooth
import Network
import IOKit.hid
import ApplicationServices

// ── палитра (светлая, как у большого Tersey) ─────────────────────────────
func hex(_ h: String) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: String(h.dropFirst())).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}
let BG = hex("#faf9f5"), FG = hex("#1a1a18"), MUT = hex("#8a8778"), LINE = hex("#e3e0d6")
let CLA = hex("#c96442"), COD = hex("#2f7d6b"), OKC = hex("#3a8a4a"), ERRC = hex("#c0392b")

let selfPath = #filePath
func weightKB() -> String {
    var sz = (try? FileManager.default.attributesOfItem(atPath: selfPath))?[.size] as? Int ?? 0
    if sz == 0, let exe = Bundle.main.executablePath { // из .app исходника не видно — вес бинарника
        sz = (try? FileManager.default.attributesOfItem(atPath: exe))?[.size] as? Int ?? 0
    }
    return String(format: "вес: %.1f КБ", Double(sz) / 1024)
}

// ── фейковое 3D: математика в cube.s, рукописный ARM64 ───────────────────
@_silgen_name("cube_rotpro")
func cubeRotPro(_ sinY: Double, _ cosY: Double, _ sinX: Double, _ cosX: Double,
                _ out: UnsafeMutablePointer<Double>)

final class CubeView: NSView {
    var a = 0.6, b = 0.35
    override init(frame: NSRect) {
        super.init(frame: frame)
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            s.a += 0.029; s.b += 0.017
            s.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 46, height: 40) }
    override func draw(_ dirty: NSRect) {
        var pts = [Double](repeating: 0, count: 16)
        cubeRotPro(sin(a), cos(a), sin(b), cos(b), &pts)
        let cx = bounds.midX, cy = bounds.midY
        let s = min(bounds.width, bounds.height) * 0.62
        func pt(_ i: Int) -> NSPoint {
            NSPoint(x: cx + CGFloat(pts[i * 2]) * s, y: cy + CGFloat(pts[i * 2 + 1]) * s)
        }
        let path = NSBezierPath()
        path.lineWidth = 1
        for i in 0..<8 {
            for j in (i + 1)..<8 where ((i ^ j).nonzeroBitCount == 1) {
                path.move(to: pt(i)); path.line(to: pt(j))
            }
        }
        CLA.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }
}

// ── поиск CLI и запуск ───────────────────────────────────────────────────
func findBin(_ name: String, _ extra: [String]) -> String {
    let home = NSHomeDirectory()
    var cands = extra.map { $0.replacingOccurrences(of: "~", with: home) }
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        cands.append("\(dir)/\(name)")
    }
    return cands.first { FileManager.default.isExecutableFile(atPath: $0) } ?? name
}
let claudeBin = findBin("claude", ["~/.local/bin/claude"])
let codexBin = findBin("codex", ["~/.local/opt/node-v22.23.1-darwin-arm64/bin/codex"])

// блокирующий запуск (для --version)
func runCLI(_ argv: [String], timeout: TimeInterval, cwd: URL? = nil) -> (out: String, err: String, ok: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    if let cwd { p.currentDirectoryURL = cwd }
    var env = ProcessInfo.processInfo.environment
    for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_API_KEY", "OPENAI_API_KEY", "OPENAI_ORG_ID", "OPENAI_PROJECT_ID", "CODEX_API_KEY"] { env.removeValue(forKey: key) }
    p.environment = env
    let outP = Pipe(), errP = Pipe()
    p.standardOutput = outP; p.standardError = errP
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return ("", "[ошибка] \(error.localizedDescription)", false) }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
    let o = outP.fileHandleForReading.readDataToEndOfFile()
    let e = errP.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: o, encoding: .utf8) ?? "",
            String(data: e, encoding: .utf8) ?? "",
            p.terminationStatus == 0)
}

// потоковый запуск: каждая строка stdout → onLine (JSONL от обоих CLI)
func streamCLI(_ argv: [String], cwd: URL?, timeout: TimeInterval,
               onLine: @escaping (String) -> Void) -> (err: String, ok: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    if let cwd { p.currentDirectoryURL = cwd }
    var env = ProcessInfo.processInfo.environment
    for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_API_KEY", "OPENAI_API_KEY", "OPENAI_ORG_ID", "OPENAI_PROJECT_ID", "CODEX_API_KEY"] { env.removeValue(forKey: key) }
    p.environment = env
    let outP = Pipe(), errP = Pipe()
    p.standardOutput = outP; p.standardError = errP
    p.standardInput = FileHandle.nullDevice
    let lock = NSLock()
    var buf = Data(), errData = Data()
    outP.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        guard !d.isEmpty else { return }
        lock.lock()
        buf.append(d)
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = buf.prefix(upTo: nl)
            buf = Data(buf.suffix(from: buf.index(after: nl)))
            if let s = String(data: line, encoding: .utf8), !s.isEmpty { onLine(s) }
        }
        lock.unlock()
    }
    errP.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        guard !d.isEmpty else { return }
        lock.lock(); errData.append(d); lock.unlock()
    }
    do { try p.run() } catch { return ("[ошибка] \(error.localizedDescription)", false) }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
    p.waitUntilExit()
    outP.fileHandleForReading.readabilityHandler = nil
    errP.fileHandleForReading.readabilityHandler = nil
    lock.lock()
    if !buf.isEmpty, let s = String(data: buf, encoding: .utf8),
       !s.trimmingCharacters(in: .whitespaces).isEmpty { onLine(s) }
    let err = String(data: errData, encoding: .utf8) ?? ""
    lock.unlock()
    return (err, p.terminationStatus == 0)
}

// баннер codex из stderr: model / sandbox / reasoning effort
func codexBanner(_ err: String) -> String {
    var model = "", sandbox = "", eff = ""
    for l in err.components(separatedBy: "\n") {
        let t = l.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("model: ") { model = String(t.dropFirst(7)) }
        else if t.hasPrefix("sandbox: ") { sandbox = String(t.dropFirst(9)) }
        else if t.hasPrefix("reasoning effort: ") { eff = String(t.dropFirst(18)) }
    }
    return [model, eff.isEmpty ? "" : "effort \(eff)", sandbox]
        .filter { !$0.isEmpty }.joined(separator: " · ")
}

// ── чат: пара панелей со своей историей, сессиями и моделями ─────────────
final class Chat {
    var title = "чат"
    var sessC: String?, sessX: String?    // resume-ид у claude / thread у codex
    var ansC = "", ansX = ""              // накопленный ответ этого хода (для судьи)
    var lastPrompt = ""
    var verdictText = "⚖ ждёт ответов…"   // строка вердикта (на чат)
    var verdictColor = MUT
    var modelC = "opus"                   // claude --model (опус — дефолт)
    var modelX = "gpt-5.6-sol"            // codex -c model (топовая, tier fast из конфига)
    var row: NSStackView!
    var svC: NSScrollView!, svX: NSScrollView!
    var tvC: NSTextView!, tvX: NSTextView!
    var metaCText = " ", metaXText = " "
    var started = false                   // заголовок вкладки взят из первого промпта
    var pending = 0
    var metaEndC = "", okC = true, gotTextC = false
    var tokensX = "", gotTextX = false
}

// ── UI ───────────────────────────────────────────────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var entry: NSTextField!, status: NSTextField!, btn: NSButton!
    var labC: NSTextField!, labX: NSTextField!
    var metaC: NSTextField!, metaX: NSTextField!
    var modeSeg: NSSegmentedControl!, effortSeg: NSSegmentedControl!
    var popC: NSPopUpButton!, comboX: NSComboBox!
    var verdict: NSTextField!
    var dirBtn: NSButton!
    var tabs: NSSegmentedControl!
    var bodyHost: NSView!
    var chats: [Chat] = []
    var cur = 0
    // ── фейковое 3D всей аппы: CALayer-перспектива + параллакс за мышкой ──
    var tiltOn = true
    var tiltViews: [(NSView, CGFloat)] = [] // (вью, базовый наклон по Y в радианах)
    var mouseDX: CGFloat = 0, mouseDY: CGFloat = 0
    // держатели для запросов прав (иначе менеджеры умирают до показа диалога)
    var locMgr: CLLocationManager?
    var btMgr: CBCentralManager?
    var netBrowser: NWBrowser?
    var ekStore = EKEventStore()
    // рабочая папка агентов; при запуске из .app cwd = "/", тогда — ~/Avatar
    var workDir: URL = {
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd == "/" ? NSHomeDirectory() + "/Avatar" : cwd)
    }()

    let stateDir = URL(fileURLWithPath: NSHomeDirectory() + "/.terseylite")
    var stateFile: URL { stateDir.appendingPathComponent("chats.json") }

    let mono = NSFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
    let monob = NSFont(name: "Menlo-Bold", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .bold)
    let small = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)

    var isWork: Bool { modeSeg.selectedSegment == 1 }
    var effort: String { ["low", "medium", "high"][effortSeg.selectedSegment] }
    var chat: Chat { chats[cur] }

    func label(_ text: String, _ color: NSColor, _ f: NSFont) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = color; l.font = f; l.backgroundColor = .clear
        l.lineBreakMode = .byTruncatingTail
        return l
    }

    func pane() -> (NSScrollView, NSTextView) {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        sv.borderType = .lineBorder
        tv.isEditable = false
        tv.font = mono
        tv.backgroundColor = .white
        tv.textContainerInset = NSSize(width: 12, height: 10)
        return (sv, tv)
    }

    func append(_ tv: NSTextView, _ text: String, _ color: NSColor) {
        let a = NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: mono])
        tv.textStorage?.append(a)
        tv.scrollToEndOfDocument(nil)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu(), appItem = NSMenuItem()
        let sub = NSMenu()
        sub.addItem(withTitle: "Quit TERSEY · дуэль", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = sub; menu.addItem(appItem)
        // Edit-меню — без него Cmd+C/V/X/A не работают в поле ввода
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "TERSEY · дуэль"
        window.minSize = NSSize(width: 760, height: 480)
        window.backgroundColor = BG
        window.center()
        if let scr = NSScreen.main { // --left/--right = своя половина монитора
            let vf = scr.visibleFrame
            let half = NSRect(x: vf.minX, y: vf.minY, width: vf.width / 2, height: vf.height)
            if CommandLine.arguments.contains("--left") { window.setFrame(half, display: true) }
            else if CommandLine.arguments.contains("--right") {
                window.setFrame(half.offsetBy(dx: vf.width / 2, dy: 0), display: true)
            }
        }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 10, left: 18, bottom: 16, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
        ])
        func full(_ v: NSView) { v.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true }

        // шапка: куб (асм!) + имя + вес + режим/effort + модели + права + статус
        let head = NSStackView()
        head.orientation = .horizontal
        head.spacing = 10
        status = label("готов", MUT, small)
        modeSeg = NSSegmentedControl(labels: ["план", "ворк"], trackingMode: .selectOne,
                                     target: nil, action: nil)
        modeSeg.selectedSegment = 1 // по дефолту ворк = байпас
        modeSeg.font = small
        effortSeg = NSSegmentedControl(labels: ["low", "med", "high"], trackingMode: .selectOne,
                                       target: nil, action: nil)
        effortSeg.selectedSegment = 2
        effortSeg.font = small
        effortSeg.toolTip = "effort claude; codex — medium из конфига"
        popC = NSPopUpButton()
        popC.addItems(withTitles: ["opus", "sonnet", "haiku", "fable"])
        popC.font = small
        popC.toolTip = "модель claude (текущего чата)"
        comboX = NSComboBox()
        comboX.addItems(withObjectValues: ["gpt-5.6-sol", "gpt-5.6-sol-light"])
        comboX.stringValue = "gpt-5.6-sol"
        comboX.font = small
        comboX.toolTip = "модель codex (текущего чата), можно вписать свою"
        comboX.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let permBtn = NSButton(title: "🔑 права", target: self, action: #selector(grantAll))
        permBtn.bezelStyle = .rounded
        permBtn.font = small
        permBtn.toolTip = "запросить все маковские пермишены разом"
        let t3 = NSButton(checkboxWithTitle: "3д", target: self, action: #selector(toggle3d(_:)))
        t3.state = .on
        t3.font = small
        head.addView(CubeView(frame: .zero), in: .leading)
        head.addView(label("TERSEY · дуэль", FG, monob), in: .leading)
        head.addView(label(weightKB(), OKC, small), in: .leading)
        head.addView(modeSeg, in: .center)
        head.addView(effortSeg, in: .center)
        head.addView(popC, in: .center)
        head.addView(comboX, in: .center)
        head.addView(permBtn, in: .center)
        head.addView(t3, in: .center)
        head.addView(status, in: .trailing)
        root.addArrangedSubview(head); full(head)

        // ряд вкладок: чаты + новый + папка
        tabs = NSSegmentedControl(labels: [], trackingMode: .selectOne,
                                  target: self, action: #selector(tabPicked))
        tabs.font = small
        let addBtn = NSButton(title: "＋ чат", target: self, action: #selector(newChat))
        addBtn.bezelStyle = .rounded
        addBtn.font = small
        dirBtn = NSButton(title: "📁 \(workDir.lastPathComponent)", target: self, action: #selector(pickDir))
        dirBtn.bezelStyle = .rounded
        dirBtn.font = small
        dirBtn.toolTip = workDir.path
        let tabRow = NSStackView(views: [tabs, addBtn, dirBtn])
        tabRow.orientation = .horizontal
        tabRow.spacing = 8
        root.addArrangedSubview(tabRow); full(tabRow)

        let sep = NSBox()
        sep.boxType = .custom; sep.fillColor = LINE; sep.borderWidth = 0
        sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(sep); full(sep)

        // заголовки колонок
        labC = label("CLAUDE", CLA, small)
        labX = label("CODEX", COD, small)
        let heads = NSStackView(views: [labC, labX])
        heads.orientation = .horizontal
        heads.distribution = .fillEqually
        root.addArrangedSubview(heads); full(heads)

        // хост панелей: у каждого чата своя пара, видима только активная
        bodyHost = NSView()
        bodyHost.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(bodyHost); full(bodyHost)
        bodyHost.setContentHuggingPriority(.defaultLow, for: .vertical)

        // мета-строки: модель · токены · права · effort
        metaC = label(" ", MUT, small)
        metaX = label(" ", MUT, small)
        let metas = NSStackView(views: [metaC, metaX])
        metas.orientation = .horizontal
        metas.distribution = .fillEqually
        root.addArrangedSubview(metas); full(metas)

        // ── строка-вердикт судьи (видна сразу) ────────────────────────────
        verdict = label("⚖ ждёт ответов…", MUT, monob)
        verdict.alignment = .center
        root.addArrangedSubview(verdict); full(verdict)

        // строка ввода
        entry = NSTextField()
        entry.font = mono
        entry.placeholderString = "спроси обоих…"
        entry.target = self
        entry.action = #selector(send)
        btn = NSButton(title: "Отправить", target: self, action: #selector(send))
        btn.bezelStyle = .rounded
        let bar = NSStackView(views: [label("❯", MUT, monob), entry, btn])
        bar.orientation = .horizontal
        bar.spacing = 8
        root.addArrangedSubview(bar); full(bar)
        entry.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // ── сцена фейкового 3D ────────────────────────────────────────────
        window.contentView!.wantsLayer = true
        tiltViews = [(root, 0)]
        watchFrames(root)
        window.acceptsMouseMovedEvents = true
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] ev in
            guard let s = self, let cv = s.window.contentView else { return ev }
            let p = cv.convert(ev.locationInWindow, from: nil)
            s.mouseDX = max(-0.5, min(0.5, p.x / max(cv.bounds.width, 1) - 0.5))
            s.mouseDY = max(-0.5, min(0.5, p.y / max(cv.bounds.height, 1) - 0.5))
            s.applyTilts()
            return ev
        }

        // ── чаты: восстановить с диска или создать три пустых ────────────
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let restored = loadChats()
        if !restored {
            for i in 1...3 { addChat(Chat(), title: "чат \(i)") }
            entry.stringValue = "Одним словом: столица Франции?" // просто нажми Отправить
        }
        selectTab(min(cur, chats.count - 1))

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(entry)
        window.layoutIfNeeded()
        DispatchQueue.main.async { self.applyTilts() }

        // версии CLI — подтягиваем асинхронно, не блокируя окно
        DispatchQueue.global().async {
            let v = runCLI([claudeBin, "--version"], timeout: 20).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: " ").first ?? ""
            DispatchQueue.main.async { if !v.isEmpty { self.labC.stringValue = "CLAUDE  \(v)" } }
        }
        DispatchQueue.global().async {
            let v = runCLI([codexBin, "--version"], timeout: 20).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: " ").last ?? ""
            DispatchQueue.main.async { if !v.isEmpty { self.labX.stringValue = "CODEX  \(v)" } }
        }

        if CommandLine.arguments.contains("--grant") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.grantAll() }
        }
        if CommandLine.arguments.contains("--selftest") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.send() }
        }
    }

    func watchFrames(_ v: NSView) {
        v.wantsLayer = true
        v.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                               object: v, queue: .main) { [weak self] _ in
            self?.applyTilts()
        }
    }

    // ── вкладки ──────────────────────────────────────────────────────────
    func addChat(_ c: Chat, title: String) {
        c.title = title
        let (svC, tvC) = pane(); let (svX, tvX) = pane()
        c.svC = svC; c.tvC = tvC; c.svX = svX; c.tvX = tvX
        let row = NSStackView(views: [svC, svX])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        c.row = row
        bodyHost.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: bodyHost.topAnchor),
            row.bottomAnchor.constraint(equalTo: bodyHost.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: bodyHost.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bodyHost.trailingAnchor),
        ])
        row.isHidden = true
        tiltViews.append((svC, 0.11)); tiltViews.append((svX, -0.11))
        watchFrames(svC); watchFrames(svX)
        chats.append(c)
        rebuildTabs()
    }

    func rebuildTabs() {
        tabs.segmentCount = chats.count
        for (i, c) in chats.enumerated() {
            tabs.setLabel(String(c.title.prefix(12)), forSegment: i)
        }
        if cur < chats.count { tabs.selectedSegment = cur }
    }

    func syncControlsIntoChat() {
        guard cur < chats.count else { return }
        let c = chats[cur]
        c.modelC = popC.titleOfSelectedItem ?? "opus"
        let mx = comboX.stringValue.trimmingCharacters(in: .whitespaces)
        c.modelX = mx.isEmpty ? "gpt-5.6-sol" : mx
    }

    func selectTab(_ i: Int) {
        guard i >= 0, i < chats.count else { return }
        cur = i
        for (n, c) in chats.enumerated() { c.row.isHidden = n != i }
        tabs.selectedSegment = i
        let c = chats[i]
        popC.selectItem(withTitle: c.modelC)
        if popC.selectedItem == nil { popC.selectItem(at: 0) }
        comboX.stringValue = c.modelX
        metaC.stringValue = c.metaCText
        metaX.stringValue = c.metaXText
        verdict.stringValue = c.verdictText
        verdict.textColor = c.verdictColor
        btn.isEnabled = c.pending == 0
        status.stringValue = c.pending > 0 ? "думают…" : "готов"
        status.textColor = c.pending > 0 ? CLA : MUT
        window.makeFirstResponder(entry)
        DispatchQueue.main.async { self.applyTilts() }
    }

    @objc func tabPicked() {
        syncControlsIntoChat()
        selectTab(tabs.selectedSegment)
        saveChats()
    }

    @objc func newChat() {
        syncControlsIntoChat()
        let c = Chat()
        addChat(c, title: "чат \(chats.count + 1)")
        selectTab(chats.count - 1)
        saveChats()
    }

    // ── персист: истории чатов не удаляются, живут в ~/.terseylite ───────
    func saveChats() {
        syncControlsIntoChat()
        let arr: [[String: Any]] = chats.map { c in
            ["title": c.title, "sessC": c.sessC ?? "", "sessX": c.sessX ?? "",
             "modelC": c.modelC, "modelX": c.modelX,
             "textC": c.tvC.string, "textX": c.tvX.string,
             "metaC": c.metaCText, "metaX": c.metaXText]
        }
        let obj: [String: Any] = ["cur": cur, "chats": arr]
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? d.write(to: stateFile)
        }
    }

    func loadChats() -> Bool {
        guard let d = try? Data(contentsOf: stateFile),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let arr = obj["chats"] as? [[String: Any]], !arr.isEmpty else { return false }
        for a in arr {
            let c = Chat()
            c.sessC = (a["sessC"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            c.sessX = (a["sessX"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            c.modelC = a["modelC"] as? String ?? "opus"
            c.modelX = a["modelX"] as? String ?? "gpt-5.6-sol"
            c.metaCText = a["metaC"] as? String ?? " "
            c.metaXText = a["metaX"] as? String ?? " "
            addChat(c, title: a["title"] as? String ?? "чат")
            let tC = a["textC"] as? String ?? "", tX = a["textX"] as? String ?? ""
            c.started = !tC.isEmpty || c.sessC != nil
            c.tvC.textStorage?.setAttributedString(
                NSAttributedString(string: tC, attributes: [.font: mono, .foregroundColor: FG]))
            c.tvX.textStorage?.setAttributedString(
                NSAttributedString(string: tX, attributes: [.font: mono, .foregroundColor: FG]))
        }
        cur = obj["cur"] as? Int ?? 0
        return true
    }

    func applicationWillTerminate(_ n: Notification) { saveChats() }

    // ── все пермишены разом: сыплются системные диалоги, жми «Разрешить» ──
    // FDA промпта в macOS нет — панель откроется сама, добавить плюсиком.
    @objc func grantAll() {
        let tv = chat.tvC!
        func log(_ s: String, _ ok: Bool? = nil) {
            DispatchQueue.main.async {
                self.append(tv, s + "\n", ok == nil ? MUT : (ok! ? OKC : ERRC))
            }
        }
        log("── запрашиваю все пермишены ──")

        let axOpt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        log("универсальный доступ: \(AXIsProcessTrustedWithOptions(axOpt) ? "есть" : "запрошен → Настройки")")

        if CGPreflightScreenCaptureAccess() { log("запись экрана: есть", true) }
        else { CGRequestScreenCaptureAccess(); log("запись экрана: запрошена") }

        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
            log("мониторинг ввода: есть", true)
        } else { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent); log("мониторинг ввода: запрошен") }

        AVCaptureDevice.requestAccess(for: .audio) { ok in log("микрофон: \(ok ? "да" : "нет")", ok) }
        AVCaptureDevice.requestAccess(for: .video) { ok in log("камера: \(ok ? "да" : "нет")", ok) }

        SFSpeechRecognizer.requestAuthorization { st in
            log("распознавание речи: \(st == .authorized ? "да" : "нет")", st == .authorized)
        }
        CNContactStore().requestAccess(for: .contacts) { ok, _ in log("контакты: \(ok ? "да" : "нет")", ok) }
        ekStore.requestFullAccessToEvents { ok, _ in log("календарь: \(ok ? "да" : "нет")", ok) }
        ekStore.requestFullAccessToReminders { ok, _ in log("напоминания: \(ok ? "да" : "нет")", ok) }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { st in
            log("фото: \(st == .authorized ? "да" : "статус \(st.rawValue)")", st == .authorized)
        }

        locMgr = CLLocationManager()
        locMgr?.requestAlwaysAuthorization()
        log("геолокация: запрошена")

        btMgr = CBCentralManager()
        log("bluetooth: запрошен")

        netBrowser = NWBrowser(for: .bonjour(type: "_tersey-ctl._tcp", domain: nil), using: .init())
        netBrowser?.start(queue: .main)
        log("локальная сеть: запрошена")

        DispatchQueue.global().async {
            for bid in ["com.apple.finder", "com.apple.systemevents"] {
                let d = NSAppleEventDescriptor(bundleIdentifier: bid)
                let st = AEDeterminePermissionToAutomateTarget(d.aeDesc, typeWildCard, typeWildCard, true)
                log("автоматизация \(bid): \(st == 0 ? "да" : "код \(st)")", st == 0)
            }
        }

        // Полный доступ к диску: системного промпта не существует — открываю панель
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(u)
            }
            log("полный доступ к диску: открыл панель — добавь TERSEY плюсиком")
        }
    }

    @objc func pickDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = workDir
        panel.prompt = "Работать здесь"
        panel.beginSheetModal(for: window) { resp in
            guard resp == .OK, let url = panel.url else { return }
            self.workDir = url
            self.dirBtn.title = "📁 \(url.lastPathComponent)"
            self.dirBtn.toolTip = url.path
        }
    }

    @objc func send() {
        let prompt = entry.stringValue.trimmingCharacters(in: .whitespaces)
        let c = chat
        guard !prompt.isEmpty, c.pending == 0 else { return }
        syncControlsIntoChat()
        if !c.started {
            c.started = true
            c.title = String(prompt.prefix(14))
            rebuildTabs()
        }
        c.pending = 2
        btn.isEnabled = false
        entry.stringValue = ""
        status.stringValue = "думают…"; status.textColor = CLA
        append(c.tvC, "❯ \(prompt)\n", MUT)
        append(c.tvX, "❯ \(prompt)\n", MUT)
        c.metaEndC = ""; c.okC = true; c.gotTextC = false
        c.tokensX = ""; c.gotTextX = false
        c.ansC = ""; c.ansX = ""; c.lastPrompt = prompt
        c.verdictText = "⚖ ждёт ответов…"; c.verdictColor = MUT
        if chats[cur] === c { verdict.stringValue = c.verdictText; verdict.textColor = MUT }

        let work = isWork, eff = effort
        let permC = work ? "bypass" : "plan"
        let resumeC = c.sessC, resumeX = c.sessX
        let modelC = c.modelC, modelX = c.modelX
        let dir = workDir

        // ── CLAUDE: stream-json, текст притекает дельтами ────────────────
        DispatchQueue.global().async {
            var argv = [claudeBin, "-p", prompt, "--output-format", "stream-json",
                        "--include-partial-messages", "--verbose", "--effort", eff,
                        "--model", modelC]
            if let s = resumeC { argv += ["--resume", s] }
            argv += work ? ["--dangerously-skip-permissions"] : ["--permission-mode", "plan"]
            let r = streamCLI(argv, cwd: dir, timeout: 600) { line in
                guard let d = line.data(using: .utf8),
                      let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
                else { return }
                DispatchQueue.main.async { self.claudeEvent(c, j) }
            }
            DispatchQueue.main.async {
                if !c.gotTextC {
                    let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.append(c.tvC, msg.isEmpty ? "(пусто)" : msg, ERRC)
                }
                let meta = c.metaEndC.isEmpty ? "\(permC) · effort \(eff)"
                    : "\(c.metaEndC) · \(permC) · effort \(eff)"
                self.finish(c, claude: true, meta, c.okC && r.ok)
            }
        }

        // ── CODEX: --json, элементы притекают по мере готовности ─────────
        DispatchQueue.global().async {
            var argv = [codexBin, "exec"]
            if let s = resumeX { argv += ["resume", s] }
            // у сабкоманды resume нет флага --sandbox/-m, поэтому всюду через -c;
            // effort не трогаем — из конфига (medium, tier fast)
            argv += ["--skip-git-repo-check", "--json", "-c", "model=\"\(modelX)\""]
            argv += work ? ["--dangerously-bypass-approvals-and-sandbox"]
                : ["-c", "sandbox_mode=\"read-only\""]
            argv.append(prompt)
            let r = streamCLI(argv, cwd: dir, timeout: 600) { line in
                guard let d = line.data(using: .utf8),
                      let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
                else { return }
                DispatchQueue.main.async { self.codexEvent(c, j) }
            }
            DispatchQueue.main.async {
                if !c.gotTextX {
                    let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.append(c.tvX, msg.isEmpty ? "(пусто)" : msg, ERRC)
                }
                var meta = codexBanner(r.err)
                if !c.tokensX.isEmpty { meta += (meta.isEmpty ? "" : " · ") + "\(c.tokensX) ток" }
                self.finish(c, claude: false, meta, r.ok)
            }
        }
    }

    // события claude stream-json (main thread)
    func claudeEvent(_ c: Chat, _ j: [String: Any]) {
        switch j["type"] as? String {
        case "system":
            if (j["subtype"] as? String) == "init", let sid = j["session_id"] as? String { c.sessC = sid }
        case "stream_event":
            guard let ev = j["event"] as? [String: Any] else { return }
            if ev["type"] as? String == "content_block_delta",
               let del = ev["delta"] as? [String: Any],
               del["type"] as? String == "text_delta",
               let t = del["text"] as? String {
                c.gotTextC = true
                c.ansC += t
                append(c.tvC, t, FG)
            } else if ev["type"] as? String == "content_block_start",
                      let cb = ev["content_block"] as? [String: Any],
                      cb["type"] as? String == "tool_use",
                      let name = cb["name"] as? String {
                c.gotTextC = true
                append(c.tvC, "⚙ \(name)\n", MUT)
            }
        case "result":
            if let sid = j["session_id"] as? String { c.sessC = sid }
            c.okC = !(j["is_error"] as? Bool ?? false)
            var bits: [String] = []
            if let mu = j["modelUsage"] as? [String: Any], let m = mu.keys.sorted().first {
                bits.append(m.replacingOccurrences(of: "claude-", with: ""))
            }
            if let u = j["usage"] as? [String: Any] {
                let inp = (u["input_tokens"] as? Int ?? 0) + (u["cache_read_input_tokens"] as? Int ?? 0)
                    + (u["cache_creation_input_tokens"] as? Int ?? 0)
                bits.append("\(inp)→\(u["output_tokens"] as? Int ?? 0) ток")
            }
            c.metaEndC = bits.joined(separator: " · ")
        default: break
        }
    }

    // события codex --json (main thread)
    func codexEvent(_ c: Chat, _ j: [String: Any]) {
        switch j["type"] as? String {
        case "thread.started":
            if let tid = j["thread_id"] as? String { c.sessX = tid }
        case "item.started":
            if let item = j["item"] as? [String: Any],
               item["type"] as? String == "command_execution",
               let cmd = item["command"] as? String {
                c.gotTextX = true
                append(c.tvX, "⚙ $ \(cmd)\n", MUT)
            }
        case "item.completed":
            guard let item = j["item"] as? [String: Any] else { return }
            if item["type"] as? String == "agent_message", let t = item["text"] as? String {
                c.gotTextX = true
                c.ansX += t
                append(c.tvX, t + "\n", FG)
            }
        case "turn.completed":
            if let u = j["usage"] as? [String: Any] {
                let inp = u["input_tokens"] as? Int ?? 0
                c.tokensX = "\(inp)→\(u["output_tokens"] as? Int ?? 0)"
            }
        default: break
        }
    }

    func finish(_ c: Chat, claude: Bool, _ metaText: String, _ ok: Bool) {
        append(claude ? c.tvC : c.tvX, "\n", ok ? FG : ERRC)
        if claude { c.metaCText = metaText.isEmpty ? " " : metaText }
        else { c.metaXText = metaText.isEmpty ? " " : metaText }
        c.pending -= 1
        if chats[cur] === c { // активный чат — обновить статус-бар
            metaC.stringValue = c.metaCText
            metaX.stringValue = c.metaXText
            if c.pending <= 0 {
                btn.isEnabled = true
                status.stringValue = "готов"; status.textColor = OKC
                window.makeFirstResponder(entry)
            }
        }
        if c.pending <= 0 { saveChats(); runJudge(c) }
    }

    // ── ⚖ судья: третий claude (haiku) сравнивает два ответа ──────────────
    func runJudge(_ c: Chat) {
        guard !c.ansC.isEmpty || !c.ansX.isEmpty else { return }
        if chats[cur] === c { verdict.stringValue = "⚖ судья думает…"; verdict.textColor = MUT }
        let dir = workDir
        let jp = """
        Ты беспристрастный судья. Вопрос пользователя:
        \(c.lastPrompt)

        Ответ CLAUDE:
        \(c.ansC.isEmpty ? "(пусто)" : c.ansC)

        Ответ CODEX:
        \(c.ansX.isEmpty ? "(пусто)" : c.ansX)

        Кто ответил лучше? Ответь РОВНО одной строкой в формате:
        CLAUDE — краткая причина
        или CODEX — краткая причина
        или НИЧЬЯ — краткая причина
        Причина по-русски, до 8 слов. Ничего больше не пиши.
        """
        DispatchQueue.global().async {
            let r = runCLI([claudeBin, "-p", jp, "--model", "haiku",
                            "--effort", "low", "--dangerously-skip-permissions"],
                           timeout: 120, cwd: dir)
            let line = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let up = line.uppercased()
            var col = FG
            if up.hasPrefix("CLAUDE") { col = CLA }
            else if up.hasPrefix("CODEX") { col = COD }
            DispatchQueue.main.async {
                c.verdictText = line.isEmpty ? "⚖ судья промолчал" : "⚖ " + line
                c.verdictColor = col
                if self.chats[self.cur] === c {
                    self.verdict.stringValue = c.verdictText
                    self.verdict.textColor = col
                }
            }
        }
    }

    // перспектива через layer.transform: геометрия окна не меняется,
    // GPU композитит бесплатно — вся «3D-сцена» стоит ноль CPU
    func applyTilts() {
        for (v, base) in tiltViews {
            guard let l = v.layer else { continue }
            l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let f = v.frame
            l.position = CGPoint(x: f.midX, y: f.midY)
            guard tiltOn else { l.transform = CATransform3DIdentity; l.shadowOpacity = 0; continue }
            var t = CATransform3DIdentity
            t.m34 = -1.0 / 750 // фокусное расстояние фейковой камеры
            t = CATransform3DRotate(t, base + mouseDX * 0.10, 0, 1, 0)
            t = CATransform3DRotate(t, mouseDY * 0.08, 1, 0, 0)
            l.transform = t
            if base != 0 { // тени глубины — только у наклонённых панелей
                l.shadowColor = NSColor.black.cgColor
                l.shadowOpacity = 0.16
                l.shadowRadius = 12
                l.shadowOffset = CGSize(width: base > 0 ? 5 : -5, height: -6)
            }
        }
    }

    @objc func toggle3d(_ sender: NSButton) {
        tiltOn = sender.state == .on
        applyTilts()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
