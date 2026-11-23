import Cocoa
import WebKit
import Network

final class StaticFileServer {
    private let listener: NWListener
    private let rootDir: URL
    let port: UInt16

    init(rootDir: URL) throws {
        self.rootDir = rootDir
        let chosenPort: UInt16 = 52831
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: chosenPort)!)
        self.port = chosenPort

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.start(queue: .global(qos: .userInteractive))
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

            let filePath = self.rootDir.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
            if FileManager.default.fileExists(atPath: filePath.path),
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
}

class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var webView: CustomWebView!
    var server: StaticFileServer?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "copyImageToClipboard", let base64String = message.body as? String {
            let cleanBase64 = base64String.contains(",") ? String(base64String.split(separator: ",")[1]) : base64String
            if let data = Data(base64Encoded: cleanBase64), let image = NSImage(data: data) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([image])
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Заметки"
        window.minSize = NSSize(width: 600, height: 450)
        window.center()

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let contentController = WKUserContentController()
        contentController.add(self, name: "copyImageToClipboard")
        config.userContentController = contentController

        webView = CustomWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private var lastPasteTime: TimeInterval = 0
    private var lastNewNoteTime: TimeInterval = 0

    @objc func pasteAction(_ sender: Any?) {
        let now = Date().timeIntervalSince1970
        if now - lastPasteTime < 0.5 {
            return
        }
        lastPasteTime = now

        let pb = NSPasteboard.general
        var targetImage: NSImage? = nil

        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil), let image = images.first as? NSImage {
            targetImage = image
        } else if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let url = urls.first {
            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"].contains(ext) {
                targetImage = NSImage(contentsOf: url)
            }
        }

        if let image = targetImage {
            if let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff) {
                var rep = bitmap
                let maxWidth: CGFloat = 1600
                let maxHeight: CGFloat = 1600
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

                // Быстрое сжатие до компактного JPEG 0.85 (размер в 20-50 раз меньше сырого PNG!)
                if let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                    let base64 = jpegData.base64EncodedString()
                    let dataUrl = "data:image/jpeg;base64,\(base64)"
                    let js = "window.dispatchEvent(new CustomEvent('flutter_image_paste', { detail: '\(dataUrl)' }));"
                    webView.evaluateJavaScript(js, completionHandler: nil)
                    return
                } else if let pngData = rep.representation(using: .png, properties: [:]) {
                    let base64 = pngData.base64EncodedString()
                    let dataUrl = "data:image/png;base64,\(base64)"
                    let js = "window.dispatchEvent(new CustomEvent('flutter_image_paste', { detail: '\(dataUrl)' }));"
                    webView.evaluateJavaScript(js, completionHandler: nil)
                    return
                }
            }
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
        editMenu.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "Z")
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
