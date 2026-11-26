import Cocoa
import WebKit
import Network

final class StaticFileServer {
    private let listener: NWListener
    private let rootDir: URL
    private(set) var port: UInt16

    init(rootDir: URL) throws {
        self.rootDir = rootDir.standardizedFileURL
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        var boundListener: NWListener?
        var boundPort: UInt16 = 52831
        var lastError: Error?

        for candidate in [UInt16(52831), 52832, 52833, 52834, 52835] {
            do {
                let candidateListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: candidate)!)
                boundListener = candidateListener
                boundPort = candidate
                break
            } catch {
                lastError = error
            }
        }

        if boundListener == nil {
            if let fallback = try? NWListener(using: params, on: .any) {
                boundListener = fallback
                boundPort = 0
            } else {
                throw lastError ?? NSError(domain: "StaticFileServer", code: 1, userInfo: nil)
            }
        }

        let chosenListener = boundListener!
        self.listener = chosenListener
        self.port = boundPort

        let readySem = DispatchSemaphore(value: 0)
        chosenListener.stateUpdateHandler = { state in
            if case .ready = state {
                readySem.signal()
            } else if case .failed(_) = state {
                readySem.signal()
            } else if case .cancelled = state {
                readySem.signal()
            }
        }

        chosenListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        chosenListener.start(queue: .global(qos: .userInteractive))
        _ = readySem.wait(timeout: .now() + 2.0)
        if let actualPort = chosenListener.port?.rawValue, actualPort != 0 {
            self.port = actualPort
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInteractive))
        receiveNext(on: connection)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, _ in
            guard let self = self, let data = data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let lines = request.components(separatedBy: "\r\n")
            guard let firstLine = lines.first else {
                connection.cancel()
                return
            }

            let parts = firstLine.components(separatedBy: " ")
            guard parts.count >= 2, parts[0] == "GET" else {
                connection.cancel()
                return
            }

            var path = parts[1]
            if path == "/" || path.isEmpty {
                path = "/index.html"
            }
            if let queryIndex = path.firstIndex(of: "?") {
                path = String(path[..<queryIndex])
            }

            let relPath = (path.hasPrefix("/") ? String(path.dropFirst()) : path)
                .removingPercentEncoding ?? path
            let filePath = self.rootDir.appendingPathComponent(relPath).standardizedFileURL
            if filePath.path.hasPrefix(self.rootDir.path),
               FileManager.default.fileExists(atPath: filePath.path),
               let fileData = try? Data(contentsOf: filePath) {
                let mime = self.mimeType(for: filePath.pathExtension)
                var headers = "HTTP/1.1 200 OK\r\n"
                headers += "Content-Type: \(mime)\r\n"
                headers += "Content-Length: \(fileData.count)\r\n"
                headers += "Access-Control-Allow-Origin: *\r\n"
                headers += "Cache-Control: no-store, no-cache, must-revalidate, max-age=0\r\n"
                headers += "Pragma: no-cache\r\n"
                headers += "Expires: 0\r\n"
                headers += "Connection: close\r\n\r\n"

                var responseData = headers.data(using: .utf8)!
                responseData.append(fileData)

                connection.send(content: responseData, completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            } else {
                let notFound = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: notFound.data(using: .utf8)!, completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            }
        }
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "wasm": return "application/wasm"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    func stop() {
        listener.cancel()
    }
}

class CustomWebView: WKWebView {
    override func menu(for event: NSEvent) -> NSMenu? {
        return nil
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let distFromTop = isFlipped ? pt.y : (bounds.height - pt.y)
        // Верхняя пустая полоса сайдбара (справа от кнопок светофора): перетаскивание окна и двойной клик для зума
        if distFromTop >= 0 && distFromTop <= 38 && pt.x >= 72 && pt.x <= 270 {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v",
           let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.pasteAction(nil)
            return
        }
        super.keyDown(with: event)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKUIDelegate {
    var window: NSWindow!
    var webView: CustomWebView!
    var server: StaticFileServer?

    private func applyWindowTheme(isDark: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let window = self.window else { return }
            let bgColor = isDark
                ? NSColor(srgbRed: 13/255.0, green: 14/255.0, blue: 16/255.0, alpha: 1.0)
                : NSColor(srgbRed: 240/255.0, green: 241/255.0, blue: 244/255.0, alpha: 1.0)
            window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            window.backgroundColor = bgColor
            if #available(macOS 12.0, *), let webView = self.webView {
                webView.underPageBackgroundColor = bgColor
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "copyImageToClipboard", let base64String = message.body as? String {
            let cleanBase64 = base64String.contains(",") ? String(base64String.split(separator: ",")[1]) : base64String
            if let data = Data(base64Encoded: cleanBase64), let image = NSImage(data: data) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([image])
            }
        } else if message.name == "setThemeAppearance", let mode = message.body as? String {
            applyWindowTheme(isDark: mode == "dark")
        } else if message.name == "pickFile" {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let window = self.window else { return }
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = true
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK else { return }
                    for url in panel.urls {
                        self.dispatchFileAttachment(from: url)
                    }
                }
            }
        } else if message.name == "pickImage" {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let window = self.window else { return }
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.allowedFileTypes = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"]
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let url = panel.urls.first else { return }
                    if let image = NSImage(contentsOf: url) {
                        self.dispatchImagePaste(image)
                    }
                }
            }
        } else if message.name == "saveFile", let dict = message.body as? [String: Any] {
            let fileName = (dict["fileName"] as? String) ?? "attachment"
            let urlString = dict["url"] as? String
            let base64String = dict["base64"] as? String

            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window else { return }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = fileName
                panel.canCreateDirectories = true
                if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                    panel.directoryURL = downloads
                }
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let destUrl = panel.url else { return }
                    if let b64 = base64String, !b64.isEmpty {
                        let clean = b64.contains(",") ? String(b64.split(separator: ",")[1]) : b64
                        if let data = Data(base64Encoded: clean) {
                            try? data.write(to: destUrl, options: .atomic)
                            return
                        }
                    }
                    if let uStr = urlString, let remoteUrl = URL(string: uStr) {
                        URLSession.shared.dataTask(with: remoteUrl) { data, _, _ in
                            if let data = data {
                                try? data.write(to: destUrl, options: .atomic)
                            }
                        }.resume()
                    }
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        let resources = Bundle.main.resourceURL!
        let webDir = resources.appendingPathComponent("web")

        do {
            server = try StaticFileServer(rootDir: webDir)
        } catch {
            print("Failed to start server: \(error)")
        }

        let port = server?.port ?? 52831
        let windowRect = NSRect(x: 100, y: 100, width: 1120, height: 760)
        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Заметки"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 600, height: 450)
        window.center()

        let systemDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        applyWindowTheme(isDark: systemDark)

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let contentController = WKUserContentController()
        contentController.add(self, name: "copyImageToClipboard")
        contentController.add(self, name: "setThemeAppearance")
        contentController.add(self, name: "saveFile")
        contentController.add(self, name: "pickFile")
        contentController.add(self, name: "pickImage")
        let titlebarScript = WKUserScript(
            source: "window.__NOTES_MACOS_TITLEBAR__ = true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(titlebarScript)
        config.userContentController = contentController

        webView = CustomWebView(frame: window.contentView!.bounds, configuration: config)
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = systemDark
                ? NSColor(srgbRed: 13/255.0, green: 14/255.0, blue: 16/255.0, alpha: 1.0)
                : NSColor(srgbRed: 240/255.0, green: 241/255.0, blue: 244/255.0, alpha: 1.0)
        }
        window.contentView?.addSubview(webView)

        if let url = URL(string: "http://127.0.0.1:\(port)/index.html") {
            WKWebsiteDataStore.default().removeData(
                ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
                modifiedSince: Date.distantPast
            ) { [weak self] in
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                self?.webView.load(request)
            }
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private var lastPasteTime: TimeInterval = 0
    private var lastNewNoteTime: TimeInterval = 0

    private func dispatchFileAttachment(from url: URL) {
        guard url.isFileURL else { return }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            return
        }
        let maxBytes = 50 * 1024 * 1024
        if let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, fileSize > maxBytes {
            if let payloadData = try? JSONSerialization.data(withJSONObject: [
                "error": "too_large",
                "name": url.lastPathComponent
            ]), let jsonStr = String(data: payloadData, encoding: .utf8),
               let encodedLiteral = try? JSONSerialization.data(withJSONObject: [jsonStr]),
               let argArray = String(data: encodedLiteral, encoding: .utf8) {
                let js = "window.dispatchEvent(new CustomEvent('flutter_file_paste', { detail: \(argArray)[0] }));"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
            return
        }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        if data.count > maxBytes { return }

        let payload: [String: Any] = [
            "name": url.lastPathComponent,
            "base64": data.base64EncodedString()
        ]
        if let payloadData = try? JSONSerialization.data(withJSONObject: payload),
           let jsonStr = String(data: payloadData, encoding: .utf8),
           let literalData = try? JSONSerialization.data(withJSONObject: [jsonStr]),
           let argArray = String(data: literalData, encoding: .utf8) {
            let js = "window.dispatchEvent(new CustomEvent('flutter_file_paste', { detail: \(argArray)[0] }));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func dispatchImagePaste(_ image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return }
        var rep = bitmap
        let maxWidth: CGFloat = 2560
        let maxHeight: CGFloat = 2560
        let width = CGFloat(bitmap.pixelsWide)
        let height = CGFloat(bitmap.pixelsHigh)

        if width > maxWidth || height > maxHeight {
            let aspectRatio = width / height
            var targetWidth = maxWidth
            var targetHeight = maxWidth / aspectRatio
            if targetHeight > maxHeight {
                targetHeight = maxHeight
                targetWidth = maxHeight * aspectRatio
            }
            let newSize = NSSize(width: targetWidth, height: targetHeight)
            let resizedImg = NSImage(size: newSize)
            resizedImg.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: newSize),
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .copy,
                       fraction: 1.0)
            resizedImg.unlockFocus()
            if let resTiff = resizedImg.tiffRepresentation,
               let newRep = NSBitmapImageRep(data: resTiff) {
                rep = newRep
            }
        }

        // Сохраняем PNG без потерь для скриншотов до 3 МБ; для больших фото используем JPEG 0.92
        if let pngData = rep.representation(using: .png, properties: [:]),
           pngData.count <= 3 * 1024 * 1024 {
            let base64 = pngData.base64EncodedString()
            let dataUrl = "data:image/png;base64,\(base64)"
            let js = "window.dispatchEvent(new CustomEvent('flutter_image_paste', { detail: '\(dataUrl)' }));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        } else if let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) {
            let base64 = jpegData.base64EncodedString()
            let dataUrl = "data:image/jpeg;base64,\(base64)"
            let js = "window.dispatchEvent(new CustomEvent('flutter_image_paste', { detail: '\(dataUrl)' }));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    @objc func pasteAction(_ sender: Any?) {
        let now = Date().timeIntervalSince1970
        if now - lastPasteTime < 0.5 {
            return
        }
        lastPasteTime = now

        let pb = NSPasteboard.general
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"]

        // Сначала проверяем скопированные файлы из Finder (до NSImage, чтобы вместо документа не вставилась его иконка)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            var handled = false
            for url in urls {
                let ext = url.pathExtension.lowercased()
                if imageExts.contains(ext), let image = NSImage(contentsOf: url) {
                    dispatchImagePaste(image)
                    handled = true
                } else {
                    dispatchFileAttachment(from: url)
                    handled = true
                }
            }
            if handled { return }
        }

        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil), let image = images.first as? NSImage {
            dispatchImagePaste(image)
            return
        }

        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
    }

    @objc func newNoteAction(_ sender: Any?) {
        let now = Date().timeIntervalSince1970
        if now - lastNewNoteTime < 0.5 {
            return
        }
        lastNewNoteTime = now
        let js = "window.dispatchEvent(new CustomEvent('flutter_new_note'));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    @objc func undoAction(_ sender: Any?) {
        let js = "window.dispatchEvent(new CustomEvent('flutter_undo'));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    @objc func redoAction(_ sender: Any?) {
        let js = "window.dispatchEvent(new CustomEvent('flutter_redo'));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Меню приложения
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "О программе Заметки", action: nil, keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Скрыть Заметки", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Скрыть остальные", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Завершить Заметки", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Меню Файл
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "Файл")
        fileMenuItem.submenu = fileMenu
        let newNoteItem = fileMenu.addItem(withTitle: "Новая заметка", action: #selector(newNoteAction(_:)), keyEquivalent: "n")
        newNoteItem.target = self
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        // Меню Правка
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Правка")
        editMenuItem.submenu = editMenu
        let undoItem = editMenu.addItem(withTitle: "Отменить", action: #selector(undoAction(_:)), keyEquivalent: "z")
        undoItem.target = self
        let redoItem = editMenu.addItem(withTitle: "Повторить", action: #selector(redoAction(_:)), keyEquivalent: "Z")
        redoItem.target = self
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        
        let pasteItem = editMenu.addItem(withTitle: "Вставить", action: #selector(pasteAction(_:)), keyEquivalent: "v")
        pasteItem.target = self

        editMenu.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
