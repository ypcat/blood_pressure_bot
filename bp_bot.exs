Mix.install([{:req, "~> 0.5"}, {:jose, "~> 1.11"}, {:jason, "~> 1.4"}])

# =============================================================================
# 血壓追蹤 Telegram 機器人 (Blood Pressure Tracking Telegram Bot)
# =============================================================================
#
# 單檔 Elixir 腳本，使用 Telegram 長輪詢 (long polling) 與 Google Sheets v4 API
# (服務帳號 OAuth2 JWT) 作為後端儲存。繁體中文 (台灣) 內嵌鍵盤介面。
#
# -----------------------------------------------------------------------------
# 必要的環境變數 (Required environment variables):
# -----------------------------------------------------------------------------
#   TELEGRAM_BOT_TOKEN  - 從 @BotFather 取得的 Telegram bot token
#   GOOGLE_SHEET_ID     - Google 試算表的 spreadsheetId (網址中 /d/<這段>/edit)
#   GOOGLE_SA_KEY_FILE  - Google 服務帳號 JSON 金鑰檔案的絕對路徑
#
# -----------------------------------------------------------------------------
# 如何建立服務帳號並分享試算表 (Setup):
# -----------------------------------------------------------------------------
#   1. 前往 Google Cloud Console -> 建立專案 -> 啟用「Google Sheets API」。
#   2. 建立「服務帳號 (Service Account)」，並產生 JSON 金鑰，下載存檔。
#      金鑰檔內含 client_email / private_key / token_uri 等欄位。
#   3. 開啟你的 Google 試算表，點「共用」，把該服務帳號的 client_email
#      (形如 xxx@yyy.iam.gserviceaccount.com) 加為「編輯者」。
#   4. 試算表第一列(標題列)請預先填入 6 欄:
#        日期時間 | 收縮壓 | 舒張壓 | 脈搏 | Telegram使用者 | 備註
#   5. 若你的工作表(分頁)名稱不是 "Sheet1"，請修改下方 @sheet_name 常數。
#
# -----------------------------------------------------------------------------
# 執行方式 (How to run):
# -----------------------------------------------------------------------------
#   export TELEGRAM_BOT_TOKEN=...
#   export GOOGLE_SHEET_ID=...
#   export GOOGLE_SA_KEY_FILE=/path/to/service_account.json
#   elixir bp_bot.exs
# =============================================================================

require Logger

defmodule Bot.Config do
  @moduledoc "讀取環境變數與服務帳號 JSON 金鑰。無可變狀態。"

  def token, do: System.fetch_env!("TELEGRAM_BOT_TOKEN")

  def sheet_id, do: System.fetch_env!("GOOGLE_SHEET_ID")

  def service_account do
    System.fetch_env!("GOOGLE_SA_KEY_FILE")
    |> File.read!()
    |> Jason.decode!()
    |> then(fn json ->
      %{
        client_email: json["client_email"],
        private_key: json["private_key"],
        token_uri: json["token_uri"] || "https://oauth2.googleapis.com/token"
      }
    end)
  end

  def api_base, do: "https://api.telegram.org/bot" <> token()
end

defmodule Bot.Auth do
  @moduledoc "鑄造並快取 Google OAuth2 access token (RS256 JWT via JOSE)。"

  def start_link do
    Agent.start_link(fn -> %{token: nil, expires_at: 0} end, name: __MODULE__)
  end

  def token do
    cache = Agent.get(__MODULE__, & &1)

    if valid?(cache) do
      cache.token
    else
      # 在 Agent 交易外進行網路請求，避免請求失敗時連帶讓 Agent 程序崩潰。
      fresh = refresh()
      Agent.update(__MODULE__, fn _ -> fresh end)
      fresh.token
    end
  end

  def valid?(cache) do
    cache.token != nil and cache.expires_at - System.os_time(:second) > 60
  end

  def refresh do
    sa = Bot.Config.service_account()
    jwt = build_jwt(sa)

    resp =
      Req.post!(sa.token_uri,
        form: [
          grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
          assertion: jwt
        ]
      )

    case resp do
      %{status: 200, body: %{"access_token" => tok, "expires_in" => ttl}} ->
        %{token: tok, expires_at: System.os_time(:second) + ttl}

      other ->
        raise "Google token 端點錯誤: #{other.status} #{inspect(other.body)}"
    end
  end

  def build_jwt(sa) do
    jwk = JOSE.JWK.from_pem(sa.private_key)
    iat = System.os_time(:second)

    claims = %{
      "iss" => sa.client_email,
      "scope" => "https://www.googleapis.com/auth/spreadsheets",
      "aud" => sa.token_uri,
      "iat" => iat,
      "exp" => iat + 3600
    }

    {_, jwt} =
      JOSE.JWT.sign(jwk, %{"alg" => "RS256"}, claims)
      |> JOSE.JWS.compact()

    jwt
  end
end

defmodule Bot.Sheets do
  @moduledoc "新增血壓紀錄列、讀取最近 N 列。使用 Bot.Auth.token/0 作為 bearer。"

  # 工作表(分頁)名稱與範圍。若你的分頁不叫 "Sheet1"，請改這裡。
  @sheet_name "Sheet1"

  def append(systolic, diastolic, pulse, user) do
    suffix =
      "/values/" <>
        URI.encode(@sheet_name <> "!A:F") <> ":append?valueInputOption=USER_ENTERED"

    resp =
      Req.post!(url(suffix),
        headers: auth_header(),
        json: %{values: [[timestamp_taipei(), systolic, diastolic, pulse, user, ""]]}
      )

    if resp.status not in 200..299 do
      raise "Sheets 寫入失敗: #{resp.status} #{inspect(resp.body)}"
    end

    :ok
  end

  def recent(n \\ 10) do
    suffix = "/values/" <> URI.encode(@sheet_name <> "!A2:F")

    resp = Req.get!(url(suffix), headers: auth_header())

    case resp do
      %{status: 200, body: body} ->
        case body["values"] do
          nil -> []
          rows -> rows |> Enum.take(-n) |> Enum.reverse()
        end

      other ->
        raise "Sheets 讀取失敗: #{other.status} #{inspect(other.body)}"
    end
  end

  # 固定 UTC+8 (台灣無日光節約)，避免依賴 tz 資料庫。
  def timestamp_taipei do
    DateTime.utc_now()
    |> DateTime.add(8 * 3600, :second)
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  def auth_header, do: [{"authorization", "Bearer " <> Bot.Auth.token()}]

  def url(suffix),
    do: "https://sheets.googleapis.com/v4/spreadsheets/" <> Bot.Config.sheet_id() <> suffix
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
       輸入收縮壓、舒張壓和脈搏數據，自動保存到個人紀錄。

    2️⃣ 查看最近紀錄
       檢視過去的血壓測量數據，追蹤健康趨勢。

    3️⃣ 設定
       調整個人偏好設定。

    📊 血壓參考範圍：
    正常: 收縮壓 < 120 且 舒張壓 < 80
    偏高: 120 ≤ 收縮壓 < 130 且 舒張壓 < 80
    第一階段高血壓: 130 ≤ 收縮壓 < 140 或 80 ≤ 舒張壓 < 90
    第二階段高血壓: 收縮壓 ≥ 140 或 舒張壓 ≥ 90

    ⏰ 所有時間使用台灣時區 (UTC+8)

    💡 貼示：定期測量血壓有助於監測健康。
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
  @moduledoc "每位使用者的對話狀態，存於以 chat_id 為鍵的 Agent。"

  def start_link, do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def get(chat_id), do: Agent.get(__MODULE__, &Map.get(&1, chat_id))

  def put(chat_id, state), do: Agent.update(__MODULE__, &Map.put(&1, chat_id, state))

  def reset(chat_id), do: Agent.update(__MODULE__, &Map.delete(&1, chat_id))
end

defmodule Bot do
  @moduledoc "啟動 Agents、執行長輪詢迴圈、派發更新、實作資料輸入狀態機。"

  require Logger

  alias Bot.{Telegram, Menu, State, Sheets}

  @ranges %{
    systolic: {60, 260},
    diastolic: {40, 160},
    pulse: {30, 220}
  }

  def start do
    Bot.State.start_link()
    Bot.Auth.start_link()
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

  # 任何文字訊息 (含 /start) -> 重置並送出主選單 (新訊息，因無前一個鍵盤訊息可編輯)
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

  def route_callback("record_bp", chat_id, message_id, _user) do
    State.put(chat_id, %{
      step: :systolic,
      message_id: message_id,
      systolic: "",
      diastolic: "",
      pulse: ""
    })

    edit(chat_id, message_id, Menu.prompt_text(:systolic, ""), Menu.keypad_kb())
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

  def route_callback("view_recent", chat_id, message_id, _user) do
    State.reset(chat_id)
    rows = Sheets.recent(10)
    kb = if rows == [], do: Menu.no_records_kb(), else: Menu.records_kb()
    edit(chat_id, message_id, Menu.records_text(rows), kb)
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

  # 僅在有進行中的對話時執行 keypad 動作 (d:/del/ok)
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

    Sheets.append(sys, dia, pul, user)
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
