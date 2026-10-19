# sa_plugin_sax 0.17 测试状态

验证时间: 2026-10-18, zig 0.17.0, sci main (LLVM-14 backend sa), LLVM-20 (plugin shim)
命令: `zig build test --summary all` (PATH=/opt/zig-0.17.0:/usr/local/bin)

## 结果: Build Summary 44/44 steps succeeded — 全绿

- 5 个 sa contract 测试全过
- 全部 demo check/build + wasm verify + node runtime verify 全过
- 前置修复: build.zig 默认 sa-repo-root 改为 sibling ../sci (S1)
