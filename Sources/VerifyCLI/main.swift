import Foundation

// VerifyCLI — 验证器（票 11 拥有本文件，spec §9.1）。
// 用法雏形：swift run VerifyCLI --snapshot <file.json>
// 从已授权终端运行（继承宿主 TCC）。票 11 实现：读快照 + 实时枚举（CGWindowList .optionAll
// + _AXUIElementGetWindow 配对，照 05 spike），输出逐条 PASS/FAIL/SKIP 雏形报告。

print("verify: scaffold — ticket 11 implements this (spec §9.1)")
exit(2)
