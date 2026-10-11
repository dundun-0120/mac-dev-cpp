import AppKit
import Darwin

// MARK: - Paths & constants

enum Paths {
    static let appName = "Mac DevC++"
    static let bundleName = "CppDev"

    /// Where the user's .cpp files live. Falls back outside Documents if that folder is not reachable.
    static var documents: URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let preferred = home.appendingPathComponent("Documents/C++程序")
        if (try? fm.createDirectory(at: preferred, withIntermediateDirectories: true)) != nil,
           fm.isWritableFile(atPath: preferred.path) {
            return preferred
        }
        let fallback = home.appendingPathComponent("Library/Application Support/C++程序")
        try? fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// Private build directory, so compiling never touches a TCC-protected folder.
    static var build: URL {
        let url = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(bundleName)/build")
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var fm: FileManager { FileManager.default }
}

let compilerPath = "/usr/bin/clang++"

/// Ships a bits/stdc++.h shim so code written for Dev-C++ / GCC compiles unchanged.
func compilerFlags() -> [String] {
    var flags = ["-std=c++17", "-Wall", "-Wextra", "-g"]
    if let resources = Bundle.main.resourcePath {
        let shim = resources + "/include"
        if FileManager.default.fileExists(atPath: shim + "/bits/stdc++.h") {
            flags += ["-isystem", shim]
        }
    }
    return flags
}

// MARK: - UTF-8 stream accumulator (a chunk may split a multi-byte character)

final class UTF8Accumulator {
    private var pending = Data()

    func reset() { pending.removeAll() }

    func consume(_ incoming: Data) -> String {
        pending.append(incoming)
        if let s = String(data: pending, encoding: .utf8) {
            pending.removeAll()
            return s
        }
        for drop in 1...4 {
            let end = pending.count - drop
            if end <= 0 { break }
            if let s = String(data: pending[0..<end], encoding: .utf8) {
                pending = Data(pending[end..<pending.count])
                return s
            }
        }
        let s = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return s
    }
}

// MARK: - Program runner over a real pseudo-terminal (console-like stdio behaviour)

final class Runner {
    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private let utf8 = UTF8Accumulator()

    var isRunning: Bool { childPID > 0 }
    var onOutput: ((String) -> Void)?
    var onFinished: ((Int32) -> Void)?

    func start(command: [String], cwd: String?) {
        guard !isRunning else { return }
        utf8.reset()

        var amaster: Int32 = -1
        var ws = winsize()
        ws.ws_row = 30
        ws.ws_col = 120

        let pid = forkpty(&amaster, nil, nil, &ws)
        if pid < 0 {
            onOutput?("无法启动子进程（forkpty 失败）\n")
            onFinished?(-1)
            return
        }

        if pid == 0 {
            if let cwd = cwd { _ = chdir(cwd) }
            var ptrs: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) }
            ptrs.append(nil)
            ptrs.withUnsafeMutableBufferPointer { buf in
                _ = execvp(command[0], buf.baseAddress)
            }
            _exit(127)
        }

        childPID = pid
        masterFD = amaster

        // The app echoes typed input itself, so the terminal must not echo it a second time.
        var t = termios()
        if tcgetattr(amaster, &t) == 0 {
            t.c_lflag = t.c_lflag & ~type(of: t.c_lflag).init(ECHO)
            _ = tcsetattr(amaster, TCSANOW, &t)
        }

        let fd = amaster
        let kid = pid
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            var buffer = Data(count: 8192)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, 8192) }
                if n > 0 {
                    let chunk = Data(buffer[0..<n])
                    let text = self?.utf8.consume(chunk) ?? ""
                    if !text.isEmpty {
                        DispatchQueue.main.async { self?.onOutput?(text) }
                    }
                } else if n < 0 {
                    if errno == EINTR { continue }
                    break // EIO once the child is gone
                } else {
                    break
                }
            }
            var status: Int32 = 0
            _ = waitpid(kid, &status, 0)
            // WIFEXITED/WEXITSTATUS/WTERMSIG are C macros, not imported into Swift.
            let code: Int32 = (status & 0x7f) == 0
                ? Int32((status >> 8) & 0xff)
                : -Int32(status & 0x7f)
            close(fd)
            DispatchQueue.main.async {
                self?.childPID = 0
                self?.masterFD = -1
                self?.onFinished?(code)
            }
        }
    }

    func sendLine(_ text: String) {
        guard isRunning, masterFD >= 0 else { return }
        let payload = Array((text + "\n").utf8)
        _ = payload.withUnsafeBytes { write(masterFD, $0.baseAddress, payload.count) }
    }

    func stop() {
        guard childPID > 0 else { return }
        kill(childPID, SIGKILL)
    }
}

// MARK: - Compiler

struct CompileResult {
    let ok: Bool
    let log: String
}

enum Compiler {
    static func compile(source: URL, output: URL) -> CompileResult {
        var args = compilerFlags()
        args.append("-o")
        args.append(output.path)
        args.append(source.path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: compilerPath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.standardInput = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return CompileResult(ok: false, log: "无法启动编译器：\(error.localizedDescription)\n")
        }

        var log = ""
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.readData(ofLength: 4096)
            if chunk.isEmpty { break }
            log += String(decoding: chunk, as: UTF8.self)
        }
        task.waitUntilExit()

        if log.isEmpty {
            log = task.terminationStatus == 0 ? "编译成功\n" : "编译失败（退出码 \(task.terminationStatus)）\n"
        }
        return CompileResult(ok: task.terminationStatus == 0, log: log)
    }
}

// MARK: - Source file IO (Windows/Dev-C++ files are often GBK, not UTF-8)

enum SourceFile {
    static func read(_ url: URL) -> String? {
        guard var data = try? Data(contentsOf: url) else { return nil }
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            data = data.subdata(in: 3..<data.count)
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gbk) { return s }
        return String(data: data, encoding: .isoLatin1)
    }

    static func write(_ text: String, to url: URL) -> Bool {
        (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
    }
}

// MARK: - Editor with auto-indent, bracket pairing, block indent

final class EditorTextView: NSTextView {
    private let openToClose: [Character: Character] = ["(": ")", "{": "}", "[": "]", "\"": "\"", "'": "'"]
    private let closers: Set<Character> = [")", "}", "]", "\"", "'"]
    private let indentUnit = "    "

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let str = insertString as? String, str.count == 1, let ch = str.first else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let sel = selectedRange()
        let ns = string as NSString

        if closers.contains(ch) {
            if sel.length == 0, sel.location < ns.length,
               ns.substring(with: NSRange(location: sel.location, length: 1)) == str {
                setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                return
            }
        }

        if let closing = openToClose[ch] {
            if sel.length > 0 {
                let selected = ns.substring(with: sel)
                let wrapped = str + selected + String(closing)
                replaceCharacters(in: sel, with: wrapped)
                setSelectedRange(NSRange(location: sel.location + 1, length: (selected as NSString).length))
                return
            }
            replaceCharacters(in: sel, with: str + String(closing))
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            return
        }

        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let line = ns.substring(with: lineRange)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        var indent = ""
        for ch in line {
            if ch == " " || ch == "\t" { indent.append(ch) } else { break }
        }
        if trimmed.hasSuffix("{") || trimmed.hasSuffix(":") { indent += indentUnit }

        let closingNext = sel.location < ns.length &&
            ns.substring(with: NSRange(location: sel.location, length: 1)) == "}"

        if closingNext {
            replaceCharacters(in: sel, with: "\n" + indent + indentUnit + "\n" + indent)
            setSelectedRange(NSRange(location: sel.location + 1 + indent.count + indentUnit.count + 1, length: 0))
        } else {
            replaceCharacters(in: sel, with: "\n" + indent)
            setSelectedRange(NSRange(location: sel.location + 1 + indent.count, length: 0))
        }
    }

    override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        let ns = string as NSString
        let blockRange = ns.lineRange(for: sel)
        let block = ns.substring(with: blockRange)
        if sel.length > 0 && block.contains("\n") {
            let parts = block.components(separatedBy: "\n")
            let updated = parts.map { $0.isEmpty ? $0 : indentUnit + $0 }.joined(separator: "\n")
            replaceCharacters(in: blockRange, with: updated)
            setSelectedRange(NSRange(location: blockRange.location, length: (updated as NSString).length))
            return
        }
        replaceCharacters(in: sel, with: indentUnit)
        setSelectedRange(NSRange(location: sel.location + indentUnit.count, length: 0))
    }

    override func insertBacktab(_ sender: Any?) {
        let sel = selectedRange()
        let ns = string as NSString
        let blockRange = ns.lineRange(for: sel)
        let block = ns.substring(with: blockRange)
        let parts = block.components(separatedBy: "\n")
        let updated = parts.map { part -> String in
            if part.hasPrefix(indentUnit) { return String(part.dropFirst(indentUnit.count)) }
            return part
        }.joined(separator: "\n")
        if updated != block {
            replaceCharacters(in: blockRange, with: updated)
            let removed = (block as NSString).length - (updated as NSString).length
            setSelectedRange(NSRange(location: max(blockRange.location, sel.location - removed), length: 0))
        }
    }
}

// MARK: - Examples

struct Example {
    let title: String
    let file: String
    let code: String
}

let examples: [Example] = [
    Example(title: "1. Hello World", file: "hello.cpp", code: """
    #include <iostream>
    using namespace std;

    int main() {
        cout << "Hello, World!" << endl;
        cout << "这是我的第一个 Mac 程序" << endl;
        return 0;
    }
    """),
    Example(title: "2. 输入与计算", file: "input.cpp", code: """
    #include <iostream>
    using namespace std;

    int main() {
        int a, b;
        cout << "请输入两个整数：" << flush;
        cin >> a >> b;
        cout << a << " + " << b << " = " << a + b << endl;
        cout << a << " x " << b << " = " << a * b << endl;
        return 0;
    }
    """),
    Example(title: "3. 循环求和", file: "loop.cpp", code: """
    #include <iostream>
    using namespace std;

    int main() {
        int n;
        cout << "请输入 n：" << flush;
        cin >> n;

        long long sum = 0;
        for (int i = 1; i <= n; i++) {
            sum += i;
        }
        cout << "1 到 " << n << " 的和 = " << sum << endl;
        return 0;
    }
    """),
    Example(title: "4. 冒泡排序", file: "sort.cpp", code: """
    #include <iostream>
    using namespace std;

    int main() {
        int a[] = {5, 3, 9, 1, 7, 2};
        int n = sizeof(a) / sizeof(a[0]);

        for (int i = 0; i < n - 1; i++) {
            for (int j = 0; j < n - 1 - i; j++) {
                if (a[j] > a[j + 1]) {
                    swap(a[j], a[j + 1]);
                }
            }
        }

        cout << "排序结果：";
        for (int i = 0; i < n; i++) cout << a[i] << " ";
        cout << endl;
        return 0;
    }
    """),
    Example(title: "5. 猜数字游戏", file: "guess.cpp", code: """
    #include <iostream>
    #include <cstdlib>
    #include <ctime>
    using namespace std;

    int main() {
        srand((unsigned)time(0));
        int answer = rand() % 100 + 1;
        int tryCount = 0, guess;

        cout << "我想了一个 1~100 的数，来猜猜看！" << endl;
        while (true) {
            cout << "第 " << ++tryCount << " 次猜：" << flush;
            if (!(cin >> guess)) { cout << "输入无效，游戏结束。" << endl; break; }
            if (guess == answer) { cout << "猜对了，用了 " << tryCount << " 次。" << endl; break; }
            cout << (guess < answer ? "小了\\n" : "大了\\n");
        }
        return 0;
    }
    """),
    Example(title: "6. 结构体与排序", file: "student.cpp", code: """
    #include <iostream>
    #include <string>
    #include <vector>
    #include <algorithm>
    using namespace std;

    struct Student {
        string name;
        int score;
    };

    int main() {
        vector<Student> list = {{"小明", 88}, {"小红", 95}, {"小刚", 72}};

        sort(list.begin(), list.end(), [](const Student &a, const Student &b) {
            return a.score > b.score;
        });

        for (size_t i = 0; i < list.size(); i++) {
            cout << i + 1 << ". " << list[i].name << " " << list[i].score << endl;
        }
        return 0;
    }
    """),
    Example(title: "7. 竞赛风格（数组求和）", file: "sum_array.cpp", code: """
    #include <bits/stdc++.h>   // Dev-C++ 常用写法，本 App 已支持
    using namespace std;

    int main() {
        int n;
        cin >> n;

        vector<int> a(n);
        long long total = 0;
        for (int i = 0; i < n; i++) {
            cin >> a[i];
            total += a[i];
        }
        cout << total << endl;
        return 0;
    }
    """),
]

let starterCode = """
#include <iostream>
using namespace std;

int main() {
    cout << "Hello, World!" << endl;
    return 0;
}
"""

// MARK: - Main window controller

final class MainWindowController: NSObject, NSToolbarDelegate, NSSplitViewDelegate,
                                  NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    let window: NSWindow
    let split = NSSplitView()
    let editor = EditorTextView()
    let editorScroll = NSScrollView()
    let console = NSTextView()
    let consoleScroll = NSScrollView()
    let inputField = NSTextField()
    let statusLabel = NSTextField(labelWithString: "")
    let runner = Runner()

    private var currentFile: URL?
    private var savedText: String = ""
    private var fontSize: CGFloat = 15
    private var compiling = false
    private var stopItem: NSToolbarItem?
    private var buildItem: NSToolbarItem?
    private var pendingEditorFocus = false

    private let toolbarIDs: [NSToolbarItem.Identifier] = [
        .init("new"), .init("open"), .init("save"), .space,
        .init("buildRun"), .init("stop"), .space, .init("examples"),
    ]

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = Paths.appName
        window.delegate = self
        window.setFrameAutosaveName("MainWindow")
        window.minSize = NSSize(width: 700, height: 480)

        buildUI()
        configureRunner()
        loadInitialContent()
        setStatus("就绪 · ⌘R 编译并运行 · 文件默认存到 \(Paths.documents.lastPathComponent)")
    }

    // MARK: UI construction

    private func buildUI() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1040, height: 720))
        window.contentView = content

        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        editor.backgroundColor = NSColor.white
        editor.textColor = NSColor.black
        editor.insertionPointColor = NSColor.black
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.isIncrementalSearchingEnabled = false
        editor.textContainerInset = NSSize(width: 6, height: 8)
        editor.delegate = self
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.textContainer?.widthTracksTextView = true
        editor.usesFindBar = true

        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.hasHorizontalScroller = false
        editorScroll.autohidesScrollers = true
        editorScroll.borderType = .noBorder
        editorScroll.drawsBackground = true

        console.isEditable = false
        console.isSelectable = true
        console.isRichText = false
        console.drawsBackground = true
        console.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        console.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        console.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        console.textContainerInset = NSSize(width: 6, height: 6)
        console.minSize = NSSize(width: 0, height: 0)
        console.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        console.isVerticallyResizable = true
        console.isHorizontallyResizable = false
        console.textContainer?.widthTracksTextView = true

        consoleScroll.documentView = console
        consoleScroll.hasVerticalScroller = true
        consoleScroll.autohidesScrollers = true
        consoleScroll.borderType = .noBorder

        inputField.placeholderString = "程序运行中：在这里输入内容，按回车发送"
        inputField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        inputField.isEnabled = false
        inputField.target = self
        inputField.action = #selector(sendInput)
        inputField.delegate = self
        inputField.translatesAutoresizingMaskIntoConstraints = false

        let badge = NSTextField(labelWithString: "输入 ▸")
        badge.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        badge.textColor = NSColor.secondaryLabelColor
        badge.translatesAutoresizingMaskIntoConstraints = false

        let consolePane = NSView()
        consolePane.translatesAutoresizingMaskIntoConstraints = false
        consoleScroll.translatesAutoresizingMaskIntoConstraints = false
        consolePane.addSubview(consoleScroll)
        consolePane.addSubview(badge)
        consolePane.addSubview(inputField)
        NSLayoutConstraint.activate([
            consoleScroll.topAnchor.constraint(equalTo: consolePane.topAnchor),
            consoleScroll.leadingAnchor.constraint(equalTo: consolePane.leadingAnchor),
            consoleScroll.trailingAnchor.constraint(equalTo: consolePane.trailingAnchor),
            consoleScroll.bottomAnchor.constraint(equalTo: inputField.topAnchor, constant: -2),
            inputField.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 6),
            inputField.trailingAnchor.constraint(equalTo: consolePane.trailingAnchor, constant: -8),
            inputField.topAnchor.constraint(equalTo: consolePane.bottomAnchor, constant: -28),
            inputField.bottomAnchor.constraint(equalTo: consolePane.bottomAnchor, constant: -5),
            badge.leadingAnchor.constraint(equalTo: consolePane.leadingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: inputField.centerYAnchor),
            consolePane.heightAnchor.constraint(greaterThanOrEqualToConstant: 170),
        ])

        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addSubview(editorScroll)
        split.addSubview(consolePane)

        let statusStrip = NSView()
        statusStrip.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusStrip.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusStrip.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: statusStrip.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: statusStrip.centerYAnchor),
        ])

        content.addSubview(split)
        content.addSubview(statusStrip)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusStrip.topAnchor),
            statusStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusStrip.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusStrip.heightAnchor.constraint(equalToConstant: 24),
        ])

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let h = self.split.bounds.height
            if h > 320 { self.split.setPosition(h * 0.62, ofDividerAt: 0) }
        }
    }

    private func configureRunner() {
        runner.onOutput = { [weak self] text in self?.appendConsole(text) }
        runner.onFinished = { [weak self] code in
            guard let self = self else { return }
            self.inputField.isEnabled = false
            self.stopItem?.isEnabled = false
            self.buildItem?.isEnabled = true
            if self.pendingEditorFocus {
                self.pendingEditorFocus = false
                self.window.makeFirstResponder(self.editor)
            }
            if code == 0 {
                self.appendConsole("\n—— 程序结束 ——\n")
                self.setStatus("运行结束")
            } else {
                self.appendConsole("\n—— 程序结束，退出码 \(code) ——\n")
                self.setStatus("程序结束（退出码 \(code)）")
            }
        }
    }

    // MARK: Toolbar delegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarIDs }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarIDs + [.flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func make(_ symbol: String, _ label: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.target = self
            item.action = action
            item.isBordered = true
            return item
        }

        switch id.rawValue {
        case "new": return make("doc.badge.plus", "新建", #selector(newDocument))
        case "open": return make("folder", "打开", #selector(openDocument))
        case "save": return make("square.and.arrow.down", "保存", #selector(saveDocument))
        case "buildRun":
            let item = make("play.fill", "编译并运行", #selector(buildAndRun))
            buildItem = item
            return item
        case "stop":
            let item = make("stop.fill", "停止", #selector(stopRun))
            item.isEnabled = false
            stopItem = item
            return item
        case "examples":
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "示例"
            item.paletteLabel = "示例"
            item.toolTip = "内置示例程序"
            item.image = NSImage(systemSymbolName: "curlybraces", accessibilityDescription: "示例")
            item.showsIndicator = true
            item.isBordered = true
            let menu = NSMenu()
            for ex in examples {
                let mi = NSMenuItem(title: ex.title, action: #selector(loadExample(_:)), keyEquivalent: "")
                mi.target = self
                menu.addItem(mi)
            }
            item.menu = menu
            return item
        default: return nil
        }
    }

    // MARK: Split view constraints

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerIndex == 0 ? 160 : proposedMin
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        dividerIndex == 0 ? splitView.bounds.height - 180 : proposedMax
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    // MARK: Console / status

    private func setStatus(_ s: String) { statusLabel.stringValue = s }

    func appendConsole(_ s: String) {
        console.textStorage?.append(NSAttributedString(
            string: s,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1),
            ]
        ))
        console.scrollRangeToVisible(NSRange(location: (console.string as NSString).length, length: 0))
    }

    func setEditorText(_ text: String) {
        editor.string = text
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        savedText = text
        updateTitle()
        window.makeFirstResponder(editor)
    }

    private var isDirty: Bool { editor.string != savedText }

    private func updateTitle() {
        let mark = isDirty ? "• " : ""
        if let file = currentFile {
            window.title = "\(mark)\(file.lastPathComponent) — \(Paths.appName)"
        } else {
            window.title = "\(mark)未命名 — \(Paths.appName)"
        }
    }

    func textDidChange(_ notification: Notification) { updateTitle() }

    // MARK: File actions

    @objc func newDocument() {
        confirmDiscard { [weak self] ok in
            guard ok, let self = self else { return }
            self.currentFile = nil
            self.setEditorText(starterCode)
            self.setStatus("新建 · 未保存")
        }
    }

    @objc func openDocument() {
        confirmDiscard { [weak self] ok in
            guard ok, let self = self else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = Paths.documents
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                self.open(url: url)
            }
        }
    }

    func open(url: URL) {
        guard let text = SourceFile.read(url) else {
            showMessage("打开失败：无法读取 \(url.lastPathComponent)")
            return
        }
        currentFile = url
        setEditorText(text)
        setStatus("已打开 \(url.path)")
        UserDefaults.standard.set(url.path, forKey: "lastFile")
    }

    /// Always asynchronous: never block the main thread waiting for a panel's completion handler.
    private func save(_ then: @escaping (Bool) -> Void) {
        if let file = currentFile {
            then(write(editor.string, to: file))
            return
        }
        let panel = NSSavePanel()
        panel.directoryURL = Paths.documents
        panel.nameFieldStringValue = "untitled.cpp"
        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { then(false); return }
            then(self.write(self.editor.string, to: url))
        }
    }

    @objc func saveDocument() {
        save { _ in }
    }

    @objc func saveDocumentAs() {
        let previous = currentFile
        currentFile = nil
        save { [weak self] ok in
            if !ok { self?.currentFile = previous }
        }
    }

    private func write(_ text: String, to url: URL) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            currentFile = url
            savedText = text
            updateTitle()
            setStatus("已保存 \(url.lastPathComponent)")
            UserDefaults.standard.set(url.path, forKey: "lastFile")
            return true
        } catch {
            showMessage("保存失败：\(error.localizedDescription)\n可以改用“另存为…”选一个可写的文件夹。")
            return false
        }
    }

    // MARK: Build & run

    @objc func buildAndRun() { build(run: true) }
    @objc func buildOnly() { build(run: false) }

    private func build(run: Bool) {
        guard !compiling else { return }
        if runner.isRunning { runner.stop() }

        buildItem?.isEnabled = false
        setStatus("正在保存并编译…")
        save { [weak self] ok in
            guard let self = self else { return }
            guard ok, let source = self.currentFile else {
                self.buildItem?.isEnabled = true
                self.setStatus("已取消（未保存）")
                return
            }
            self.compiling = true
            let output = Paths.build.appendingPathComponent(source.deletingPathExtension().lastPathComponent)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Compiler.compile(source: source, output: output)
                DispatchQueue.main.async {
                    self.compiling = false
                    if result.ok {
                        self.appendConsole("✔ 编译成功（arm64 原生 · Apple clang · C++17）\n")
                        if run {
                            self.appendConsole("\n▶ 运行：\n")
                            self.setStatus("正在运行…（程序需要输入时，用下方“输入”框）")
                            self.buildItem?.isEnabled = true
                            self.stopItem?.isEnabled = true
                            self.inputField.isEnabled = true
                            self.pendingEditorFocus = true
                            self.window.makeFirstResponder(self.inputField)
                            self.runner.start(command: [output.path],
                                              cwd: output.deletingLastPathComponent().path)
                        } else {
                            self.buildItem?.isEnabled = true
                            self.setStatus("编译成功，已生成可执行文件")
                        }
                    } else {
                        self.appendConsole("✘ 编译失败：\n" + result.log)
                        self.buildItem?.isEnabled = true
                        self.setStatus("编译失败，见输出窗口（格式：文件名:行号:列号: error）")
                    }
                }
            }
        }
    }

    @objc func stopRun() {
        if runner.isRunning {
            runner.stop()
            appendConsole("\n（已停止）\n")
        }
    }

    @objc func sendInput() {
        let text = inputField.stringValue
        guard !text.isEmpty else { return }
        inputField.stringValue = ""
        runner.sendLine(text)
        appendConsole(text + "\n")
    }

    // MARK: Examples, view, help

    @objc func loadExample(_ sender: NSMenuItem) {
        guard let index = examples.firstIndex(where: { $0.title == sender.title }) else { return }
        confirmDiscard { [weak self] ok in
            guard ok, let self = self else { return }
            let ex = examples[index]
            self.currentFile = Paths.documents.appendingPathComponent(ex.file)
            self.setEditorText(ex.code)
            self.setStatus("示例《\(ex.title)》· 按 ⌘S 保存到 \(Paths.documents.lastPathComponent)")
        }
    }

    @objc func clearConsole() { console.string = "" }

    @objc func increaseFont() { setFontSize(min(28, fontSize + 1)) }
    @objc func decreaseFont() { setFontSize(max(10, fontSize - 1)) }

    private func setFontSize(_ size: CGFloat) {
        fontSize = size
        editor.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        setStatus("编辑器字号 \(Int(size))")
    }

    @objc func showHelp(_ sender: Any?) {
        let text = """
        一、写代码
        • 上半部分编辑器：回车自动缩进、括号/引号自动配对、Tab 缩进整块代码、⌘⇧[ 反缩进
        • 新建 ⌘N · 打开 ⌘O · 保存 ⌘S · 另存为 ⌘⇧S

        二、编译运行
        • ⌘R 编译并运行（等同 Dev-C++ 的 F11）
        • ⌘B 只编译 · ⌘. 停止运行
        • 编译错误显示在下方黑色输出窗口：文件名:行号:列号: error
        • 程序用 cin 等输入时，在“输入 ▸”框里打字回车即可（支持多个数、整行文字）

        三、文件位置
        • 源文件默认保存：\(Paths.documents.path)
        • 可执行文件在 App 私有目录，不会把一堆 .o/.exe 留在你桌面上

        四、和 Windows 版 Dev-C++ 的关系
        • .cpp 源码通用：从 Windows 拷过来直接“打开”就能编译运行
        • 代码里的 #include <bits/stdc++.h> 也能直接用（App 自带兼容头文件）
        • 使用系统自带 Apple clang（命令行工具已安装），无需额外配置
        • 原生 arm64（M3）编译运行，不是模拟，速度很快

        五、找不到命令行工具时
        • 终端执行：xcode-select --install
        """
        let alert = NSAlert()
        alert.messageText = "\(Paths.appName) 使用说明"
        alert.informativeText = text
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    // MARK: Misc

    private func loadInitialContent() {
        if let path = UserDefaults.standard.string(forKey: "lastFile") {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path),
               let text = SourceFile.read(url) {
                currentFile = url
                setEditorText(text)
                setStatus("已恢复上次打开的文件 · \(url.path)")
                return
            }
        }
        setEditorText(starterCode)
    }

    /// Unsaved-changes prompt. Completion is false when the user cancels.
    private func confirmDiscard(_ then: @escaping (Bool) -> Void) {
        guard isDirty else { then(true); return }
        let alert = NSAlert()
        alert.messageText = "当前文件有未保存的修改"
        alert.informativeText = "要先保存吗？"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save(then)
        case .alertSecondButtonReturn:
            then(true)
        default:
            then(false)
        }
    }

    private func showMessage(_ m: String) {
        let alert = NSAlert()
        alert.messageText = m
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func windowWillClose(_ notification: Notification) { runner.stop() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }
}

// MARK: - Self test (headless): exercises the exact compile + pty + stdin path

func runSelfTest() -> Int32 {
    let dir = Paths.build
    let src = dir.appendingPathComponent("selftest.cpp")
    let bin = dir.appendingPathComponent("selftest")
    let code = """
    #include <iostream>
    #include <string>
    using namespace std;
    int main() {
        cout << "请输入一个数：" << flush;
        int n;
        if (!(cin >> n)) { cout << "NO INPUT" << endl; return 1; }
        cout << "平方是 " << n * n << endl;
        string s;
        cout << "再输入一句话：" << flush;
        getline(cin >> ws, s);
        cout << "你说的是[" << s << "]" << endl;
        return 0;
    }
    """
    do {
        try code.write(to: src, atomically: true, encoding: .utf8)
    } catch {
        print("selftest: 写源文件失败 \(error)")
        return 2
    }

    let result = Compiler.compile(source: src, output: bin)
    print("compile ok = \(result.ok)")
    if !result.ok {
        print(result.log)
        return 3
    }

    let runner = Runner()
    var collected = ""
    var fedNumber = false
    var fedText = false
    var exitCode: Int32 = -1
    var finished = false

    // Runner delivers its callbacks on the main queue, so the main run loop must keep turning.
    runner.onOutput = { text in
        collected += text
        if !fedNumber, collected.contains("请输入一个数") {
            fedNumber = true
            runner.sendLine("7")
        }
        if fedNumber, !fedText, collected.contains("再输入一句话") {
            fedText = true
            runner.sendLine("你好 Mac 世界")
        }
    }
    runner.onFinished = { code in
        exitCode = code
        finished = true
    }
    runner.start(command: [bin.path], cwd: dir.path)

    let deadline = Date().addingTimeInterval(20)
    while !finished && Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    if !finished {
        print("selftest: 超时")
        runner.stop()
        return 4
    }

    print("--- program output ---")
    print(collected)
    print("--- exit code \(exitCode) ---")

    // Second check: the GCC-only <bits/stdc++.h> header must resolve from the bundled shim.
    let bitsSrc = dir.appendingPathComponent("selftest_bits.cpp")
    let bitsBin = dir.appendingPathComponent("selftest_bits")
    try? """
    #include <bits/stdc++.h>
    using namespace std;
    int main() {
        int n; cin >> n;
        vector<int> a(n);
        long long s = 0;
        for (int &x : a) { cin >> x; s += x; }
        cout << s << endl;
        return 0;
    }
    """.write(to: bitsSrc, atomically: true, encoding: .utf8)
    let bits = Compiler.compile(source: bitsSrc, output: bitsBin)
    print("bits/stdc++.h compile ok = \(bits.ok)")
    if !bits.ok { print(bits.log) }

    let pass = collected.contains("平方是 49")
        && collected.contains("你说的是[你好 Mac 世界]")
        && exitCode == 0
        && bits.ok
    print(pass ? "SELFTEST PASS" : "SELFTEST FAIL")
    return pass ? 0 : 1
}

// MARK: - Menu bar

func installMainMenu(target: MainWindowController) {
    let main = NSMenu()

    func addTop(_ title: String) -> NSMenu {
        let holder = NSMenuItem()
        let submenu = NSMenu(title: title)
        holder.submenu = submenu
        main.addItem(holder)
        return submenu
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String,
             _ modifiers: NSEvent.ModifierFlags = .command, to target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        if let target = target { item.target = target }
        menu.addItem(item)
        return item
    }

    let appMenu = addTop(Paths.appName)
    _ = add(appMenu, "关于 \(Paths.appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "")
    appMenu.addItem(.separator())
    _ = add(appMenu, "服务", nil, "")
    appMenu.addItem(.separator())
    _ = add(appMenu, "隐藏 \(Paths.appName)", #selector(NSApplication.hide(_:)), "h")
    _ = add(appMenu, "退出 \(Paths.appName)", #selector(NSApplication.terminate(_:)), "q")

    let fileMenu = addTop("文件")
    _ = add(fileMenu, "新建", #selector(MainWindowController.newDocument), "n", to: target)
    _ = add(fileMenu, "打开…", #selector(MainWindowController.openDocument), "o", to: target)
    _ = add(fileMenu, "保存", #selector(MainWindowController.saveDocument), "s", to: target)
    _ = add(fileMenu, "另存为…", #selector(MainWindowController.saveDocumentAs), "S", to: target)
    fileMenu.addItem(.separator())
    _ = add(fileMenu, "关闭窗口", #selector(NSWindow.performClose(_:)), "w")

    let editMenu = addTop("编辑")
    _ = add(editMenu, "撤销", Selector(("undo:")), "z")
    _ = add(editMenu, "重做", Selector(("redo:")), "Z")
    editMenu.addItem(.separator())
    _ = add(editMenu, "剪切", #selector(NSText.cut(_:)), "x")
    _ = add(editMenu, "复制", #selector(NSText.copy(_:)), "c")
    _ = add(editMenu, "粘贴", #selector(NSText.paste(_:)), "v")
    _ = add(editMenu, "全选", #selector(NSText.selectAll(_:)), "a")
    editMenu.addItem(.separator())
    let find = add(editMenu, "查找…", #selector(NSTextView.performTextFinderAction(_:)), "f")
    // Standard AppKit performTextFinderAction: tags (1 = find bar, 12 = find & replace bar).
    find.tag = 1
    let replace = add(editMenu, "替换…", #selector(NSTextView.performTextFinderAction(_:)), "F")
    replace.tag = 12

    let runMenu = addTop("运行")
    _ = add(runMenu, "编译并运行", #selector(MainWindowController.buildAndRun), "r", to: target)
    _ = add(runMenu, "仅编译", #selector(MainWindowController.buildOnly), "b", to: target)
    _ = add(runMenu, "停止运行", #selector(MainWindowController.stopRun), ".")
    runMenu.addItem(.separator())
    for ex in examples {
        _ = add(runMenu, ex.title, #selector(MainWindowController.loadExample(_:)), "", to: target)
    }

    let viewMenu = addTop("视图")
    _ = add(viewMenu, "放大字号", #selector(MainWindowController.increaseFont), "+")
    _ = add(viewMenu, "缩小字号", #selector(MainWindowController.decreaseFont), "-")
    viewMenu.addItem(.separator())
    _ = add(viewMenu, "清空输出窗口", #selector(MainWindowController.clearConsole), "k", to: target)

    let helpMenu = addTop("帮助")
    _ = add(helpMenu, "使用说明", #selector(MainWindowController.showHelp(_:)), "?", to: target)
    NSApp.helpMenu = helpMenu

    NSApp.mainMenu = main
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        let c = MainWindowController()
        controller = c
        installMainMenu(target: c)
        c.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Entry point

let arguments = CommandLine.arguments
if arguments.contains("--selftest") {
    exit(runSelfTest())
}
if arguments.contains("--version") {
    print("\(Paths.appName) 1.0 · arm64 native · Apple clang C++17")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
