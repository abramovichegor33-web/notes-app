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

	"github.com/jchv/go-webview2"
)

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
			Title:  "Заметки",
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

	// 5. Переход на встроенное веб-приложение
	url := fmt.Sprintf("http://127.0.0.1:%d/index.html", port)
	w.Navigate(url)

	// 6. Запуск цикла обработки событий
	w.Run()
}
