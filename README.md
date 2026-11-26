# FlowNote

Minimalist cross-platform notes app with a freeform image canvas, file attachments, rich text formatting, and instant cloud sync across **macOS**, **Android**, **Windows**, and **Web**.

## Features

- **Rich Text + Slash Commands (`/`)** — headings (`H1`, `H2`), checklists, bullet lists, code blocks, quotes, and inline formatting toolbar.
- **Freeform Image Canvas** — paste (`Cmd+V` / `Ctrl+V`) or pick single/multiple images, drag smoothly with magnetic snap guides, resize from edges/corners with locked aspect ratio, and inspect in a fullscreen lightbox.
- **File Attachments** — attach any file up to 50 MB via the paperclip button, `/` slash menu, or `Cmd+V` / `Ctrl+V` clipboard paste; download/save natively on macOS, Android, Windows, and Web.
- **Full History (`Cmd+Z` / `Ctrl+Z` & `Shift+Cmd+Z` / `Ctrl+Y`)** — unified undo/redo across text edits, image placement/resizing/deletion, and file attachments.
- **Instant Cross-Device Sync** — realtime Supabase Postgres + Broadcast sync with offline cache (`SharedPreferences`), Vault ID pairing, and mobile-friendly touch scrolling & viewport clamping.
- **Native Desktop Shells** — lightweight native wrappers for macOS (`WKWebView` with transparent titlebar & `NSOpenPanel`/`NSSavePanel` bridge) and Windows (`WebView2` with DWM theme sync).

## Downloads (`v1.1.0`)

Prebuilt binaries are available in [GitHub Releases](https://github.com/abramovichegor33-web/notes-app/releases/tag/v1.1.0):

| Platform | Package |
| --- | --- |
| **macOS** (Apple Silicon) | `FlowNote-v1.1.0.dmg` |
| **Android** | `FlowNote-v1.1.0.apk` |
| **Windows** (x64 Installer) | `FlowNote-Setup-v1.1.0.exe` |
| **Windows** (x64 Portable) | `FlowNote-Windows-v1.1.0.zip` |
| **Web** | `FlowNote-v1.1.0-web.zip` |

## Development & Verification

```bash
# Static analysis & tests
flutter analyze
flutter test

# Native checks
swiftc -typecheck -target arm64-apple-macos11.0 macos_native/main.swift
(cd windows_native && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go vet ./...)
```

## Building Release Packages

```bash
# Web
flutter build web --release

# macOS DMG
bash make_dmg.sh

# Windows
rm -rf windows_native/web && cp -r build/web windows_native/web
(cd windows_native && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -ldflags="-s -w -H windowsgui" -o FlowNote.exe .)

# Android APK
flutter build apk --release
```
