# 血壓追蹤 Telegram 機器人

單檔 Elixir 腳本，透過 Telegram 內嵌鍵盤記錄血壓，並將資料儲存至 Google Sheets。繁體中文（台灣）介面。

## 特色

- **單一檔案**：`bp_bot.exs`，使用 `Mix.install` 自動安裝相依套件，`elixir bp_bot.exs` 即可執行。
- **Telegram 長輪詢**（long polling）：不需公開網址或 webhook。
- **Google Sheets 後端**：以服務帳號（Service Account）OAuth2 JWT（JOSE 簽署 RS256）驗證，access token 自動快取與更新。
- **互動式選單**：內嵌鍵盤主選單 + 數字鍵盤，依序輸入收縮壓 → 舒張壓 → 脈搏，原地編輯同一則訊息。
- **範圍驗證**：收縮壓 60–260、舒張壓 40–160、脈搏 30–220，附繁體中文錯誤訊息。
- **台灣時區**：紀錄時間以 UTC+8 標記，不依賴時區資料庫。

## 試算表欄位

| 日期時間 | 收縮壓 | 舒張壓 | 脈搏 | Telegram使用者 | 備註 |
| --- | --- | --- | --- | --- | --- |

## 事前準備

1. 向 [@BotFather](https://t.me/BotFather) 申請一個 Telegram bot，取得 token。
2. 前往 Google Cloud Console，建立專案並啟用 **Google Sheets API**。
3. 建立**服務帳號（Service Account）**，產生並下載 JSON 金鑰（內含 `client_email`、`private_key`）。
4. 開啟你的 Google 試算表，點「共用」，把服務帳號的 `client_email`（形如 `xxx@yyy.iam.gserviceaccount.com`）加為**編輯者**。
5. 在試算表第一列填入上表的標題列。若分頁名稱不是 `Sheet1`，請修改 `bp_bot.exs` 中的 `@sheet_name` 常數。

## 環境變數

| 變數 | 說明 |
| --- | --- |
| `TELEGRAM_BOT_TOKEN` | 從 @BotFather 取得的 token |
| `GOOGLE_SHEET_ID` | 試算表網址 `/d/<這段>/edit` 的 spreadsheetId |
| `GOOGLE_SA_KEY_FILE` | 服務帳號 JSON 金鑰檔案的絕對路徑 |

## 執行

需要 [Elixir](https://elixir-lang.org/)（OTP 27+）。

```bash
export TELEGRAM_BOT_TOKEN=...
export GOOGLE_SHEET_ID=...
export GOOGLE_SA_KEY_FILE=/path/to/service_account.json
elixir bp_bot.exs
```

啟動後，在 Telegram 對機器人傳送任意訊息（或 `/start`）即可叫出主選單。
