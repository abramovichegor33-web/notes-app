//go:build windows

package main

import (
	_ "embed"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"unsafe"
)

//go:embed FlowNote.exe
var embeddedExe []byte

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	gdi32    = syscall.NewLazyDLL("gdi32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	dwmapi   = syscall.NewLazyDLL("dwmapi.dll")

	pRegisterClassExW     = user32.NewProc("RegisterClassExW")
	pCreateWindowExW      = user32.NewProc("CreateWindowExW")
	pDefWindowProcW       = user32.NewProc("DefWindowProcW")
	pGetMessageW          = user32.NewProc("GetMessageW")
	pTranslateMessage     = user32.NewProc("TranslateMessage")
	pDispatchMessageW     = user32.NewProc("DispatchMessageW")
	pPostQuitMessage      = user32.NewProc("PostQuitMessage")
	pShowWindow           = user32.NewProc("ShowWindow")
	pUpdateWindow         = user32.NewProc("UpdateWindow")
	pBeginPaint           = user32.NewProc("BeginPaint")
	pEndPaint             = user32.NewProc("EndPaint")
	pInvalidateRect       = user32.NewProc("InvalidateRect")
	pGetSystemMetrics     = user32.NewProc("GetSystemMetrics")
	pLoadCursorW          = user32.NewProc("LoadCursorW")
	pSetCursor            = user32.NewProc("SetCursor")
	pDrawTextW            = user32.NewProc("DrawTextW")
	pFillRect             = user32.NewProc("FillRect")
	pMessageBoxW          = user32.NewProc("MessageBoxW")
	pGetModuleHandleW     = kernel32.NewProc("GetModuleHandleW")
	pDwmSetWindowAttr     = dwmapi.NewProc("DwmSetWindowAttribute")
	pCreateSolidBrush     = gdi32.NewProc("CreateSolidBrush")
	pCreatePen            = gdi32.NewProc("CreatePen")
	pCreateFontW          = gdi32.NewProc("CreateFontW")
	pSelectObject         = gdi32.NewProc("SelectObject")
	pDeleteObject         = gdi32.NewProc("DeleteObject")
	pSetBkMode            = gdi32.NewProc("SetBkMode")
	pSetTextColor         = gdi32.NewProc("SetTextColor")
	pRoundRect            = gdi32.NewProc("RoundRect")
	pCreateCompatibleDC   = gdi32.NewProc("CreateCompatibleDC")
	pCreateCompatibleBmp  = gdi32.NewProc("CreateCompatibleBitmap")
	pBitBlt               = gdi32.NewProc("BitBlt")
	pDeleteDC             = gdi32.NewProc("DeleteDC")
)

const (
	winW = 540
	winH = 390

	wsOverlapped  = 0x00000000
	wsCaption     = 0x00C00000
	wsSysMenu     = 0x00080000
	wsMinimizeBox = 0x00020000
	wsVisible     = 0x10000000

	wmDestroy     = 0x0002
	wmPaint       = 0x000F
	wmLButtonDown = 0x0201
	wmMouseMove   = 0x0200
	wmSetCursor   = 0x0020
	wmAppDone     = 0x8001

	swShow          = 5
	dtLeft          = 0x00000000
	dtCenter        = 0x00000001
	dtVCenter       = 0x00000004
	dtSingleLine    = 0x00000020
	dtWordBreak     = 0x00000010
	transparentBk   = 1
	idcArrow        = 32512
	idcHand         = 32649
	createNoWindow  = 0x08000000
	srccopy         = 0x00CC0020
)

type rect struct{ Left, Top, Right, Bottom int32 }
type point struct{ X, Y int32 }

type wndClassExW struct {
	CbSize        uint32
	Style         uint32
	LpfnWndProc   uintptr
	CbClsExtra    int32
	CbWndExtra    int32
	HInstance     uintptr
	HIcon         uintptr
	HCursor       uintptr
	HbrBackground uintptr
	LpszMenuName  *uint16
	LpszClassName *uint16
	HIconSm       uintptr
}

type msg struct {
	Hwnd    uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      point
}

type paintStruct struct {
	Hdc         uintptr
	FErase      int32
	RcPaint     rect
	FRestore    int32
	FIncUpdate  int32
	RgbReserved [32]byte
}

var (
	mainHwnd        uintptr
	createShortcuts = true
	installState    int32 // 0=ready, 1=installing, 2=done, 3=error
	progressPct     int32
	statusMu        sync.Mutex
	statusText      = "Готово к установке FlowNote v1.1.0"
	errorText       = ""
	btnHovered      bool
	chkHovered      bool
	installDir      string
)

var (
	btnRect = rect{Left: 32, Top: 300, Right: winW - 32, Bottom: 348}
	chkRect = rect{Left: 32, Top: 248, Right: winW - 32, Bottom: 278}
)

func utf16Ptr(s string) *uint16 {
	p, _ := syscall.UTF16PtrFromString(s)
	return p
}

func inRect(x, y int32, r rect) bool {
	return x >= r.Left && x <= r.Right && y >= r.Top && y <= r.Bottom
}

func applyDarkTitlebar(hwnd uintptr) {
	var darkFlag int32 = 1
	captionColor := uint32(0x00100E0D) // #0D0E10
	textColor := uint32(0x00EFEDED)    // #EDEDEF
	borderColor := uint32(0x0026201E)  // #1E2026
	_, _, _ = pDwmSetWindowAttr.Call(hwnd, 20, uintptr(unsafe.Pointer(&darkFlag)), unsafe.Sizeof(darkFlag))
	_, _, _ = pDwmSetWindowAttr.Call(hwnd, 19, uintptr(unsafe.Pointer(&darkFlag)), unsafe.Sizeof(darkFlag))
	_, _, _ = pDwmSetWindowAttr.Call(hwnd, 35, uintptr(unsafe.Pointer(&captionColor)), unsafe.Sizeof(captionColor))
	_, _, _ = pDwmSetWindowAttr.Call(hwnd, 36, uintptr(unsafe.Pointer(&textColor)), unsafe.Sizeof(textColor))
	_, _, _ = pDwmSetWindowAttr.Call(hwnd, 34, uintptr(unsafe.Pointer(&borderColor)), unsafe.Sizeof(borderColor))
}

func mkFont(size int32, weight int32) uintptr {
	h, _, _ := pCreateFontW.Call(
		uintptr(uint32(-size)), 0, 0, 0, uintptr(weight),
		0, 0, 0, 1, 0, 0, 5, 0,
		uintptr(unsafe.Pointer(utf16Ptr("Segoe UI"))),
	)
	return h
}

func fillRoundRect(hdc uintptr, r rect, radius int32, fillColor uint32, borderColor uint32) {
	brush, _, _ := pCreateSolidBrush.Call(uintptr(fillColor))
	pen, _, _ := pCreatePen.Call(0, 1, uintptr(borderColor))
	oldB, _, _ := pSelectObject.Call(hdc, brush)
	oldP, _, _ := pSelectObject.Call(hdc, pen)
	_, _, _ = pRoundRect.Call(hdc, uintptr(r.Left), uintptr(r.Top), uintptr(r.Right), uintptr(r.Bottom), uintptr(radius), uintptr(radius))
	_, _, _ = pSelectObject.Call(hdc, oldB)
	_, _, _ = pSelectObject.Call(hdc, oldP)
	_, _, _ = pDeleteObject.Call(brush)
	_, _, _ = pDeleteObject.Call(pen)
}

func drawLabel(hdc uintptr, text string, r rect, font uintptr, color uint32, flags uint32) {
	oldF, _, _ := pSelectObject.Call(hdc, font)
	_, _, _ = pSetTextColor.Call(hdc, uintptr(color))
	ptr := utf16Ptr(text)
	_, _, _ = pDrawTextW.Call(hdc, uintptr(unsafe.Pointer(ptr)), uintptr(^uint32(0)), uintptr(unsafe.Pointer(&r)), uintptr(flags))
	_, _, _ = pSelectObject.Call(hdc, oldF)
}

func paintWindow(hwnd uintptr) {
	var ps paintStruct
	hdc, _, _ := pBeginPaint.Call(hwnd, uintptr(unsafe.Pointer(&ps)))
	if hdc == 0 {
		return
	}
	defer pEndPaint.Call(hwnd, uintptr(unsafe.Pointer(&ps)))

	memDC, _, _ := pCreateCompatibleDC.Call(hdc)
	bmp, _, _ := pCreateCompatibleBmp.Call(hdc, winW, winH)
	oldBmp, _, _ := pSelectObject.Call(memDC, bmp)
	defer func() {
		_, _, _ = pSelectObject.Call(memDC, oldBmp)
		_, _, _ = pDeleteObject.Call(bmp)
		_, _, _ = pDeleteDC.Call(memDC)
	}()

	_, _, _ = pSetBkMode.Call(memDC, transparentBk)

	// Background #0D0E10 -> COLORREF 0x00100E0D
	bgBrush, _, _ := pCreateSolidBrush.Call(0x00100E0D)
	fullR := rect{0, 0, winW, winH}
	_, _, _ = pFillRect.Call(memDC, uintptr(unsafe.Pointer(&fullR)), bgBrush)
	_, _, _ = pDeleteObject.Call(bgBrush)

	// Fonts
	fLogo := mkFont(24, 700)
	fTitle := mkFont(24, 700)
	fSub := mkFont(14, 400)
	fLabel := mkFont(13, 600)
	fPath := mkFont(13, 400)
	fBtn := mkFont(15, 600)
	defer func() {
		for _, f := range []uintptr{fLogo, fTitle, fSub, fLabel, fPath, fBtn} {
			_, _, _ = pDeleteObject.Call(f)
		}
	}()

	// Indigo icon badge (#6366F1 -> COLORREF 0x00F16663)
	badgeR := rect{32, 28, 80, 76}
	fillRoundRect(memDC, badgeR, 14, 0x00F16663, 0x00F16663)
	drawLabel(memDC, "F", badgeR, fLogo, 0x00FFFFFF, dtCenter|dtVCenter|dtSingleLine)

	// Title & Subtitle
	drawLabel(memDC, "FlowNote v1.1.0", rect{96, 26, winW - 32, 54}, fTitle, 0x00F5F5F7, dtLeft|dtSingleLine)
	drawLabel(memDC, "Быстрые заметки с холстом, файлами и облачной синхронизацией", rect{96, 56, winW - 32, 82}, fSub, 0x00A19B94, dtLeft|dtSingleLine)

	// Install path card
	cardR := rect{32, 102, winW - 32, 174}
	fillRoundRect(memDC, cardR, 12, 0x00181514, 0x002C2826)
	drawLabel(memDC, "Папка установки", rect{48, 114, winW - 48, 134}, fLabel, 0x00A19B94, dtLeft|dtSingleLine)
	drawLabel(memDC, installDir, rect{48, 138, winW - 48, 162}, fPath, 0x00EDEDEF, dtLeft|dtSingleLine)

	// Progress track
	trackR := rect{32, 194, winW - 32, 204}
	fillRoundRect(memDC, trackR, 6, 0x0024201E, 0x002C2826)
	pct := atomic.LoadInt32(&progressPct)
	if pct > 0 {
		fillW := int32(float64(winW-64) * float64(pct) / 100.0)
		if fillW < 10 {
			fillW = 10
		}
		fillRoundRect(memDC, rect{32, 194, 32 + fillW, 204}, 6, 0x00F16663, 0x00F16663)
	}

	// Status text
	st := atomic.LoadInt32(&installState)
	statusMu.Lock()
	msgText := statusText
	errMsg := errorText
	statusMu.Unlock()
	msgColor := uint32(0x00A19B94)
	if st == 2 {
		msgColor = 0x0081B910 // emerald
	} else if st == 3 {
		msgText = errMsg
		msgColor = 0x005555EF // red
	}
	drawLabel(memDC, msgText, rect{32, 214, winW - 32, 238}, fPath, msgColor, dtLeft|dtSingleLine)

	// Checkbox
	boxR := rect{32, 253, 50, 271}
	if createShortcuts {
		fillRoundRect(memDC, boxR, 5, 0x00F16663, 0x00F16663)
		drawLabel(memDC, "✓", boxR, fLabel, 0x00FFFFFF, dtCenter|dtVCenter|dtSingleLine)
	} else {
		border := uint32(0x0046423F)
		if chkHovered {
			border = 0x00F16663
		}
		fillRoundRect(memDC, boxR, 5, 0x00181514, border)
	}
	drawLabel(memDC, "Создать ярлык на Рабочем столе и в меню Пуск", rect{60, 250, winW - 32, 274}, fSub, 0x00DFDFDF, dtLeft|dtVCenter|dtSingleLine)

	// Action button
	btnColor := uint32(0x00F16663) // #6366F1
	if btnHovered && st != 1 {
		btnColor = 0x00F67874
	}
	if st == 1 {
		btnColor = 0x004A4440
	}
	btnLabel := "Установить FlowNote"
	if st == 1 {
		btnLabel = "Установка..."
	} else if st == 2 {
		btnLabel = "Запустить FlowNote"
	} else if st == 3 {
		btnLabel = "Повторить установку"
	}
	fillRoundRect(memDC, btnRect, 12, btnColor, btnColor)
	drawLabel(memDC, btnLabel, btnRect, fBtn, 0x00FFFFFF, dtCenter|dtVCenter|dtSingleLine)

	_, _, _ = pBitBlt.Call(hdc, 0, 0, winW, winH, memDC, 0, 0, srccopy)
}

func runHidden(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow}
	return cmd.Run()
}

func createShortcut(lnkPath, targetPath string) {
	ps := fmt.Sprintf(
		`$s=(New-Object -COM WScript.Shell).CreateShortcut('%s');$s.TargetPath='%s';$s.WorkingDirectory='%s';$s.Description='FlowNote';$s.Save()`,
		strings.ReplaceAll(lnkPath, "'", "''"),
		strings.ReplaceAll(targetPath, "'", "''"),
		strings.ReplaceAll(filepath.Dir(targetPath), "'", "''"),
	)
	_ = runHidden("powershell.exe", "-NoProfile", "-WindowStyle", "Hidden", "-Command", ps)
}

func setStatus(s string) {
	statusMu.Lock()
	statusText = s
	statusMu.Unlock()
	_, _, _ = pInvalidateRect.Call(mainHwnd, 0, 0)
}

func setError(s string) {
	statusMu.Lock()
	errorText = s
	statusMu.Unlock()
	atomic.StoreInt32(&installState, 3)
	_, _, _ = pInvalidateRect.Call(mainHwnd, 0, 0)
}

func doInstall() {
	atomic.StoreInt32(&installState, 1)
	atomic.StoreInt32(&progressPct, 15)
	setStatus("Подготовка папки установки...")

	if err := os.MkdirAll(installDir, 0755); err != nil {
		setError("Ошибка создания папки: " + err.Error())
		return
	}

	// Stop running instance if updating
	_ = runHidden("taskkill.exe", "/F", "/IM", "FlowNote.exe")

	atomic.StoreInt32(&progressPct, 45)
	setStatus("Копирование FlowNote.exe...")

	exeTarget := filepath.Join(installDir, "FlowNote.exe")
	if err := os.WriteFile(exeTarget, embeddedExe, 0755); err != nil {
		setError("Не удалось записать FlowNote.exe: " + err.Error())
		return
	}

	// Copy uninstaller
	uninstallTarget := filepath.Join(installDir, "Uninstall.exe")
	if selfPath, err := os.Executable(); err == nil {
		if selfBytes, err := os.ReadFile(selfPath); err == nil {
			_ = os.WriteFile(uninstallTarget, selfBytes, 0755)
		}
	}

	atomic.StoreInt32(&progressPct, 75)
	if createShortcuts {
		setStatus("Создание ярлыков...")
		if appData := os.Getenv("APPDATA"); appData != "" {
			startLnk := filepath.Join(appData, "Microsoft", "Windows", "Start Menu", "Programs", "FlowNote.lnk")
			createShortcut(startLnk, exeTarget)
		}
		if userProfile := os.Getenv("USERPROFILE"); userProfile != "" {
			desktopLnk := filepath.Join(userProfile, "Desktop", "FlowNote.lnk")
			createShortcut(desktopLnk, exeTarget)
		}
	}

	atomic.StoreInt32(&progressPct, 90)
	setStatus("Регистрация в Windows...")

	regKey := `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\FlowNote`
	_ = runHidden("reg.exe", "add", regKey, "/v", "DisplayName", "/t", "REG_SZ", "/d", "FlowNote", "/f")
	_ = runHidden("reg.exe", "add", regKey, "/v", "DisplayVersion", "/t", "REG_SZ", "/d", "1.1.0", "/f")
	_ = runHidden("reg.exe", "add", regKey, "/v", "Publisher", "/t", "REG_SZ", "/d", "FlowNote", "/f")
	_ = runHidden("reg.exe", "add", regKey, "/v", "DisplayIcon", "/t", "REG_SZ", "/d", exeTarget, "/f")
	_ = runHidden("reg.exe", "add", regKey, "/v", "UninstallString", "/t", "REG_SZ", "/d", fmt.Sprintf(`"%s" --uninstall`, uninstallTarget), "/f")

	atomic.StoreInt32(&progressPct, 100)
	setStatus("FlowNote успешно установлен!")
	atomic.StoreInt32(&installState, 2)
	_, _, _ = pInvalidateRect.Call(mainHwnd, 0, 0)
}

func doUninstall() {
	_ = runHidden("taskkill.exe", "/F", "/IM", "FlowNote.exe")
	if appData := os.Getenv("APPDATA"); appData != "" {
		_ = os.Remove(filepath.Join(appData, "Microsoft", "Windows", "Start Menu", "Programs", "FlowNote.lnk"))
	}
	if userProfile := os.Getenv("USERPROFILE"); userProfile != "" {
		_ = os.Remove(filepath.Join(userProfile, "Desktop", "FlowNote.lnk"))
	}
	_ = os.Remove(filepath.Join(installDir, "FlowNote.exe"))
	_ = runHidden("reg.exe", "delete", `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\FlowNote`, "/f")
	_, _, _ = pMessageBoxW.Call(0, uintptr(unsafe.Pointer(utf16Ptr("FlowNote удалён с компьютера."))), uintptr(unsafe.Pointer(utf16Ptr("FlowNote"))), 0x40)
}

func wndProc(hwnd uintptr, message uint32, wParam, lParam uintptr) uintptr {
	switch message {
	case wmMouseMove:
		x := int32(int16(lParam & 0xFFFF))
		y := int32(int16((lParam >> 16) & 0xFFFF))
		nb := inRect(x, y, btnRect)
		nc := inRect(x, y, chkRect) && atomic.LoadInt32(&installState) == 0
		if nb != btnHovered || nc != chkHovered {
			btnHovered = nb
			chkHovered = nc
			_, _, _ = pInvalidateRect.Call(hwnd, 0, 0)
		}
		if nb || nc {
			cur, _, _ := pLoadCursorW.Call(0, idcHand)
			_, _, _ = pSetCursor.Call(cur)
		} else {
			cur, _, _ := pLoadCursorW.Call(0, idcArrow)
			_, _, _ = pSetCursor.Call(cur)
		}
		return 0

	case wmLButtonDown:
		x := int32(int16(lParam & 0xFFFF))
		y := int32(int16((lParam >> 16) & 0xFFFF))
		st := atomic.LoadInt32(&installState)
		if inRect(x, y, chkRect) && st == 0 {
			createShortcuts = !createShortcuts
			_, _, _ = pInvalidateRect.Call(hwnd, 0, 0)
			return 0
		}
		if inRect(x, y, btnRect) {
			if st == 0 || st == 3 {
				go doInstall()
			} else if st == 2 {
				exeTarget := filepath.Join(installDir, "FlowNote.exe")
				_ = exec.Command(exeTarget).Start()
				_, _, _ = pPostQuitMessage.Call(0)
			}
		}
		return 0

	case wmPaint:
		paintWindow(hwnd)
		return 0

	case wmDestroy:
		_, _, _ = pPostQuitMessage.Call(0)
		return 0
	}
	ret, _, _ := pDefWindowProcW.Call(hwnd, uintptr(message), wParam, lParam)
	return ret
}

func main() {
	localAppData := os.Getenv("LOCALAPPDATA")
	if localAppData == "" {
		localAppData = os.TempDir()
	}
	installDir = filepath.Join(localAppData, "Programs", "FlowNote")

	for _, arg := range os.Args[1:] {
		if arg == "--uninstall" {
			doUninstall()
			return
		}
	}

	hInstance, _, _ := pGetModuleHandleW.Call(0)
	className := utf16Ptr("FlowNoteInstallerClass")
	cursor, _, _ := pLoadCursorW.Call(0, idcArrow)

	wc := wndClassExW{
		CbSize:        uint32(unsafe.Sizeof(wndClassExW{})),
		LpfnWndProc:   syscall.NewCallback(wndProc),
		HInstance:     hInstance,
		HCursor:       cursor,
		LpszClassName: className,
	}
	_, _, _ = pRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))

	scrW, _, _ := pGetSystemMetrics.Call(0)
	scrH, _, _ := pGetSystemMetrics.Call(1)
	posX := (int32(scrW) - winW) / 2
	posY := (int32(scrH) - winH) / 2

	hwnd, _, _ := pCreateWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(utf16Ptr("Установка FlowNote"))),
		wsOverlapped|wsCaption|wsSysMenu|wsMinimizeBox|wsVisible,
		uintptr(posX), uintptr(posY), winW, winH,
		0, 0, hInstance, 0,
	)
	mainHwnd = hwnd
	applyDarkTitlebar(hwnd)
	_, _, _ = pShowWindow.Call(hwnd, swShow)
	_, _, _ = pUpdateWindow.Call(hwnd)

	var m msg
	for {
		ret, _, _ := pGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(ret) <= 0 {
			break
		}
		_, _, _ = pTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		_, _, _ = pDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
}
