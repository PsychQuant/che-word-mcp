# che-word-mcp 開發指引

## 專案結構

```
che-word-mcp/
├── Sources/
│   └── CheWordMCP/
│       └── Server.swift          # MCP Server 主程式（146 tools）
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
4. **新增／移除某工具的「目前未實作」註記時，同步更新 `README.md` 與
   `README_zh-TW.md` 裡對該工具（或該工具所屬能力分類，如 Watermark CRUD）
   的敘述**——工具數量不變時上面第 3 項不會觸發，但過度宣稱能力（description
   誠實、README 卻仍寫成可用 CRUD）是使用者會直接被誤導的落差（#210）。
5. **`Sources/CheWordMCP/Server.swift` 的 `static let serverVersion`**——
   MCP `initialize` handshake 回報給 client 的版本，單一來源（`Server(...)`
   建構時直接讀這個常數，不要再改回內嵌字面量）。這個常數曾經漏改超過
   兩個大版本（#211）。
6. **`server.json`**——`version`、`packages[0].version`、
   `packages[0].identifier`（下載網址裡的 `vX.Y.Z`）三處都要跟著改；
   `packages[0].fileSha256` 由 `scripts/release.sh` 在發版成功後自動寫回，
   不要事先手填（見下段）。

以上六項中，第 1、5、6 項（manifest.json／serverVersion／server.json 的
version 與 identifier）由 `scripts/release.sh` 的 `[0.3/7]` 步驟在建置前
fail-fast 檢查。`server.json` 的 `fileSha256` 是**簽章後** binary 的 sha256，
而 `codesign --timestamp` 每次簽章都會嵌入新的時間戳，同一份 bytes 簽兩次
sha 就不同，所以發版前不可能知道正確值：`scripts/release.sh` 在 `[post]`
步驟把這次實際的 sha 寫回 `server.json`，發版後要 commit 這個變更（下一次
發版的乾淨工作樹檢查會擋住沒 commit 的情況）。第 5 項另有 `Issue211VersionConsistencyTests`（`swift test`）
鎖住 `serverVersion` 與 `mcpb/manifest.json` 的一致性，每次 `swift test`
都會跑，不必等到真的要發版才發現漏改（#211）。

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

- **ooxml-swift**: https://github.com/PsychQuant/ooxml-swift（核心 OOXML 庫）
- **macdoc**: /Users/che/Developer/macdoc（Word→MD 轉換 CLI，export_markdown 委託目標）
- **che-claude-plugins**: 包含此專案的 plugin 定義
