package main

import (
	"embed"
	"fmt"
	"io/fs"
	"mime"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"github.com/jchv/go-webview2"
)

var (
	dwmapi                = syscall.NewLazyDLL("dwmapi.dll")
	dwmSetWindowAttribute = dwmapi.NewProc("DwmSetWindowAttribute")
)

func applyWindowsTitlebarTheme(hwnd uintptr, isDark bool) {
	if hwnd == 0 {
		return
	}
	var darkFlag int32
	var captionColor uint32
	var textColor uint32
	var borderColor uint32

	if isDark {
		darkFlag = 1
		captionColor = 0x00100E0D // #0D0E10 (COLORREF: 0x00BBGGRR)
		textColor = 0x00EFEDED    // #EDEDEF
		borderColor = 0x0026201E  // #1E2026
	} else {
		darkFlag = 0
		captionColor = 0x00F4F1F0 // #F0F1F4
		textColor = 0x001E1B1A    // #1A1B1E
		borderColor = 0x00E8E3E1  // #E1E3E8
	}

	// DWMWA_USE_IMMERSIVE_DARK_MODE (Windows 11 / 20H1+: 20, older Win10: 19)
	_, _, _ = dwmSetWindowAttribute.Call(hwnd, 20, uintptr(unsafe.Pointer(&darkFlag)), unsafe.Sizeof(darkFlag))
	_, _, _ = dwmSetWindowAttribute.Call(hwnd, 19, uintptr(unsafe.Pointer(&darkFlag)), unsafe.Sizeof(darkFlag))
	// Windows 11 caption/text/border seamless colors
	_, _, _ = dwmSetWindowAttribute.Call(hwnd, 35, uintptr(unsafe.Pointer(&captionColor)), unsafe.Sizeof(captionColor))
	_, _, _ = dwmSetWindowAttribute.Call(hwnd, 36, uintptr(unsafe.Pointer(&textColor)), unsafe.Sizeof(textColor))
	_, _, _ = dwmSetWindowAttribute.Call(hwnd, 34, uintptr(unsafe.Pointer(&borderColor)), unsafe.Sizeof(borderColor))
}

//go:embed web/*
var webFiles embed.FS

func main() {
	// 1. Создаем поддиректорию для встроенных web-файлов
	subFS, err := fs.Sub(webFiles, "web")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating sub FS: %v\n", err)
		return
	}

	// 2. Запускаем локальный веб-сервер: сначала пробуем фиксированный порт 52831 (чтобы сохранялся localStorage / vault_id), иначе свободный порт
	var listener net.Listener
	for _, p := range []int{52831, 52832, 52833, 52834, 52835, 0} {
		listener, err = net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p))
		if err == nil {
			break
		}
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error listening on 127.0.0.1: %v\n", err)
		return
	}
	defer listener.Close()

	port := listener.Addr().(*net.TCPAddr).Port

	// Пользовательский обработчик файлов с точными MIME-типами и отключенным кэшированием
	fileServer := http.FileServer(http.FS(subFS))
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		if path == "/" || path == "" {
			path = "/index.html"
		}

		ext := strings.ToLower(filepath.Ext(path))
		switch ext {
		case ".html", ".htm":
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
		case ".js":
			w.Header().Set("Content-Type", "application/javascript; charset=utf-8")
		case ".css":
			w.Header().Set("Content-Type", "text/css; charset=utf-8")
		case ".json":
			w.Header().Set("Content-Type", "application/json")
		case ".wasm":
			w.Header().Set("Content-Type", "application/wasm")
		case ".png":
			w.Header().Set("Content-Type", "image/png")
		case ".jpg", ".jpeg":
			w.Header().Set("Content-Type", "image/jpeg")
		case ".svg":
			w.Header().Set("Content-Type", "image/svg+xml")
		case ".ico":
			w.Header().Set("Content-Type", "image/x-icon")
		default:
			if m := mime.TypeByExtension(ext); m != "" {
				w.Header().Set("Content-Type", m)
			}
		}

		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
		fileServer.ServeHTTP(w, r)
	})

	server := &http.Server{Handler: handler}
	go func() {
		_ = server.Serve(listener)
	}()

	// 3. Каталог данных пользователя в %LOCALAPPDATA%\Заметки\WebView2Data
	appData := os.Getenv("LOCALAPPDATA")
	if appData == "" {
		appData = os.Getenv("APPDATA")
	}
	if appData == "" {
		appData = os.TempDir()
	}
	dataPath := filepath.Join(appData, "Заметки", "WebView2Data")
	_ = os.MkdirAll(dataPath, 0755)

	// 4. Инициализация окна WebView2
	w := webview2.NewWithOptions(webview2.WebViewOptions{
		Debug:     false,
		DataPath:  dataPath,
		AutoFocus: true,
		WindowOptions: webview2.WindowOptions{
			Title:  "FlowNote",
			Width:  1160,
			Height: 760,
			Center: true,
		},
	})
	if w == nil {
		fmt.Fprintf(os.Stderr, "Failed to initialize WebView2\n")
		return
	}
	defer w.Destroy()

	w.SetSize(1160, 760, webview2.HintNone)
	applyWindowsTitlebarTheme(uintptr(w.Window()), true)
	_ = w.Bind("setNativeTheme", func(isDark bool) {
		w.Dispatch(func() {
			applyWindowsTitlebarTheme(uintptr(w.Window()), isDark)
		})
	})

	// 5. Переход на встроенное веб-приложение
	url := fmt.Sprintf("http://127.0.0.1:%d/index.html", port)
	w.Navigate(url)

	// 6. Запуск цикла обработки событий
	w.Run()
}
