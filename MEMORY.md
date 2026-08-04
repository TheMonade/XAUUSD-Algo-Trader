```markdown
# TRẠNG THÁI DỰ ÁN: XAU SMC TRADER BOT (MQL5)

> **File:** `MEMORY.md` , Bộ nhớ dự án tĩnh. Cập nhật lần cuối: 2026-08-04 (rev 6, hoàn thành Stops Level Clamp [FEAT-P0-012] + đồng bộ lại cây hàm Mục 2.2 theo code thực tế).
> **Lưu ý quan trọng:** Dự án này **KHÔNG phải Python**. Toàn bộ hệ thống là **Expert Advisor (EA) chạy native trên MetaTrader 5**, viết bằng **MQL5**.
> **Tên file chính thức duy nhất:** `XAU_SMC_Trader.mq5` , mọi tham chiếu, chỉnh sửa, ghi đè PHẢI dùng đúng tên này.

## 1. Bối cảnh & Mục tiêu dự án

* **Mục tiêu:** Bot giao dịch tự động Vàng (XAUUSD) theo phương pháp **SMC (Smart Money Concepts)**, kết hợp đa khung thời gian (Multi-Timeframe).
* **Chiến lược cốt lõi:** `HTF Bias (H4/D1) → H1 Order Block (POI) → chờ giá quay về vùng OB → M5 CHoCH (Change of Character) xác nhận đảo chiều → M5 FVG (Fair Value Gap) hội tụ → vào lệnh`.
* **Triết lý quản trị:** Rủi ro cố định theo % balance, quản lý lệnh theo **R-multiple** (bội số rủi ro ban đầu), có cơ chế chống overtrade và "né" vùng giá vừa gây thua lỗ.
* **Phiên bản hiện tại:** `XAU_SMC_Trader.mq5` , bản đã tích hợp FEAT-P1-008 (Liquidity Sweep), FEAT-P1-009 (FVG Filter), FEAT-P1-010 (HTF Bias Filter), FEAT-P1-011 (Session Filter) và FEAT-P0-012 (Stops Level Clamp). Không còn nợ kỹ thuật P0 nào đang mở.

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
    ├── [Inputs]                      # 11 nhóm tham số cấu hình (TRADE/OB/SL BUFFER/CHoCH/SWEEP/FVG/HTF BIAS/SESSION/POSITION MGMT/OVERTRADE/MISC)
    ├── [State toàn cục]              # Ticket, InitialVolume, HTFBiasInfo, LossZones, SessionState, g_TrailClampLogged (FEAT-P0-012)...
    ├── OnInit/OnDeinit               # Khởi tạo CTrade, indicator handles / giải phóng handle
    ├── OnTick                        # Vòng lặp chính: filter → session → HTF Bias → tìm OB → gate hướng → tìm CHoCH → FVG → clamp SL → đặt lệnh
    ├── OnTradeTransaction            # Bắt sự kiện đóng deal → đếm chuỗi thua, cooldown
    ├── ResolveSessionWindows()       # [FEAT-P1-011] Khởi tạo và validate các session window
    ├── IsInTradeSession()            # [FEAT-P1-011] Gate chính lọc thời gian giao dịch
    ├── SessionHourToMin()            # [FEAT-P1-011] Helper quy đổi giờ sang phút
    ├── ComputeTFBias()               # [FEAT-P1-010] Tính và cache bias cho từng khung H4/D1
    ├── UpdateHTFBias()               # [FEAT-P1-010] Orchestrator tổng hợp bias đa khung
    ├── CheckHTFBiasDirection()       # [FEAT-P1-010] Gate chặn entry ngược cấu trúc khung lớn
    ├── GetOB_H1()                    # Nhận diện Order Block trên H1
    ├── DetectLiquiditySweep_M5()     # Nhận diện quét thanh khoản (FEAT-P1-008)
    ├── DetectCHoCH_M5()              # Nhận diện CHoCH trên M5 + tính Smart SL
    ├── DetectFVG_M5()                # [FEAT-P1-009] Nhận diện Fair Value Gap trên M5
    ├── CheckFVGConfluence()          # [FEAT-P1-009] Orchestrator kiểm tra hội tụ FVG sau CHoCH
    ├── IsPeak()/IsTrough()           # Swing high/low theo distance + prominence (kiểu scipy)
    ├── HasOpenPosition()/GetOpenPosition()  # Kiểm tra & lấy dữ liệu lệnh đang mở theo Symbol+Magic (đã có sẵn trong code, bổ sung vào cây lần này)
    ├── ManagePosition()              # Partial close + Trailing stop theo R, guard clamp STOPS_LEVEL trước PositionModify (FEAT-P0-012)
    ├── GetMinStopDistance()          # [FEAT-P0-012] Khoảng cách tối thiểu hợp lệ SL/TP, đọc động STOPS_LEVEL/FREEZE_LEVEL + sàn 2×spread
    ├── CalcLotSize()                 # Position sizing theo RiskPercent
    ├── ResolveFillingMode()/FallbackFillingMode()/SafeOrderSend()  # [FEAT-P0-001] Auto filling mode + retry gửi lệnh (đã có sẵn trong code, bổ sung vào cây lần này)
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
* Filter trước entry: thị trường mở → không cooldown → chưa vượt `MaxTradesPerDay = 4` → `Spread ≤ 80 points` → `IsInTradeSession` hợp lệ → Hướng đánh khớp HTF Bias → OB không nằm trong blacklist loss-zone.
* **Hội tụ FVG (Phase 1):** Bắt buộc có FVG chưa bị mitigate sau CHoCH, cùng hướng với OB.
* **SL** = `smart_sl ± buffer`, buffer = `ATR(M5) × 0.15` (động).
* **TP** = `max(ob.top, entry + SL_dist × MinRR)` cho BUY (mirror cho SELL). Loại lệnh nếu RR thực tế `< MinRR = 1.5`.
* **Lot size** = `(Balance × 1%) / (SL_points × value_per_point)`, floor theo `lot_step`, clamp min/max.

#### 3.4.1. Clamp SL theo STOPS_LEVEL — ĐÃ HOÀN THÀNH [FEAT-P0-012] (2026-07-26)

Khi giãn spread (news/rollover), khoảng cách entry → Smart SL trên M5 có thể **nhỏ hơn khoảng dừng tối thiểu** sàn cho phép → lệnh bị reject `Invalid Stops` (retcode 10016). Đã implement dưới dạng bug-fix, KHÔNG thêm input mới (2 hằng số kỹ thuật qua `#define`).

**Hàm dùng chung `GetMinStopDistance()`** (thuần, không log, đọc động mỗi lần gọi — không cache STOPS_LEVEL/FREEZE_LEVEL/spread vì broker có thể đổi intraday):

```mql5
#define STOPS_SAFETY_POINTS   2     // buffer chống giá dịch giữa lúc tính và lúc lệnh tới server
#define STOPS_SPREAD_MULT     2.0   // sàn động = mult * spread hiện tại (khi broker báo STOPS_LEVEL=0)

double GetMinStopDistance()
{
   long stops_pts  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze_pts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double static_min  = MathMax((double)stops_pts, (double)freeze_pts) * Point_val;

   double spread = 0;
   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick)) spread = tick.ask - tick.bid;
   double dynamic_min = STOPS_SPREAD_MULT * spread;

   return MathMax(static_min, dynamic_min) + STOPS_SAFETY_POINTS * Point_val;
}
```

* **Entry (`OnTick`):** code tính `sl_dist` theo **2 nhánh riêng biệt** (BUY: `entry - sl_price`; SELL: `sl_price - entry`) — không phải 1 khối chung dùng `ob.ob_type` như bản nháp ban đầu giả định. Trong mỗi nhánh, ngay sau `if(sl_dist <= 0) return;`: nếu `sl_dist < GetMinStopDistance()` thì set `sl_dist = min_stop`, tính lại `sl_price` theo đúng hướng lệnh, `NormalizeDouble(..., Digits_val)`, log 1 dòng `[FEAT-P0-012] SL clamped: ...`. Khối `min_tp`/`tp_price`/`sl_points`/`CalcLotSize` phía dưới đọc lại `sl_dist`/`sl_price` nên tự động dùng giá trị SAU clamp — nếu RR sau clamp `< MinRR` → RR-check sẵn có (`actual_rr < MinRR`) tự hủy setup, không cần code thêm.
* **Trailing (`ManagePosition`):** trong block `if(profit_R >= TrailingStartR)`, sau khi tính `new_sl` (cả 2 nhánh BUY/SELL) và TRƯỚC điều kiện cải thiện (`buffer_price`/`should_modify`): guard kiểm tra `new_sl` có cách `Bid`/`Ask` hiện tại `≥ GetMinStopDistance()` không. Vi phạm → `return` (skip modify lần này, KHÔNG đẩy SL lùi — giữ kỷ luật R-multiple). Log skip chống spam qua flag global `g_TrailClampLogged` (chỉ log lần đầu của chuỗi vi phạm liên tiếp, reset khi hết vi phạm).
* Entry = **clamp** (nới SL ra + tính lại TP/RR/Lot); trailing = **skip** (không nới SL) — hành vi khác nhau có chủ đích.

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
        └→ New M5 bar? → Filters (cooldown/daily/spread)
             → IsInTradeSession (Session/Kill-zone filter)
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
* [x] **Session/Kill-zone Filter**, (FEAT-P1-011, London/NY KZ, custom window, Friday cutoff, Monday delay)
* [x] **Order Block Detection (H1)**, hoàn thành, có mitigation check
* [x] **CHoCH Detection (M5)**, hoàn thành, peak/prominence + fresh-break trigger
* [x] **Risk Management**, % risk sizing, ATR-based SL buffer, MinRR filter
* [x] **Position Management**, Partial close + R-based trailing
* [x] **Overtrade Control**, daily cap, loss-streak cooldown, loss-zone blacklist
* [x] **Execution**, CTrade với Magic, deviation 30
* [x] **Auto Filling Mode Detection**, Hoàn thành [FEAT-P0-001]
* [x] **Stops Level Clamp**, hoàn thành [FEAT-P0-012] 2026-07-26 — `GetMinStopDistance()` + clamp entry (2 nhánh BUY/SELL) + guard skip trailing (xem 3.4.1)
* [x] **Liquidity Sweep Detection**, (FEAT-P1-008)
* [x] **FVG (Fair Value Gap)**, (FEAT-P1-009, Phase 1: Filter mode)
* [ ] **News Filter**, chưa có (liên quan trực tiếp slippage/spread XAU)
* [ ] **Logging/Telemetry**, chỉ 1 `Print` khi init fail
* [ ] **State Persistence**, loss zones / counters mất khi restart EA
* [ ] **Unit Test / Backtest harness tự động**, chưa có

## 5. Định hướng nâng cấp / Refactor tiếp theo

### Ưu tiên khẩn cấp (P0, lỗi execution thực chiến) — ĐÃ XỬ LÝ HẾT

* ~~Auto-detect Filling Mode~~ — hoàn thành [FEAT-P0-001] (chi tiết 2.1).
* ~~Stops Level Clamp~~ — hoàn thành [FEAT-P0-012] 2026-07-26 (chi tiết 3.4.1).

Không còn nợ kỹ thuật P0 nào đang mở tại thời điểm cập nhật này (2026-08-04).

### Ưu tiên cao (P1)

1. **News filter:** chặn entry ±X phút quanh tin đỏ (NFP, CPI, FOMC), XAU giãn spread mạnh nhất tại các mốc này.
2. **Module hóa:** tách `SMC_OrderBlock.mqh`, `SMC_CHoCH.mqh`, `RiskManager.mqh`, `TradeManager.mqh`.

### Ưu tiên trung/thấp (P2)

3. **Time-based exit:** Đóng lệnh cuối phiên giao dịch.
4. **Logging chuẩn:** log mọi quyết định (OB found, CHoCH trigger, lý do reject, mã retcode lệnh fail) ra file/Journal.
5. **Breakeven step riêng** trước trailing (hiện trailing start = partial trigger = 1R).
6. **Multi-symbol support:** bỏ phụ thuộc `_Symbol`.


## 6. Quy chuẩn Code (Code Conventions)

* MQL5 `#property strict`; mọi array phải `ArraySetAsSeries(arr, true)` trước khi Copy.
* Indicator dùng **handle** (`iATR` + `CopyBuffer`), release trong `OnDeinit`.
* Mọi lệnh gửi qua `CTrade` với `MagicNumber = 202405`; mọi filter position check cả `Symbol` + `Magic`.
* **Execution an toàn cho XAUUSD (BẮT BUỘC):**
* KHÔNG hard-code filling mode, luôn dò `SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE)` rồi mới `Trade.SetTypeFilling()` (ưu tiên FOK → IOC → RETURN).
* MỌI giá SL/TP trước khi gửi/modify phải thỏa: khoảng cách tới giá thị trường `≥ max(SYMBOL_TRADE_STOPS_LEVEL, SYMBOL_TRADE_FREEZE_LEVEL) × _Point`.
* Sau khi clamp SL → tính lại TP, RR, lot trên khoảng SL mới; RR sau clamp `< MinRR` → hủy setup.
* Kiểm tra `Trade.ResultRetcode()` sau mỗi lệnh; log retcode khi thất bại, không retry mù quá 2 lần.


* **Thời gian và phiên:** Mọi logic so sánh giờ giấc quy về số phút-từ-nửa-đêm (0 đến 1439). Tuyệt đối sử dụng `TimeCurrent()` (server time), không dùng `TimeGMT()` hoặc `TimeLocal()` để bảo đảm đồng nhất khi backtest.
* Giá SL/TP phải `NormalizeDouble(..., Digits_val)`; lot floor theo `lot_step`, clamp `[lot_min, lot_max]`.
* Tham số chiến lược luôn qua `input`, không hard-code magic numbers trong logic.
* Naming: biến global prefix `g_`, struct PascalCase (`OBZone`, `CHoCHResult`, `LossZone`).
* **Tên file chính thức:** `XAU_SMC_Trader.mq5`, mọi thay đổi logic ghi vào change-log cuối file `.mq5` và cập nhật `MEMORY.md` cùng lúc; đổi tên file phải cập nhật đồng thời Mục 1 + 2.2.

```

```
## 7. Quản trị rủi ro OVERFIT & Phân loại tái sử dụng module

> **Bối cảnh:** Hệ thống hiện có 5 lớp gate chồng nhau (Session → HTF Bias → OB → Sweep/CHoCH → FVG) với ~25–30 tham số tự do, được phát triển tuần tự qua 4 vòng feature A/B test. Đây là cấu hình **có rủi ro overfit CAO** nếu không có quy trình kiểm soát. Mục này là **quy trình bắt buộc**, không phải khuyến nghị.

### 7.1. Phân loại 4 nguồn rủi ro overfit

| # | Loại overfit | Biểu hiện trong dự án | Mức độ |
|---|---|---|---|
| O1 | **Parameter explosion** | ~25–30 input ảnh hưởng quyết định entry (OB × 3, Sweep × 5, FVG × 5, Bias × 5, Session × 7, Risk × 4...). Mỗi lần chọn default "vì backtest tốt hơn" = 1 phép tối ưu ngầm | Cao |
| O2 | **Data snooping quy trình** | Cả 4 feature P1-008 → P1-011 đều được chấp nhận nhờ cải thiện kết quả **trên cùng T1/T5**. Không cần chạy optimizer, bộ tham số cuối cùng vẫn đã "nhìn thấy" toàn bộ dữ liệu test → backtest không còn là dự báo mà là ký ức | **Rất cao — đang xảy ra** |
| O3 | **Filter stacking (overfit cấu trúc)** | 5 lớp gate → lệnh phải thỏa đồng thời đúng bias + đúng session + OB hiệu lực + sweep chuẩn + FVG displacement. Nếu chỉ còn 30–50 lệnh/năm, "edge" đo được có thể chỉ là chuỗi may mắn, thiếu ý nghĩa thống kê | Cao |
| O4 | **Overfit khái niệm** | Các ngưỡng số hóa khái niệm SMC là tùy ý (`1.5 × ATR`, `0.5 × ATR`, `Peak_Distance = 5`...) — không có lý thuyết nào bảo chứng con số này; dễ fit vào quá khứ của riêng XAUUSD/broker/giai đoạn 2023–2026 | Trung bình |

### 7.2. Định mức chấp nhận được (Acceptance Thresholds)

Một cấu hình/feature chỉ được coi là "không overfit" khi thỏa **TẤT CẢ**:

1. **Robustness lân cận:** xê dịch từng tham số nhạy cảm ±50% quanh giá trị chọn → kết luận (expectancy > 0, feature có hiệu quả) **không đảo chiều**.
2. **Đủ mẫu thống kê:** cấu hình cuối (sau mọi filter) phải có **≥ 100 lệnh** trên vùng dữ liệu kiểm chứng; dưới mức này mọi kết luận chỉ là "gợi ý", không phải "bằng chứng".
3. **Out-of-sample pass:** hiệu năng trên vùng Validation (chưa từng nhìn) đạt **≥ 50%** hiệu năng in-sample (theo expectancy), và max drawdown không vượt 1.5× in-sample.
4. **Kỳ vọng live thực tế:** mặc định hiệu năng live ≈ 50–70% backtest là bình thường, không phải dấu hiệu bot hỏng.

### 7.3. Biện pháp bắt buộc (Measures)

| # | Biện pháp | Chi tiết áp dụng |
|---|---|---|
| M1 | **Phân vùng dữ liệu 3 vùng** | *Development* (T1/T5 hiện tại — được nhìn, dùng tune); *Validation* (khoảng mới, **chỉ chạy 1 lần** sau khi chốt toàn bộ feature P1); *Final* (chỉ chạy **đúng 1 lần** trước khi live). Tuyệt đối không quay lại chỉnh code/tham số sau khi chạy Validation |
| M2 | **Walk-forward analysis** | Thay 1 backtest tĩnh bằng cửa sổ trượt: tune đoạn A → kiểm chứng đoạn B → trượt tiếp. Ghi nhận tỷ lệ window pass/fail thay vì 1 con số tổng |
| M3 | **Kỷ luật A/B song hành** | Mọi feature ON/OFF bằng input (đã có) — khi kết quả tổng tệ, chẩn đoán theo thứ tự: (1) chi phí spread/slippage → (2) số lệnh có đủ mẫu không → (3) tắt từng filter tìm lớp phá → (4) mới kết luận strategy sai. KHÔNG được kết luận từ backtest tổng hợp duy nhất |
| M4 | **Cross-symbol sanity check** | Chạy cấu hình cuối trên EURUSD/GBPUSD: không nhất thiết lãi nhưng **không được vỡ hoàn toàn** — chứng tỏ logic bắt hiện tượng thị trường chứ không chỉ nhiễu XAUUSD (phụ thuộc P2 Multi-symbol) |
| M5 | **Ngân sách thất bại (failure budget)** | Mỗi strategy mới test lại trên cùng bộ data = 1 vòng data snooping. Sau **2–3 strategy thất bại** trên cùng dữ liệu, bộ data đó hết giá trị kiểm chứng → bắt buộc lấy dữ liệu mới |
| M6 | **Ưu tiên đơn giản khi hòa** | Nếu 2 cấu hình cho kết quả tương đương, chọn cấu hình ít filter/ít tham số hơn (Occam's razor). Filter stacking chỉ được giữ nếu mỗi lớp chứng minh được đóng góp độc lập qua A/B |

### 7.4. Phân loại module theo tính tái sử dụng (khi thay strategy)

Nếu backtest tổng (sau khi đã chẩn đoán theo M3) chứng minh SMC core không có edge trên XAU M5/H1 → **thay "ruột" strategy, giữ hạ tầng**. Phân loại:

| Nhóm | Module | Tái sử dụng |
|---|---|---|
| **R1 — Hạ tầng giao dịch** (strategy-agnostic 100%) | `SafeOrderSend`, `ResolveFillingMode` + fallback, `CalcLotSize`, STOPS_LEVEL clamp (khi implement), `IsMarketTradeable`, `SessionHourToMin` | ✅ Giữ nguyên cho mọi strategy |
| **R2 — Quản trị vốn & lệnh** | `ManagePosition` (partial/trailing theo R), daily cap, loss-streak cooldown, loss-zone blacklist, `OnTradeTransaction` | ✅ Giữ — tài sản quý nhất, độc lập hoàn toàn với cách tìm entry |
| **R3 — Bộ lọc bối cảnh** | Session/Kill-zone (P1-011), HTF Bias (P1-010), News filter (tương lai) | ✅ Giữ — mọi strategy trend/momentum đều cần đúng giờ + đúng hướng lớn |
| **R4 — Nguyên liệu thô** | `IsPeak`/`IsTrough`, ATR/EMA handles, Sweep detector, FVG detector | ⚠️ Một phần — swing detection generic; sweep/FVG tái dùng cho biến thể SMC/ICT khác (breaker block, mitigation, liquidity grab) |
| **R5 — SMC Core (phần thay được)** | `GetOB_H1`, `DetectCHoCH_M5` | ❌ Thay thế — đây chính là "strategy logic" cần đổi khi SMC thất bại |

**Ước lượng:** ~60–70% codebase (R1 + R2 + R3) sống sót qua mọi lần thay strategy.

### 7.5. Signal Contract (điều kiện để "thay ruột" sạch)

Pipeline hiện tại đã vô tình có interface ngầm giữa "tìm tín hiệu" và "thực thi". Để thay strategy không phải phẫu thuật monolith, cần formalize (đi kèm P1 Module hóa, Mục 5 item 4):

```mql5
// Contract tín hiệu — mọi strategy mới chỉ cần trả về struct này,
// toàn bộ R1/R2/R3 chạy lại nguyên xi không sửa dòng nào
struct TradeSignal
{
   int    direction;      // +1 BUY, -1 SELL, 0 = no signal
   double sl_anchor;      // điểm neo SL (tương đương smart_sl hiện tại)
   double tp_reference;   // mốc tham chiếu TP (tương đương ob.top/bottom)
   double zone_top;       // vùng POI — để loss-zone blacklist hoạt động
   double zone_bottom;
   string context_tag;    // tag chiến lược cho logging ("SMC_OB_CHOCH", ...)
};
```

* Strategy mới (vd: EMA crossover + Donchian breakout) = 1 hàm trả về `TradeSignal` → `OnTick` ráp vào pipeline sẵn có (SL buffer, MinRR, CalcLotSize, SafeOrderSend, ManagePosition).
* **Nguyên tắc:** mọi feature mới từ nay PHẢI giữ ON/OFF bằng input và không hard-wire vào contract — đảm bảo tháo lắp từng mảnh không phá code.
```