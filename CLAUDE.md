# che-word-mcp 開發指引

## 專案結構

```
che-word-mcp/
├── Sources/
│   └── CheWordMCP/
│       └── Server.swift          # MCP Server 主程式（101 tools）
├── mcpb/                         # MCPB 打包目錄
│   ├── manifest.json             # MCPB 設定檔
│   ├── server/
│   │   └── CheWordMCP            # 編譯後的 binary（需手動複製）
│   ├── che-word-mcp.mcpb         # 打包好的 mcpb 檔案
│   ├── PRIVACY.md
│   └── README.md
├── Package.swift                 # Swift 專案設定
├── Package.resolved              # 依賴鎖定
├── CHANGELOG.md                  # 版本歷史
├── README.md                     # 英文文檔
├── README_zh-TW.md               # 繁體中文文檔
└── LICENSE
```

## 重要路徑規則

### Binary 安裝位置
- **本地開發**: `~/bin/CheWordMCP`
- **mcpb 打包**: `mcpb/server/CheWordMCP`

### mcpb 打包檔位置
- **正確**: `mcpb/che-word-mcp.mcpb`
- **錯誤**: 專案根目錄（不要放在這裡！）

### 編譯與部署流程
```bash
# 1. 編譯
swift build -c release

# 2. 複製 binary 到安裝位置
cp .build/release/CheWordMCP ~/bin/
cp .build/release/CheWordMCP mcpb/server/

# 3. 打包 mcpb（在 mcpb/ 目錄內執行）
cd mcpb && zip -r che-word-mcp.mcpb . && mv che-word-mcp.mcpb ../mcpb/
# 或
cd mcpb && zip -r che-word-mcp.mcpb .
```

## 版本更新 Checklist

更新版本時需要修改：
1. `mcpb/manifest.json` - version 欄位
2. `CHANGELOG.md` - 新增版本條目
3. `README.md` - 工具數量等資訊（如有變動）

## GitHub Release

發布新版本時：
```bash
# 建立 tag 並推送
git tag v1.x.0
git push origin v1.x.0

# 建立 release 並上傳 mcpb
gh release create v1.x.0 --title "v1.x.0 - 功能描述" --notes "..."
gh release upload v1.x.0 mcpb/che-word-mcp.mcpb
```

## 相關專案

- **ooxml-swift**: https://github.com/kiki830621/ooxml-swift（核心 OOXML 庫）
- **che-claude-plugins**: 包含此專案的 plugin 定義
