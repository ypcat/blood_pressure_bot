Mix.install([{:req, "~> 0.5"}, {:jason, "~> 1.4"}])

# =============================================================================
# 血壓追蹤 Telegram 機器人 (Blood Pressure Tracking Telegram Bot)
# =============================================================================
#
# 單檔 Elixir 腳本。每位使用者透過 Telegram 以「Google 帳號授權 (OAuth2)」
# 連結自己的 Google Drive，機器人會在「使用者自己的雲端硬碟」建立一份私人
# 試算表來記錄血壓。繁體中文 (台灣) 內嵌鍵盤介面。
#
# -----------------------------------------------------------------------------
# 為什麼是 OAuth 而非服務帳號 (Service Account)？
# -----------------------------------------------------------------------------
#   服務帳號只能存取「它自己的」雲端硬碟，無法寫入任意使用者的私人 Drive。
#   要讓每位使用者把資料存在「自己的」Drive，必須使用 OAuth 使用者授權流程
#   (每位使用者各自同意，並各自取得 refresh token)。
#
# -----------------------------------------------------------------------------
# 必要的環境變數 (Required environment variables):
# -----------------------------------------------------------------------------
#   TELEGRAM_BOT_TOKEN       - 從 @BotFather 取得的 Telegram bot token
#   GOOGLE_OAUTH_CLIENT_FILE - OAuth 用戶端 JSON 金鑰檔路徑 (含 client_id /
#                              client_secret)。請建立「桌面應用程式 (Desktop
#                              app)」類型的 OAuth 用戶端。
#
# -----------------------------------------------------------------------------
# 設定 Google OAuth (一次性):
# -----------------------------------------------------------------------------
#   1. Google Cloud Console -> 建立專案 -> 啟用「Google Drive API」與
#      「Google Sheets API」。
#   2. 「OAuth 同意畫面」: 使用者類型選「外部」，填寫基本資訊；在「測試使用者」
#      區段加入會使用此機器人的 Google 帳號 (測試模式最多 100 位，免 Google
#      應用程式審查)。範圍 (scope) 使用 drive.file 即可，屬非敏感範圍。
#   3. 「憑證 -> 建立憑證 -> OAuth 用戶端 ID」-> 應用程式類型選「桌面應用程式」。
#      下載 JSON (內含 client_id / client_secret)，設為 GOOGLE_OAUTH_CLIENT_FILE。
#   4. 重要 (loopback 限制): 重新導向採用 http://localhost:#{53682}/ (見下方
#      @redirect_port)。授權者的瀏覽器必須與「機器人執行的主機」為同一台，
#      Google 才會把授權碼送回機器人。適合自用 / 同機使用者。
#
# -----------------------------------------------------------------------------
# 執行方式 (How to run):
# -----------------------------------------------------------------------------
#   export TELEGRAM_BOT_TOKEN=...
#   export GOOGLE_OAUTH_CLIENT_FILE=/path/to/oauth_client.json
#   elixir bp_bot.exs
#
#   使用者資料 (refresh token、試算表 ID) 會存於工作目錄的 users.json，
#   內含機密，請勿提交版控或外流。
# =============================================================================

require Logger

defmodule Bot.Config do
  @moduledoc "讀取環境變數與 OAuth 用戶端設定。"

  # loopback 重新導向所用的固定埠號。
  @redirect_port 53682

  def token, do: System.fetch_env!("TELEGRAM_BOT_TOKEN")

  def redirect_uri, do: "http://localhost:#{@redirect_port}/"

  def redirect_port, do: @redirect_port

  # OAuth 用戶端 JSON 可能是 {"installed": {...}} 或 {"web": {...}}。
  def oauth_client do
    json =
      System.fetch_env!("GOOGLE_OAUTH_CLIENT_FILE")
      |> File.read!()
      |> Jason.decode!()

    c = json["installed"] || json["web"] || json

    %{
      client_id: c["client_id"],
      client_secret: c["client_secret"],
      auth_uri: c["auth_uri"] || "https://accounts.google.com/o/oauth2/v2/auth",
      token_uri: c["token_uri"] || "https://oauth2.googleapis.com/token"
    }
  end

  def api_base, do: "https://api.telegram.org/bot" <> token()
end

defmodule Bot.Users do
  @moduledoc """
  每位使用者的持久化資料 (refresh_token、spreadsheet_id)，以 chat_id (字串)
  為鍵，存於 users.json 並於每次更新時寫回檔案。
  """

  @store_file "users.json"

  def start_link do
    init =
      case File.read(@store_file) do
        {:ok, bin} -> Jason.decode!(bin)
        _ -> %{}
      end

    Agent.start_link(fn -> init end, name: __MODULE__)
  end

  def get(chat_id), do: Agent.get(__MODULE__, &Map.get(&1, to_string(chat_id)))

  def put(chat_id, fields) do
    key = to_string(chat_id)

    Agent.update(__MODULE__, fn m ->
      updated = Map.merge(Map.get(m, key, %{}), fields)
      m = Map.put(m, key, updated)
      File.write!(@store_file, Jason.encode!(m))
      m
    end)
  end

  def connected?(chat_id) do
    case get(chat_id) do
      %{"refresh_token" => rt} when is_binary(rt) -> true
      _ -> false
    end
  end
end

defmodule Bot.OAuth do
  @moduledoc """
  OAuth 使用者授權流程：產生授權連結、以 loopback HTTP 伺服器接收 Google
  重新導向的授權碼、交換 token、並快取各使用者的 access token。
  """

  require Logger

  @scope "https://www.googleapis.com/auth/drive.file"

  # state -> chat_id 的暫存對應；chat_id -> %{token, expires_at} 的 token 快取。
  def start_link do
    Agent.start_link(fn -> %{} end, name: Bot.OAuth.Pending)
    Agent.start_link(fn -> %{} end, name: Bot.OAuth.Cache)
    port = Bot.Config.redirect_port()

    {:ok, listen} =
      :gen_tcp.listen(port,
        ip: {127, 0, 0, 1},
        mode: :binary,
        packet: :raw,
        active: false,
        reuseaddr: true
      )

    spawn_link(fn -> accept_loop(listen) end)
    Logger.info("OAuth loopback 伺服器已啟動於 #{Bot.Config.redirect_uri()}")
    :ok
  end

  # 產生授權連結，並記下 state -> chat_id 的對應。
  def auth_url(chat_id) do
    c = Bot.Config.oauth_client()
    state = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    Agent.update(Bot.OAuth.Pending, &Map.put(&1, state, chat_id))

    query =
      URI.encode_query(%{
        "client_id" => c.client_id,
        "redirect_uri" => Bot.Config.redirect_uri(),
        "response_type" => "code",
        "scope" => @scope,
        "access_type" => "offline",
        "prompt" => "consent",
        "state" => state
      })

    c.auth_uri <> "?" <> query
  end

  # 取得有效的 access token：先看記憶體快取，過期則用 refresh_token 換新的。
  def access_token(chat_id) do
    cache = Agent.get(Bot.OAuth.Cache, &Map.get(&1, chat_id))

    if cache && cache.expires_at - System.os_time(:second) > 60 do
      {:ok, cache.token}
    else
      refresh(chat_id)
    end
  end

  defp refresh(chat_id) do
    case Bot.Users.get(chat_id) do
      %{"refresh_token" => rt} when is_binary(rt) ->
        c = Bot.Config.oauth_client()

        resp =
          Req.post!(c.token_uri,
            form: [
              client_id: c.client_id,
              client_secret: c.client_secret,
              refresh_token: rt,
              grant_type: "refresh_token"
            ]
          )

        case resp do
          %{status: 200, body: %{"access_token" => at, "expires_in" => ttl}} ->
            cache_token(chat_id, at, ttl)
            {:ok, at}

          other ->
            {:error, "更新 token 失敗: #{other.status} #{inspect(other.body)}"}
        end

      _ ->
        {:error, :not_connected}
    end
  end

  defp cache_token(chat_id, token, ttl) do
    entry = %{token: token, expires_at: System.os_time(:second) + ttl}
    Agent.update(Bot.OAuth.Cache, &Map.put(&1, chat_id, entry))
  end

  # ----- loopback HTTP 伺服器 -----

  defp accept_loop(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        spawn(fn -> handle_conn(sock) end)
        accept_loop(listen)

      {:error, reason} ->
        Logger.error("OAuth accept 失敗: #{inspect(reason)}")
        accept_loop(listen)
    end
  end

  defp handle_conn(sock) do
    params = read_query(sock)
    respond(sock, "✅ 授權完成，請回到 Telegram 繼續使用。您可以關閉此分頁。")

    state = params["state"]
    chat_id = state && Agent.get_and_update(Bot.OAuth.Pending, &Map.pop(&1, state))

    cond do
      params["error"] ->
        Logger.error("OAuth 使用者拒絕或錯誤: #{params["error"]}")

      is_nil(chat_id) ->
        Logger.error("OAuth callback 無對應的 state (可能已過期)")

      params["code"] ->
        finish_auth(chat_id, params["code"])

      true ->
        Logger.error("OAuth callback 缺少授權碼")
    end
  rescue
    e -> Logger.error("OAuth callback 處理失敗: #{inspect(e)}")
  end

  defp finish_auth(chat_id, code) do
    c = Bot.Config.oauth_client()

    resp =
      Req.post!(c.token_uri,
        form: [
          client_id: c.client_id,
          client_secret: c.client_secret,
          code: code,
          redirect_uri: Bot.Config.redirect_uri(),
          grant_type: "authorization_code"
        ]
      )

    case resp do
      %{status: 200, body: %{"access_token" => at, "refresh_token" => rt, "expires_in" => ttl}} ->
        Bot.Users.put(chat_id, %{"refresh_token" => rt})
        cache_token(chat_id, at, ttl)
        # 預先在使用者 Drive 建立試算表，確認流程可用。
        Bot.Sheets.ensure_spreadsheet(chat_id)

        Bot.Telegram.send_message(
          chat_id,
          "✅ Google 帳號連結成功！已在您的雲端硬碟建立「血壓紀錄」試算表。",
          Bot.Menu.main_menu_kb()
        )

      other ->
        Logger.error("交換授權碼失敗: #{other.status} #{inspect(other.body)}")

        Bot.Telegram.send_message(
          chat_id,
          "❌ Google 帳號連結失敗，請稍後再試一次。"
        )
    end
  end

  # 只需讀到第一個請求行 (GET /?code=...&state=... HTTP/1.1) 即可取得查詢參數。
  defp read_query(sock, acc \\ "") do
    if String.contains?(acc, "\r\n") do
      parse_query(acc)
    else
      case :gen_tcp.recv(sock, 0, 5000) do
        {:ok, data} -> read_query(sock, acc <> data)
        {:error, _} -> parse_query(acc)
      end
    end
  end

  defp parse_query(raw) do
    with [req_line | _] <- String.split(raw, "\r\n"),
         [_method, target | _] <- String.split(req_line, " "),
         %URI{query: q} when is_binary(q) <- URI.parse(target) do
      URI.decode_query(q)
    else
      _ -> %{}
    end
  end

  defp respond(sock, message) do
    html = """
    <!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">
    <title>血壓追蹤機器人</title></head>
    <body style="font-family:sans-serif;text-align:center;padding:3em">
    <h2>#{message}</h2></body></html>
    """

    :gen_tcp.send(
      sock,
      "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n" <>
        "Content-Length: #{byte_size(html)}\r\nConnection: close\r\n\r\n" <> html
    )

    :gen_tcp.close(sock)
  end
end

defmodule Bot.Sheets do
  @moduledoc "在使用者自己的 Drive 建立 / 讀寫私人試算表。使用該使用者的 access token。"

  @sheet_name "Sheet1"
  @headers ["日期時間", "收縮壓", "舒張壓", "脈搏", "Telegram使用者", "備註"]

  # 取得使用者試算表 ID，沒有就在其 Drive 建立一份。
  def ensure_spreadsheet(chat_id) do
    case Bot.Users.get(chat_id) do
      %{"spreadsheet_id" => id} when is_binary(id) ->
        {:ok, id}

      _ ->
        create_spreadsheet(chat_id)
    end
  end

  defp create_spreadsheet(chat_id) do
    {:ok, at} = Bot.OAuth.access_token(chat_id)

    resp =
      Req.post!("https://sheets.googleapis.com/v4/spreadsheets",
        headers: bearer(at),
        json: %{
          properties: %{title: "血壓紀錄"},
          sheets: [%{properties: %{title: @sheet_name}}]
        }
      )

    case resp do
      %{status: 200, body: %{"spreadsheetId" => id}} ->
        Bot.Users.put(chat_id, %{"spreadsheet_id" => id})
        append_row(id, at, @headers)
        {:ok, id}

      other ->
        raise "建立試算表失敗: #{other.status} #{inspect(other.body)}"
    end
  end

  def append(chat_id, systolic, diastolic, pulse, user) do
    {:ok, at} = Bot.OAuth.access_token(chat_id)
    {:ok, id} = ensure_spreadsheet(chat_id)
    append_row(id, at, [timestamp_taipei(), systolic, diastolic, pulse, user, ""])
    :ok
  end

  def recent(chat_id, n \\ 10) do
    {:ok, at} = Bot.OAuth.access_token(chat_id)
    {:ok, id} = ensure_spreadsheet(chat_id)
    suffix = "/values/" <> URI.encode(@sheet_name <> "!A2:F")
    resp = Req.get!(values_url(id, suffix), headers: bearer(at))

    case resp do
      %{status: 200, body: body} ->
        case body["values"] do
          nil -> []
          rows -> rows |> Enum.take(-n) |> Enum.reverse()
        end

      other ->
        raise "讀取紀錄失敗: #{other.status} #{inspect(other.body)}"
    end
  end

  defp append_row(spreadsheet_id, access_token, row) do
    suffix =
      "/values/" <>
        URI.encode(@sheet_name <> "!A:F") <> ":append?valueInputOption=USER_ENTERED"

    resp =
      Req.post!(values_url(spreadsheet_id, suffix),
        headers: bearer(access_token),
        json: %{values: [row]}
      )

    if resp.status not in 200..299 do
      raise "寫入試算表失敗: #{resp.status} #{inspect(resp.body)}"
    end

    :ok
  end

  # 固定 UTC+8 (台灣無日光節約)，避免依賴 tz 資料庫。
  def timestamp_taipei do
    DateTime.utc_now()
    |> DateTime.add(8 * 3600, :second)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  defp bearer(at), do: [{"authorization", "Bearer " <> at}]

  defp values_url(id, suffix),
    do: "https://sheets.googleapis.com/v4/spreadsheets/" <> id <> suffix
end

defmodule Bot.Telegram do
  @moduledoc "Telegram Bot API 薄封裝。Req bang 函式，錯誤由輪詢迴圈捕捉。"

  def get_updates(offset) do
    Req.post!(Bot.Config.api_base() <> "/getUpdates",
      json: %{offset: offset, timeout: 30},
      receive_timeout: 60_000
    ).body["result"]
  end

  def send_message(chat_id, text, keyboard \\ nil) do
    Req.post!(Bot.Config.api_base() <> "/sendMessage",
      json: with_markup(%{chat_id: chat_id, text: text}, keyboard)
    ).body["result"]
  end

  def edit_message_text(chat_id, message_id, text, keyboard \\ nil) do
    Req.post!(Bot.Config.api_base() <> "/editMessageText",
      json: with_markup(%{chat_id: chat_id, message_id: message_id, text: text}, keyboard)
    )
  end

  def answer_callback(callback_query_id) do
    Req.post!(Bot.Config.api_base() <> "/answerCallbackQuery",
      json: %{callback_query_id: callback_query_id}
    )
  end

  def with_markup(body, nil), do: body
  def with_markup(body, kb), do: Map.put(body, :reply_markup, %{inline_keyboard: kb})
end

defmodule Bot.Menu do
  @moduledoc "所有繁體中文文案與 InlineKeyboardMarkup 版面。純函式。"

  def main_menu_text, do: "👋 歡迎使用血壓追蹤機器人\n\n請選擇功能"

  def main_menu_kb do
    [
      [
        %{text: "📝 記錄血壓", callback_data: "record_bp"},
        %{text: "📊 查看最近紀錄", callback_data: "view_recent"}
      ],
      [
        %{text: "ℹ️ 說明", callback_data: "help"},
        %{text: "⚙️ 設定", callback_data: "settings"}
      ]
    ]
  end

  # 尚未連結 Google 帳號時顯示的提示與授權按鈕 (URL 按鈕)。
  def connect_text,
    do:
      "🔗 請先連結您的 Google 帳號\n\n" <>
        "機器人會在「您自己的」Google 雲端硬碟建立一份私人試算表來儲存血壓紀錄。\n" <>
        "點下方按鈕完成授權後，再回來操作。"

  def connect_kb(auth_url) do
    [
      [%{text: "🔗 連結 Google 帳號", url: auth_url}],
      [%{text: "🏠 返回主選單", callback_data: "main_menu"}]
    ]
  end

  def keypad_kb do
    [
      [
        %{text: "1", callback_data: "d:1"},
        %{text: "2", callback_data: "d:2"},
        %{text: "3", callback_data: "d:3"}
      ],
      [
        %{text: "4", callback_data: "d:4"},
        %{text: "5", callback_data: "d:5"},
        %{text: "6", callback_data: "d:6"}
      ],
      [
        %{text: "7", callback_data: "d:7"},
        %{text: "8", callback_data: "d:8"},
        %{text: "9", callback_data: "d:9"}
      ],
      [
        %{text: "0", callback_data: "d:0"},
        %{text: "⌫ 刪除", callback_data: "del"},
        %{text: "✅ 確認", callback_data: "ok"}
      ]
    ]
  end

  def prompt_text(:systolic, current),
    do: "📋 請輸入收縮壓 (mmHg)\n當前值: " <> display(current)

  def prompt_text(:diastolic, current),
    do: "📋 請輸入舒張壓 (mmHg)\n當前值: " <> display(current)

  def prompt_text(:pulse, current),
    do: "📋 請輸入脈搏 (bpm)\n當前值: " <> display(current)

  defp display(""), do: "—"
  defp display(v), do: v

  def help_text do
    """
    ℹ️ 使用說明

    歡迎使用血壓追蹤機器人！

    📝 功能說明：

    1️⃣ 記錄血壓
       輸入收縮壓、舒張壓和脈搏數據，儲存到您自己 Google 雲端硬碟的私人試算表。

    2️⃣ 查看最近紀錄
       檢視過去的血壓測量數據，追蹤健康趨勢。

    🔐 隱私
       資料存於「您自己的」Google Drive，僅您本人可存取。

    📊 血壓參考範圍：
    正常: 收縮壓 < 120 且 舒張壓 < 80
    偏高: 120 ≤ 收縮壓 < 130 且 舒張壓 < 80
    第一階段高血壓: 130 ≤ 收縮壓 < 140 或 80 ≤ 舒張壓 < 90
    第二階段高血壓: 收縮壓 ≥ 140 或 舒張壓 ≥ 90

    ⏰ 所有時間使用台灣時區 (UTC+8)
    """
  end

  def settings_text, do: "⚙️ 設定\n\n目前沒有可調整的設定。"

  def back_kb, do: [[%{text: "🏠 返回主選單", callback_data: "main_menu"}]]

  def confirmed_kb, do: [[%{text: "🏠 返回主選單", callback_data: "main_menu"}]]

  def records_kb do
    [
      [
        %{text: "🏠 返回主選單", callback_data: "main_menu"},
        %{text: "➕ 新增記錄", callback_data: "record_bp"}
      ]
    ]
  end

  def no_records_kb do
    [
      [
        %{text: "📝 開始記錄", callback_data: "record_bp"},
        %{text: "🏠 返回主選單", callback_data: "main_menu"}
      ]
    ]
  end

  def confirm_text(systolic, diastolic, pulse, ts) do
    "✅ 血壓紀錄已保存\n\n📊 記錄詳情\n收縮壓: #{systolic} mmHg\n舒張壓: #{diastolic} mmHg\n脈搏: #{pulse} bpm\n\n⏰ 記錄時間: #{ts}"
  end

  def records_text([]), do: "📊 目前沒有血壓紀錄。"

  def records_text(rows) do
    header = "📊 最近的血壓紀錄\n"

    body =
      rows
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {row, i} ->
        [ts, sys, dia, pul | _] = row ++ List.duplicate("", 4)
        "\n##{i} | #{ts}\n   收縮壓: #{sys} | 舒張壓: #{dia} | 脈搏: #{pul}"
      end)

    header <> body
  end

  # field in [:systolic, :diastolic, :pulse]; kind in [:blank, :low, :high]
  def error_text(:systolic, :blank), do: "❌ 請輸入收縮壓值。"
  def error_text(:systolic, :low), do: "❌ 收縮壓過低。正常範圍為 60-260 mmHg。"
  def error_text(:systolic, :high), do: "❌ 收縮壓過高。正常範圍為 60-260 mmHg。"
  def error_text(:diastolic, :blank), do: "❌ 請輸入舒張壓值。"
  def error_text(:diastolic, :low), do: "❌ 舒張壓過低。正常範圍為 40-160 mmHg。"
  def error_text(:diastolic, :high), do: "❌ 舒張壓過高。正常範圍為 40-160 mmHg。"
  def error_text(:pulse, :blank), do: "❌ 請輸入脈搏值。"
  def error_text(:pulse, :low), do: "❌ 脈搏過低。正常範圍為 30-220 bpm。"
  def error_text(:pulse, :high), do: "❌ 脈搏過高。正常範圍為 30-220 bpm。"
end

defmodule Bot.State do
  @moduledoc "每位使用者的對話狀態 (鍵盤輸入流程)，存於以 chat_id 為鍵的 Agent。"

  def start_link, do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def get(chat_id), do: Agent.get(__MODULE__, &Map.get(&1, chat_id))

  def put(chat_id, state), do: Agent.update(__MODULE__, &Map.put(&1, chat_id, state))

  def reset(chat_id), do: Agent.update(__MODULE__, &Map.delete(&1, chat_id))
end

defmodule Bot do
  @moduledoc "啟動 Agents/伺服器、執行長輪詢迴圈、派發更新、實作資料輸入狀態機。"

  require Logger

  alias Bot.{Telegram, Menu, State, Sheets, Users, OAuth}

  @ranges %{
    systolic: {60, 260},
    diastolic: {40, 160},
    pulse: {30, 220}
  }

  def start do
    State.start_link()
    Users.start_link()
    OAuth.start_link()
    Logger.info("血壓追蹤機器人已啟動，開始長輪詢...")
    poll_loop(0)
  end

  def poll_loop(offset) do
    updates =
      try do
        Telegram.get_updates(offset)
      rescue
        e ->
          Logger.error("getUpdates 錯誤: #{inspect(e)}")
          Process.sleep(1000)
          []
      end

    # 每筆更新各自 try/rescue，確保 offset 一定前進，避免單筆壞更新造成無限重送。
    Enum.each(updates, fn update ->
      try do
        handle(update)
      rescue
        e -> Logger.error("處理更新失敗: #{inspect(e)} | #{inspect(update)}")
      end
    end)

    poll_loop(new_offset(updates, offset))
  end

  def new_offset([], offset), do: offset

  def new_offset(updates, _offset) do
    (updates |> Enum.map(& &1["update_id"]) |> Enum.max()) + 1
  end

  # 任何文字訊息 (含 /start) -> 重置並送出主選單。
  def handle(%{"message" => msg}) do
    chat_id = msg["chat"]["id"]
    State.reset(chat_id)
    Telegram.send_message(chat_id, Menu.main_menu_text(), Menu.main_menu_kb())
  end

  def handle(%{"callback_query" => cq}) do
    # 強制：先回應 callback_query，否則使用者端 UI 會卡住轉圈。
    Telegram.answer_callback(cq["id"])

    # 訊息過舊時 Telegram 會省略 message 欄位，需防呆避免崩潰。
    case cq["message"] do
      nil ->
        :ok

      msg ->
        chat_id = msg["chat"]["id"]
        message_id = msg["message_id"]
        user = cq["from"]["username"] || to_string(cq["from"]["id"])
        route_callback(cq["data"], chat_id, message_id, user)
    end
  end

  def handle(_other), do: :ok

  # 需要 Google 連結的功能，先確認已連結，否則顯示授權連結。
  def route_callback("record_bp", chat_id, message_id, _user) do
    require_connected(chat_id, message_id, fn ->
      State.put(chat_id, %{
        step: :systolic,
        message_id: message_id,
        systolic: "",
        diastolic: "",
        pulse: ""
      })

      edit(chat_id, message_id, Menu.prompt_text(:systolic, ""), Menu.keypad_kb())
    end)
  end

  def route_callback("view_recent", chat_id, message_id, _user) do
    require_connected(chat_id, message_id, fn ->
      State.reset(chat_id)
      rows = Sheets.recent(chat_id, 10)
      kb = if rows == [], do: Menu.no_records_kb(), else: Menu.records_kb()
      edit(chat_id, message_id, Menu.records_text(rows), kb)
    end)
  end

  def route_callback("main_menu", chat_id, message_id, _user) do
    State.reset(chat_id)
    edit(chat_id, message_id, Menu.main_menu_text(), Menu.main_menu_kb())
  end

  def route_callback("help", chat_id, message_id, _user) do
    State.reset(chat_id)
    edit(chat_id, message_id, Menu.help_text(), Menu.back_kb())
  end

  def route_callback("settings", chat_id, message_id, _user) do
    State.reset(chat_id)
    edit(chat_id, message_id, Menu.settings_text(), Menu.back_kb())
  end

  def route_callback("d:" <> digit, chat_id, _message_id, _user) do
    with_state(chat_id, fn state ->
      current = Map.fetch!(state, state.step)

      new_val =
        if String.length(current) >= 3, do: current, else: current <> digit

      state = Map.put(state, state.step, new_val)
      State.put(chat_id, state)
      edit(chat_id, state.message_id, Menu.prompt_text(state.step, new_val), Menu.keypad_kb())
    end)
  end

  def route_callback("del", chat_id, _message_id, _user) do
    with_state(chat_id, fn state ->
      current = Map.fetch!(state, state.step)
      new_val = String.slice(current, 0..-2//1)
      state = Map.put(state, state.step, new_val)
      State.put(chat_id, state)
      edit(chat_id, state.message_id, Menu.prompt_text(state.step, new_val), Menu.keypad_kb())
    end)
  end

  def route_callback("ok", chat_id, _message_id, user) do
    with_state(chat_id, fn state -> on_confirm(state, chat_id, user) end)
  end

  def route_callback(_unknown, _chat_id, _message_id, _user), do: :ok

  # 未連結 Google 帳號時，顯示授權連結；已連結則執行 fun。
  defp require_connected(chat_id, message_id, fun) do
    if Users.connected?(chat_id) do
      fun.()
    else
      State.reset(chat_id)
      url = OAuth.auth_url(chat_id)
      edit(chat_id, message_id, Menu.connect_text(), Menu.connect_kb(url))
    end
  end

  # 僅在有進行中的對話時執行 keypad 動作 (d:/del/ok)。
  defp with_state(chat_id, fun) do
    case State.get(chat_id) do
      nil -> :ok
      state -> fun.(state)
    end
  end

  def on_confirm(state, chat_id, user) do
    field = state.step
    value = Map.fetch!(state, field)

    case validate(field, value) do
      {:error, kind} ->
        text = Menu.error_text(field, kind) <> "\n\n" <> Menu.prompt_text(field, value)
        edit(chat_id, state.message_id, text, Menu.keypad_kb())

      {:ok, _int} ->
        advance(state, chat_id, user)
    end
  end

  defp advance(%{step: :systolic} = state, chat_id, _user) do
    state = %{state | step: :diastolic}
    State.put(chat_id, state)
    edit(chat_id, state.message_id, Menu.prompt_text(:diastolic, ""), Menu.keypad_kb())
  end

  defp advance(%{step: :diastolic} = state, chat_id, _user) do
    state = %{state | step: :pulse}
    State.put(chat_id, state)
    edit(chat_id, state.message_id, Menu.prompt_text(:pulse, ""), Menu.keypad_kb())
  end

  defp advance(%{step: :pulse} = state, chat_id, user) do
    sys = String.to_integer(state.systolic)
    dia = String.to_integer(state.diastolic)
    pul = String.to_integer(state.pulse)

    Sheets.append(chat_id, sys, dia, pul, user)
    ts = Sheets.timestamp_taipei()

    edit(chat_id, state.message_id, Menu.confirm_text(sys, dia, pul, ts), Menu.confirmed_kb())
    State.reset(chat_id)
  end

  defp validate(field, value) do
    {lo, hi} = @ranges[field]

    cond do
      value == "" -> {:error, :blank}
      true -> check_range(String.to_integer(value), lo, hi)
    end
  end

  defp check_range(int, lo, _hi) when int < lo, do: {:error, :low}
  defp check_range(int, _lo, hi) when int > hi, do: {:error, :high}
  defp check_range(int, _lo, _hi), do: {:ok, int}

  # editMessageText 在新內容與舊內容完全相同時會回 400 "message is not modified"
  # (例如對已空欄位按刪除)。在此捕捉該情況使其成為 no-op。
  defp edit(chat_id, message_id, text, keyboard) do
    Telegram.edit_message_text(chat_id, message_id, text, keyboard)
  rescue
    e -> Logger.debug("editMessageText 略過 (可能未變更): #{inspect(e)}")
  end
end

Bot.start()
