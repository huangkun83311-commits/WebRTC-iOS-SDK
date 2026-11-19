//go:build !windows

package main

import "log"

// 非 Windows 构建（云主机/CI）没有全局快捷键能力，留空实现保证编译通过。
func startClipHotkey(onText func(string)) {
	log.Printf("[clip] 全局 Ctrl+V 监听仅 Windows 可用，本平台跳过")
}
