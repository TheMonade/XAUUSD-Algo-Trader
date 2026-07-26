```markdown
# TRẠNG THÁI DỰ ÁN: XAU SMC TRADER BOT (MQL5)

> **File:** `MEMORY.md` , Bộ nhớ dự án tĩnh. Cập nhật lần cuối: 2026-07-26 (rev 4, bổ sung HTF Bias H4/D1).
> **Lưu ý quan trọng:** Dự án này **KHÔNG phải Python**. Toàn bộ hệ thống là **Expert Advisor (EA) chạy native trên MetaTrader 5**, viết bằng **MQL5**.
> **Tên file chính thức duy nhất:** `XAU_SMC_Trader.mq5` , mọi tham chiếu, chỉnh sửa, ghi đè PHẢI dùng đúng tên này.

## 1. Bối cảnh & Mục tiêu dự án

* **Mục tiêu:** Bot giao dịch tự động Vàng (XAUUSD) theo phương pháp **SMC (Smart Money Concepts)**, kết hợp đa khung thời gian (Multi-Timeframe).
* **Chiến lược cốt lõi:** `HTF Bias (H4/D1) → H1 Order Block (POI) → chờ giá quay về vùng OB → M5 CHoCH (Change of Character) xác nhận đảo chiều → M5 FVG (Fair Value Gap) hội tụ → vào lệnh`.
* **Triết lý quản trị:** Rủi ro cố định theo % balance, quản lý lệnh theo **R-multiple** (bội số rủi ro ban đầu), có cơ chế chống overtrade và "né" vùng giá vừa gây thua lỗ.
* **Phiên bản hiện tại:** `XAU_SMC_Trader.mq5` , bản đã tích hợp FEAT-P1-008 (Liquidity Sweep), FEAT-P1-009 (FVG Filter) và FEAT-P1-010 (HTF Bias Filter).

## 2. Cấu trúc hệ thống

| Hạng mục | Chi tiết |
| --- | --- |
| Ngôn ngữ | MQL5 (MetaQuotes Language 5), `#property strict` |
| Nền tảng | MetaTrader 5 (EA event-driven: `OnInit`, `OnTick`, `OnTradeTransaction`, `OnDeinit`) |
| Thư viện chuẩn | `Trade\Trade.mqh` (CTrade), `Trade\PositionInfo.mqh` (CPositionInfo), `Indicators\Indicators.mqh` |
| Indicator | ATR H1, ATR M5, ATR H4/D1, EMA H4/D1 qua handle `iATR`/`iMA` + `CopyBuffer` |
| Symbol mục tiêu | XAUUSD (chart-attached `_Symbol`) |
| Kiến trúc | **Monolith 1 file** , toàn bộ logic nằm trong 1 file `.mq5` |
| Execution Mode | Tự động dò theo bitmask broker (ResolveFillingMode), bọc qua SafeOrderSend với cơ chế fallback FOK -> IOC -> RETURN khi gặp lỗi 10030|

### 2.1. Quy tắc Execution Mode (BẮT BUỘC khi refactor)

XAUUSD biến động cực nhanh khi ra tin; `ORDER_FILLING_RETURN` bị nhiều broker ECN/STP từ chối, lỗi `Unsupported filling mode` hoặc đặt lệnh thất bại. **Không được hard-code filling mode.** Quy tắc chuẩn:

```mql5
// Gọi trong OnInit() TRƯỚC khi Trade.SetTypeFilling()
ENUM_ORDER_TYPE_FILLING GetSupportedFilling()
{
   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE); // bitmask
   if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN; // fallback (Exchange/Market execution)
}

```

* Thứ tự ưu tiên: **FOK → IOC → RETURN** (tự dò theo bitmask của broker).
* Kết hợp `Trade.SetDeviationInPoints(30)` để kiểm soát slippage; cân nhắc tăng deviation động theo ATR trong phiên tin mạnh, hoặc chặn entry ±X phút quanh tin (news filter, chưa có, xem Mục 5).

### 2.2. Cấu trúc file & vai trò (đã thống nhất tên file)

```
project_root/
├── MEMORY.md                         # File này, bộ nhớ dự án
└── XAU_SMC_Trader.mq5                # EA DUY NHẤT, tên chính thức, không đổi/ghi đè nhầm
    ├── [Inputs]                      # 8 nhóm tham số cấu hình (thêm HTF BIAS FILTER)
    ├── [State toàn cục]              # Ticket, InitialVolume, HTFBiasInfo, LossZones...
    ├── OnInit/OnDeinit               # Khởi tạo CTrade, indicator handles / giải phóng handle
    ├── OnTick                        # Vòng lặp chính: filter → HTF Bias → tìm OB → gate hướng → tìm CHoCH → FVG → đặt lệnh
    ├── OnTradeTransaction            # Bắt sự kiện đóng deal → đếm chuỗi thua, cooldown
    ├── ComputeTFBias()               # [FEAT-P1-010] Tính và cache bias cho từng khung H4/D1
    ├── UpdateHTFBias()               # [FEAT-P1-010] Orchestrator tổng hợp bias đa khung
    ├── CheckHTFBiasDirection()       # [FEAT-P1-010] Gate chặn entry ngược cấu trúc khung lớn
    ├── GetOB_H1()                    # Nhận diện Order Block trên H1
    ├── DetectLiquiditySweep_M5()     # Nhận diện quét thanh khoản (FEAT-P1-008)
    ├── DetectCHoCH_M5()              # Nhận diện CHoCH trên M5 + tính Smart SL
    ├── DetectFVG_M5()                # [FEAT-P1-009] Nhận diện Fair Value Gap trên M5
    ├── CheckFVGConfluence()          # [FEAT-P1-009] Orchestrator kiểm tra hội tụ FVG sau CHoCH
    ├── IsPeak()/IsTrough()           # Swing high/low theo distance + prominence (kiểu scipy)
    ├── ManagePosition()              # Partial close + Trailing stop theo R
    ├── CalcLotSize()                 # Position sizing theo RiskPercent
    ├── IsZoneBlocked()/RegisterLossZone()  # Blacklist vùng OB gây thua (ring buffer 10 slot)
    └── IsMarketTradeable(), InCooldown(), UpdateDailyCounterIfNewDay()  # Filter phụ trợ

```

> **Quy ước đặt tên phiên bản:** Nếu tạo bản mới, đặt `XAU_SMC_Trader_v{N}.mq5` và cập nhật lại mục này + Mục 1. Tuyệt đối không tồn tại song song 2 tên file mơ hồ.

## 3. Chi tiết logic giao dịch (SMC Core)

### 3.1. HTF Bias Filter H4/D1, `UpdateHTFBias()` & `CheckHTFBiasDirection()`

* **Phương pháp định hướng:** Cấu trúc Swing (HH/HL, LH/LL) hoặc Giá so với EMA, hoặc yêu cầu đồng thuận cả hai.
* **Chế độ đa khung:** H4 only, D1 only, H4 + D1 (đồng thuận), hoặc H4 chính (D1 dự phòng khi H4 trung lập).
* **Cơ chế Cache:** Chỉ tính toán lại khi có nến mới trên khung thời gian HTF tương ứng, tiết kiệm tài nguyên trên nến M5.
* **Neutral Policy:** Quyết định hành vi khi cấu trúc không rõ ràng (cho phép giao dịch 2 chiều hoặc chặn tất cả).

### 3.2. Order Block H1, `GetOB_H1()`

* Quét `OB_Lookback = 100` nến H1 (từ nến index 1, bỏ nến đang chạy).
* **Bullish OB:** Tìm nến tăng có `body > ATR(15) × 1.5` (displacement candle) → nến ngay trước đó (`i+1`) phải là **nến giảm** → vùng OB = `[low, high]` của nến giảm đó.
* **Bearish OB:** Đối xứng, nến giảm mạnh, nến trước đó là nến tăng.
* **Kiểm tra mitigation:** Quét từ nến OB về hiện tại; nếu có `close` phá xuyên đáy OB (bullish) / đỉnh OB (bearish) → OB **mất hiệu lực**.
* Trả về OB **gần nhất còn hiệu lực** (return ngay khi tìm thấy đầu tiên).

### 3.3. CHoCH M5, `DetectCHoCH_M5()`

Với OB Bullish (Bearish làm đối xứng):

1. **Touch check:** Trong 100 nến M5, phải có ít nhất 1 nến có `low` chạm vùng OB (`bottom ≤ low ≤ top`).
2. **Tìm swing high gần nhất:** `IsPeak()`, cao hơn `Peak_Distance = 5` nến 2 bên **và** prominence `≥ ATR(M5) × 0.5`.
3. **Trigger CHoCH:** `close[1]` phá lên swing high và `close[2]` còn nằm dưới, breakout mới xảy ra (chống re-trigger).
4. **Sweep filter:** Xác nhận nến có độ xuyên từ `0.05` đến `2.0` ATR qua `ref_level`. Khóa lệnh nếu có breakdown đóng nến hoàn toàn qua cực.
5. **Smart SL:** Lấy `sweep_extreme` làm SL hoặc fallback về `lowest low` từ swing peak đến hiện tại, SL phải nằm trong/dưới OB (`lowest_low ≤ ob.top`).

### 3.4. Vào lệnh & Risk (trong `OnTick`)

* **Chạy theo nến M5 mới** (bar-close logic), không xử lý mỗi tick khi chưa có lệnh.
* Filter trước entry: thị trường mở → không cooldown → chưa vượt `MaxTradesPerDay = 4` → `Spread ≤ 80 points` → Hướng đánh khớp HTF Bias → OB không nằm trong blacklist loss-zone.
* **Hội tụ FVG (Phase 1):** Bắt buộc có FVG chưa bị mitigate sau CHoCH, cùng hướng với OB.
* **SL** = `smart_sl ± buffer`, buffer = `ATR(M5) × 0.15` (động).
* **TP** = `max(ob.top, entry + SL_dist × MinRR)` cho BUY (mirror cho SELL). Loại lệnh nếu RR thực tế `< MinRR = 1.5`.
* **Lot size** = `(Balance × 1%) / (SL_points × value_per_point)`, floor theo `lot_step`, clamp min/max.

#### 3.4.1. Clamp SL theo STOPS_LEVEL (BẮT BUỘC, chống "Invalid Stops")

Khi giãn spread (news/rollover), khoảng cách entry → Smart SL trên M5 có thể **nhỏ hơn khoảng dừng tối thiểu** sàn cho phép → lệnh bị reject `Invalid Stops`. Quy tắc chuẩn phải áp dụng TRƯỚC khi gửi lệnh và TRƯỚC mọi `PositionModify`:

```mql5
long   stops_level_pts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); // points
long   freeze_level    = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
double min_dist_price  = MathMax(stops_level_pts, freeze_level) * Point_val;

// Clamp: SL_Distance = max(Calculated_SL_Distance, StopsLevel)
double sl_dist = MathMax(MathAbs(entry - sl_price), min_dist_price);
// Tính lại sl_price từ sl_dist đã clamp, rồi mới tính TP/RR/Lot từ sl_dist MỚI

```

* **Quan trọng:** Nếu SL bị nới ra do clamp → **phải tính lại TP và RR trên khoảng SL mới** (nếu RR mới `< MinRR` → hủy lệnh). Không được tính lot trên SL cũ.
* Áp dụng tương tự trong `ManagePosition()`: SL trailing mới phải cách `Bid/Ask` tối thiểu `min_dist_price`, nếu không → skip lần modify đó.

### 3.5. Quản lý lệnh, `ManagePosition()`

* **Partial close:** Lãi `≥ 1.0R` → đóng `66%` volume (kiểm tra `lot_min`/`lot_step`).
* **Trailing stop:** Kích hoạt từ `1.0R`, SL trail cách giá `1.0R`, chỉ modify khi cải thiện `> 0.1R` (chống spam modify). Phải tuân thủ clamp STOPS_LEVEL ở 3.4.1.

### 3.6. Chống Overtrade & Loss-Zone Blacklist

* **Daily cap:** Tối đa 4 lệnh/ngày (reset theo ngày lịch).
* **Loss streak:** 2 lệnh thua liên tiếp → cooldown 12 nến H1 (profit tính gồm swap + commission trong `OnTradeTransaction`).
* **Loss zones:** OB gây thua ghi vào ring buffer 10 slot, block re-entry 24 nến H1, proximity = `ATR(H1) × 1.0`.

## 4. Luồng dữ liệu & Trạng thái hoàn thành

### Luồng dữ liệu chính

```
Tick → [Có position?] ─Yes→ ManagePosition (Partial/Trailing + clamp StopsLevel)
        │No
        └→ New M5 bar? → Filters (session/cooldown/daily/spread)
             → UpdateHTFBias (Cache theo nến H4/D1)
             → GetOB_H1 (POI) → CheckHTFBiasDirection (Gate chặn ngược trend)
             → IsZoneBlocked → DetectCHoCH_M5 (trigger + Smart SL)
             → CheckFVGConfluence (FVG Filter)
             → Clamp SL theo STOPS_LEVEL → Tính lại TP/RR → CalcLotSize
             → Trade.Buy/Sell (filling mode tự dò theo broker)
             → Lưu state (zone, initial risk, ticket)

Deal closed → OnTradeTransaction → cập nhật loss streak / loss zone / reset state

```

### Trạng thái module

* [x] **Data Access**, CopyBuffer/CopyHigh/Low/Open/Close, ATR handles (có check lỗi)
* [x] **HTF Bias Filter (H4/D1)**, (FEAT-P1-010, hoàn thành filter 4 mode + logic Swing/EMA)
* [x] **Order Block Detection (H1)**, hoàn thành, có mitigation check
* [x] **CHoCH Detection (M5)**, hoàn thành, peak/prominence + fresh-break trigger
* [x] **Risk Management**, % risk sizing, ATR-based SL buffer, MinRR filter
* [x] **Position Management**, Partial close + R-based trailing
* [x] **Overtrade Control**, daily cap, loss-streak cooldown, loss-zone blacklist
* [x] **Execution**, CTrade với Magic, deviation 30
* [x] **Auto Filling Mode Detection**, Hoàn thành [FEAT-P0-001]
* [ ] **Stops Level Clamp**, CHƯA CÓ trong entry lẫn trailing (P0, xem 3.4.1)
* [x] **Liquidity Sweep Detection**, (FEAT-P1-008)
* [x] **FVG (Fair Value Gap)**, (FEAT-P1-009, Phase 1: Filter mode)
* [ ] **Session/Kill-zone Filter (London/NY)**, chỉ check symbol tradeable
* [ ] **News Filter**, chưa có (liên quan trực tiếp slippage/spread XAU)
* [ ] **Logging/Telemetry**, chỉ 1 `Print` khi init fail
* [ ] **State Persistence**, loss zones / counters mất khi restart EA
* [ ] **Unit Test / Backtest harness tự động**, chưa có

## 5. Định hướng nâng cấp / Refactor tiếp theo

### Ưu tiên khẩn cấp (P0, lỗi execution thực chiến)

1. **Auto-detect Filling Mode** theo `SYMBOL_FILLING_MODE` (FOK → IOC → RETURN) trong `OnInit`, chống lỗi reject lệnh trên broker ECN/STP (chi tiết 2.1).

### Ưu tiên cao (P1)

2. **Session/Kill-zone filter:** giới hạn entry London + NY.
3. **News filter:** chặn entry ±X phút quanh tin đỏ (NFP, CPI, FOMC), XAU giãn spread mạnh nhất tại các mốc này.
4. **Module hóa:** tách `SMC_OrderBlock.mqh`, `SMC_CHoCH.mqh`, `RiskManager.mqh`, `TradeManager.mqh`.

### Ưu tiên trung/thấp (P2)

5. **Logging chuẩn:** log mọi quyết định (OB found, CHoCH trigger, lý do reject, mã retcode lệnh fail) ra file/Journal.
6. **Breakeven step riêng** trước trailing (hiện trailing start = partial trigger = 1R).
7. **Multi-symbol support:** bỏ phụ thuộc `_Symbol`.

## 6. Quy chuẩn Code (Code Conventions)

* MQL5 `#property strict`; mọi array phải `ArraySetAsSeries(arr, true)` trước khi Copy.
* Indicator dùng **handle** (`iATR` + `CopyBuffer`), release trong `OnDeinit`.
* Mọi lệnh gửi qua `CTrade` với `MagicNumber = 202405`; mọi filter position check cả `Symbol` + `Magic`.
* **Execution an toàn cho XAUUSD (BẮT BUỘC):**
* KHÔNG hard-code filling mode, luôn dò `SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE)` rồi mới `Trade.SetTypeFilling()` (ưu tiên FOK → IOC → RETURN).
* MỌI giá SL/TP trước khi gửi/modify phải thỏa: khoảng cách tới giá thị trường `≥ max(SYMBOL_TRADE_STOPS_LEVEL, SYMBOL_TRADE_FREEZE_LEVEL) × _Point`.
* Sau khi clamp SL → tính lại TP, RR, lot trên khoảng SL mới; RR sau clamp `< MinRR` → hủy setup.
* Kiểm tra `Trade.ResultRetcode()` sau mỗi lệnh; log retcode khi thất bại, không retry mù quá 2 lần.


* Giá SL/TP phải `NormalizeDouble(..., Digits_val)`; lot floor theo `lot_step`, clamp `[lot_min, lot_max]`.
* Tham số chiến lược luôn qua `input`, không hard-code magic numbers trong logic.
* Naming: biến global prefix `g_`, struct PascalCase (`OBZone`, `CHoCHResult`, `LossZone`).
* **Tên file chính thức:** `XAU_SMC_Trader.mq5`, mọi thay đổi logic ghi vào change-log cuối file `.mq5` và cập nhật `MEMORY.md` cùng lúc; đổi tên file phải cập nhật đồng thời Mục 1 + 2.2.

```

```