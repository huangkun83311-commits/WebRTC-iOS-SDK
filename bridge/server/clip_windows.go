//go:build windows

package main

import (
	"log"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unicode/utf16"
	"unsafe"
)

var (
	u32 = syscall.NewLazyDLL("user32.dll")
	k32 = syscall.NewLazyDLL("kernel32.dll")

	pIsClipFmt    = u32.NewProc("IsClipboardFormatAvailable")
	pOpenClip     = u32.NewProc("OpenClipboard")
	pCloseClip    = u32.NewProc("CloseClipboard")
	pGetClipData  = u32.NewProc("GetClipboardData")
	pGlobalLock   = k32.NewProc("GlobalLock")
	pGlobalUnlock = k32.NewProc("GlobalUnlock")

	pGetFgWnd  = u32.NewProc("GetForegroundWindow")
	pGetWndPID = u32.NewProc("GetWindowThreadProcessId")
	pOpenProc  = k32.NewProc("OpenProcess")
	pQueryName = k32.NewProc("QueryFullProcessImageNameW")
	pCloseH    = k32.NewProc("CloseHandle")

	pGetAsyncKeyState = u32.NewProc("GetAsyncKeyState")
)

const (
	cfUnicodeText = 13
	procQueryInfo = 0x1000

	vkV = 0x56
)

func isCtrlVk(vk uint32) bool {
	// 左右 Ctrl 在不同键盘上报的虚拟键码不同，三种都认
	return vk == 0x11 || vk == 0xA2 || vk == 0xA3
}

func readClipText() string {
	if r, _, _ := pIsClipFmt.Call(cfUnicodeText); r == 0 {
		return ""
	}
	opened := false
	for i := 0; i < 6; i++ {
		if r, _, _ := pOpenClip.Call(0); r != 0 {
			opened = true
			break
		}
		time.Sleep(8 * time.Millisecond)
	}
	if !opened {
		return ""
	}
	defer pCloseClip.Call()
	h, _, _ := pGetClipData.Call(cfUnicodeText)
	if h == 0 {
		return ""
	}
	p, _, _ := pGlobalLock.Call(h)
	if p == 0 {
		return ""
	}
	defer pGlobalUnlock.Call(h)
	var out []uint16
	base := uintptr(p)
	for i := 0; i < 30000; i++ {
		ch := *(*uint16)(unsafe.Pointer(base + uintptr(i*2)))
		if ch == 0 {
			break
		}
		out = append(out, ch)
	}
	return string(utf16.Decode(out))
}

func foregroundExe() string {
	hwnd, _, _ := pGetFgWnd.Call()
	if hwnd == 0 {
		return ""
	}
	var pid uint32
	pGetWndPID.Call(hwnd, uintptr(unsafe.Pointer(&pid)))
	if pid == 0 {
		return ""
	}
	h, _, _ := pOpenProc.Call(procQueryInfo, 0, uintptr(pid))
	if h == 0 {
		return ""
	}
	defer pCloseH.Call(h)
	buf := make([]uint16, 512)
	sz := uint32(len(buf))
	if r, _, _ := pQueryName.Call(h, 0, uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&sz))); r == 0 {
		return ""
	}
	if int(sz) > len(buf) {
		sz = uint32(len(buf))
	}
	return strings.ToLower(filepath.Base(string(utf16.Decode(buf[:sz]))))
}

func isBrowserExe(exe string) bool {
	for _, b := range []string{"msedge", "chrome", "firefox", "brave", "opera", "360se", "360chrome", "qqbrowser", "sogouexplorer"} {
		if strings.Contains(exe, b) {
			return true
		}
	}
	return false
}

// startClipHotkey 5ms 轮询键盘状态：Ctrl 与 V 同时按下（上升沿）就取电脑剪贴板下发。
// 真人按 Ctrl+V 会持续 80~200ms，5ms 一次足够命中；不装钩子所以不吞键、不影响别的程序。
func startClipHotkey(onText func(string)) {
	go func() {
		// 这个 goroutine 只是辅助功能：任何 panic 都要吞掉，
		// 绝不允许把整个信令服务端带走（之前 QueryFullProcessImageNameW 写错 DLL 就崩在这）。
		defer func() {
			if e := recover(); e != nil {
				log.Printf("[clip] 监听异常退出（已兜住，服务不受影响）: %v", e)
			}
		}()
		log.Printf("[clip] 全局 Ctrl+V 监听已启动（5ms 轮询，前台为浏览器时下发）")
		var prev bool
		var lastAt time.Time
		for {
			down := (keyDown(0x11) || keyDown(0xA2) || keyDown(0xA3)) && keyDown(vkV)
			if down && !prev && time.Since(lastAt) > 150*time.Millisecond {
				exe := foregroundExe()
				if isBrowserExe(exe) {
					if txt := readClipText(); strings.TrimSpace(txt) != "" {
						lastAt = time.Now()
						log.Printf("[clip] 捕获 Ctrl+V %d 字（前台 %s）", len([]rune(txt)), exe)
						onText(txt)
					}
				}
			}
			prev = down
			time.Sleep(5 * time.Millisecond)
		}
	}()
}

func keyDown(vk uint32) bool {
	r, _, _ := pGetAsyncKeyState.Call(uintptr(vk))
	return uint16(r)&0x8000 != 0
}
