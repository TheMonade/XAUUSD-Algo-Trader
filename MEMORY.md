```markdown
# TRẠNG THÁI DỰ ÁN: XAU TRADING BOT PLATFORM (MQL5)

> **File:** MEMORY.md , Bộ nhớ dự án tĩnh. Cập nhật lần cuối: 2026-08-11 (rev 11 , Hoàn thành FEAT-S2-001 và feature Market Closed Spam).
> **Lưu ý quan trọng:** Dự án này **KHÔNG phải Python**. Toàn bộ hệ thống là **Expert Advisor (EA) chạy native trên MetaTrader 5**, viết bằng **MQL5**.
> **File ACTIVE duy nhất:** XAU_Donchian_Trader.mq5 (đã tạo base và hoàn thiện logic). File XAU_SMC_Trader.mq5 **ĐÓNG BĂNG** , CẤM chỉnh sửa, chi tiết lưu trữ tại ARCHIVE_STRAT-001_SMC.md.

## 1. Bối cảnh & Strategy Registry

* **Mục tiêu platform:** Xây dựng hạ tầng EA giao dịch XAUUSD tái sử dụng được (execution an toàn, risk manager theo R-multiple, bộ lọc bối cảnh), trên đó thay thế strategy lõi (signal source) theo quy trình kiểm chứng chặt (Mục 6).
* **Kết luận nền tảng đã kiểm chứng:** XAUUSD là tài sản **trend mạnh, quét thanh khoản liên tục** , mean-reversion SL hẹp khung nhỏ bị phạt nặng; trend-following SL rộng theo ATR khung lớn là hướng phù hợp (bằng chứng: ARCHIVE_STRAT-001_SMC.md Mục A2).
* **Triết lý quản trị (xuyên mọi strategy):** Rủi ro cố định theo % balance, quản lý lệnh theo **R-multiple**, chống overtrade, execution tuân thủ rule broker.

### 1.1. Strategy Registry 

| ID | Tên | Trạng thái | File code | File archive |
|---|---|---|---|---|
| STRAT-001 | SMC: H1 OB + M5 CHoCH (+Sweep/FVG/Bias/Session) | **CLOSED , FAILED** | XAU_SMC_Trader.mq5 (đóng băng) | ARCHIVE_STRAT-001_SMC.md |
| STRAT-002 | Donchian Breakout H1 + ATR Chandelier Trailing | **ACTIVE , Đã tích hợp FEAT-S2-001** | XAU_Donchian_Trader.mq5 | , |

* **Quy tắc:** chỉ 1 strategy ACTIVE tại 1 thời điểm. Strategy CLOSED **không bao giờ được "mở lại"** trên cùng bộ dữ liệu (M5/M7, Mục 6.3).
* **Quy ước archive:** khi CLOSED một strategy , tạo ARCHIVE_STRAT-00X_<Tên>.md theo mẫu A1,A7 của ARCHIVE_STRAT-001_SMC.md, chuyển file code sang đóng băng, cập nhật Registry. MEMORY.md chỉ giữ 1 dòng con trỏ trong Registry, KHÔNG nhân bản chi tiết.
* **Failure budget (M5):** T1/T5 đã tiêu tốn = 5 vòng feature SMC + 1 vòng xác nhận âm bản. STRAT-002 là strategy thứ 2 trên cùng data , **chỉ được dùng T1/T5 cho Development**; Validation bắt buộc theo Mục 4.2.

## 2. Cấu trúc hệ thống

| Hạng mục | Chi tiết |
| --- | --- |
| Ngôn ngữ | MQL5 (MetaQuotes Language 5), #property strict |
| Nền tảng | MetaTrader 5 (EA event-driven: OnInit, OnTick, OnTradeTransaction, OnDeinit) |
| Thư viện chuẩn | Trade\Trade.mqh (CTrade), Trade\PositionInfo.mqh (CPositionInfo), Indicators\Indicators.mqh |
| Indicator | ATR H1 (SL/trailing), ATR H4/D1 + EMA H4/D1 (HTF Bias , tạo handle có điều kiện) qua iATR/iMA + CopyBuffer |
| Symbol mục tiêu | XAUUSD (chart-attached _Symbol) |
| Kiến trúc | **Monolith 1 file per strategy.** Module hóa .mqh HOÃN tới khi STRAT-002 pass Development (tránh confound: refactor đồng thời với đổi strategy) |
| Execution Mode | Tự động dò theo bitmask broker (ResolveFillingMode), bọc qua SafeOrderSend với fallback FOK -> IOC -> RETURN khi gặp lỗi 10030 [FEAT-P0-001] |

### 2.1. Quy tắc Execution Mode (BẮT BUỘC khi refactor)

XAUUSD biến động cực nhanh khi ra tin; ORDER_FILLING_RETURN bị nhiều broker ECN/STP từ chối, lỗi Unsupported filling mode hoặc đặt lệnh thất bại. **Không được hard-code filling mode.** Quy tắc chuẩn:

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

* Thứ tự ưu tiên: **FOK , IOC , RETURN** (tự dò theo bitmask của broker).
* Kết hợp Trade.SetDeviationInPoints(30) để kiểm soát slippage; cân nhắc chặn entry ±X phút quanh tin (news filter, chưa có, xem Mục 5).

### 2.2. Cấu trúc file & vai trò

```
project_root/
├── MEMORY.md                         # File này , bộ nhớ platform (chỉ ACTIVE + quy trình)
├── ARCHIVE_STRAT-001_SMC.md          # Archive STRAT-001 (đóng băng, chi tiết logic + bằng chứng)
├── XAU_SMC_Trader.mq5                # ĐÓNG BĂNG. CẤM sửa. Kho code nguồn để COPY module R1,R3
└── XAU_Donchian_Trader.mq5           # File ACTIVE duy nhất , STRAT-002
    ├── [Phần copy nguyên xi từ archive code]  # theo bản đồ Mục 2.3
    │     ├── SafeOrderSend()/ResolveFillingMode()/FallbackFillingMode()  # [P0-001] (tích hợp feature Market Closed Spam)
    │     ├── CalcLotSize(), IsMarketTradeable() (tích hợp feature Market Closed Spam)
    │     ├── ManagePosition() (partial + R-trailing + Chandelier mode)
    │     ├── Daily cap / loss-streak cooldown / OnTradeTransaction
    │     ├── HTF Bias: ComputeTFBias()/UpdateHTFBias()/CheckHTFBiasDirection()  # [P1-010]
    │     ├── Session: ResolveSessionWindows()/IsInTradeSession()/SessionHourToMin()  # [P1-011]
    │     ├── GetMinStopDistance() + clamp entry/trailing  # [P0-012]
    │     └── IsPeak()/IsTrough() (phục vụ HTF Bias)
    └── [Phần viết mới , Donchian core]   # FEAT-S2-001

```

* **Quy ước tên file:** mỗi strategy = 1 file riêng, tên XAU_*Trader.mq5; archive = ARCHIVE_STRAT-00X*<Tên>.md. File ACTIVE duy nhất ghi tại Mục 1. File CLOSED đóng băng tại Registry + Mục 2.2 đồng thời.
* **Cấm:** chỉnh sửa file đóng băng; tồn tại 2 file ACTIVE; copy module mà không ghi nguồn trong change-log file mới.

### 2.3. Bản đồ tái sử dụng module (SMC archive , Donchian)

| Module (nguồn: XAU_SMC_Trader.mq5) | Nhóm | Hành động cho STRAT-002 |
| --- | --- | --- |
| SafeOrderSend, ResolveFillingMode, FallbackFillingMode | R1 | Copy nguyên xi, tích hợp feature chặn spam Market Closed |
| CalcLotSize, IsMarketTradeable | R1 | Copy nguyên xi, tích hợp feature chặn spam Market Closed |
| Stops Level Clamp [P0-012] (spec sẵn) | R1 | Đã merge lần đầu vào file mới , **P0 hoàn thành** |
| ManagePosition (partial + R-trailing) | R2 | Tích hợp mode Chandelier ATR trailing và feature chặn spam Market Closed |
| Daily cap, loss-streak cooldown, OnTradeTransaction | R2 | Copy nguyên xi |
| Loss-zone blacklist | R2 | Đã tích hợp , zone = breakout range (giả định mới, A/B test ON/OFF) |
| HTF Bias Filter [P1-010] | R3 | Copy nguyên xi , trend context filter |
| Session Filter [P1-011] (spec sẵn) | R3 | Đã merge lần đầu vào file mới |
| IsPeak/IsTrough, ATR/EMA handles | R4 | Copy (phục vụ HTF Bias; ATR H1 cho SL/trailing) |
| GetOB_H1, DetectCHoCH_M5, Sweep, FVG | R5 | Bỏ , thay bằng Donchian core (FEAT-S2-001) |

## 3. STRAT-002: Donchian Breakout H1 + ATR Trailing (Thiết kế chốt)

> Spec chi tiết sẽ viết riêng (FEAT-S2-001). Mục này chốt các quyết định thiết kế cốt lõi , AI Coder không được tự suy diễn khác đi.

### 3.1. Logic entry

* **Khung:** Entry/exit trên **H1** (bar-close). KHÔNG dùng M5 (bài học A5.1 , M5 quá nhỏ cho XAU).
* **Setup BUY:** close[1] H1 phá lên trên Donchian High của DC_Period = 20 nến H1 (tính trên nến đã đóng, không gồm nến đang chạy). SELL đối xứng với Donchian Low.
* **Fresh-break trigger:** close[2] chưa phá (chống re-trigger).
* **Context filter (bắt buộc):** chỉ vào lệnh **cùng hướng HTF Bias** (module P1-010, default HTF_TF_H4_ONLY + method SWING). Neutral , NEUTRAL_ALLOW_ALL (A/B test sau).
* **Session filter:** chỉ entry trong London/NY kill-zone (module P1-011). A/B test ON/OFF.
* **Một lệnh tại một thời điểm** (giữ cơ chế HasOpenPosition).

### 3.2. SL / TP / Exit

* **SL khởi tạo:** entry ∓ DC_SL_ATR_Mult × ATR(H1), default DC_SL_ATR_Mult = 2.5.
* **KHÔNG TP cố định.** Thoát bằng **Chandelier trailing**: SL = đỉnh cao nhất kể từ entry ∓ DC_Trail_ATR_Mult × ATR(H1) (BUY; SELL đối xứng), default DC_Trail_ATR_Mult = 3.0. SL chỉ dịch theo hướng có lợi, KHÔNG BAO GIỜ nới lỏng.
* **Partial close:** giữ cơ chế partial 66% tại 1R , A/B test riêng vì chandelier đã là cơ chế chốt lời.
* **Stops Level Clamp [P0-012]:** bắt buộc cho cả SL khởi tạo lẫn mọi lần modify trailing.
* **Lot:** theo RiskPercent = 1% trên SL sau clamp (CalcLotSize nguyên xi).
* **KHÔNG dùng MinRR filter** (không TP cố định) , loại bỏ 1 tham số (M6).

### 3.3. Tham số tự do (chỉ 3 , chống O1)

| Input | Default | Robustness range bắt buộc |
| --- | --- | --- |
| DC_Period | 20 | {15, 20, 30, 40} |
| DC_SL_ATR_Mult | 2.5 | {2.0, 2.5, 3.0} |
| DC_Trail_ATR_Mult | 3.0 | {2.5, 3.0, 4.0} |

Kết luận chỉ hợp lệ nếu **không đảo chiều** trong toàn bộ lưới robustness trên (Mục 6.2).

### 3.4. Kỳ vọng & tiêu chí pass Development

* Tần suất: 5,15 lệnh/tháng , ≥ 100 lệnh/7 năm (đủ mẫu, Mục 6.2).
* Hình thái kỳ vọng: winrate 35,45%, payoff trung bình ≥ 2.5R, equity có các pha flat dài (đặc trưng trend-following , **không** đánh giá bằng "đường equity mượt").
* **Pass Development khi:** expectancy > 0 sau chi phí trên T1/T5 **và** lưới robustness không đảo chiều **và** max DD ≤ 25%.

## 4. Luồng dữ liệu & Data Governance

### 4.1. Luồng dữ liệu chính (STRAT-002)

```
Tick → [Có position?] ─Yes→ ManagePosition (Partial + Chandelier trailing + clamp StopsLevel)
        │No
        └→ New H1 bar? → Filters (tradeable/cooldown/daily/spread)
             → IsInTradeSession (P1-011)
             → UpdateHTFBias (cache theo nến H4/D1)
             → Donchian fresh-break check (Mục 3.1) + bias direction gate
             → SL = 2.5×ATR(H1) → Clamp STOPS_LEVEL (P0-012) → CalcLotSize
             → SafeOrderSend (filling tự dò)
             → Lưu state (initial risk, ticket, highest-since-entry)

Deal closed → OnTradeTransaction → cập nhật loss streak / reset state

```

### 4.2. Data Governance (thay thế M1 cũ , vì data lịch sử đã cạn)

| Vùng | Khoảng | Trạng thái |
| --- | --- | --- |
| Development | 2024.02 – 2026.07 (XAUUSD-VIP, VTMarkets) | EXHAUSTED cho validation.
  Lưu ý: broker chỉ cung cấp history từ 2024.02.20; vùng 2019.07–2024.02
  của T1/T5 gốc KHÔNG khả dụng trên symbol này. Đủ mẫu kiểm lại: ~2.4 năm
  × 5–15 lệnh/tháng ≈ 150–430 lệnh, vẫn ≥ 100 (MEMORY 6.2-2) nhưng biên mỏng.
  → Validation (forward demo + cross-broker) càng trở nên BẮT BUỘC, vì
  cross-broker chính là cách phủ lại giai đoạn 2019–2024 nếu broker khác
  có dữ liệu sâu hơn. |
| Validation | Chưa có | Tạo theo kế hoạch bên dưới |
| Final | Chưa có | Chỉ chạy đúng 1 lần trước live |

**Kế hoạch Validation cho STRAT-002 (bắt buộc), gồm ÍT NHẤT 2 trong 3:**

1. **Forward test demo** tối thiểu 3 tháng trên tài khoản demo cùng broker (dữ liệu hoàn toàn mới).
2. **Cross-broker data:** backtest trên dữ liệu broker khác (feed khác = gần-như-dữ-liệu-mới; khác cấu trúc spread/swap).
3. **Cross-symbol sanity (M4):** chạy EURUSD/GBPUSD , không được vỡ hoàn toàn.

* **Ngưỡng pass Validation:** theo Mục 6.2 (≥ 50% expectancy in-sample, DD ≤ 1.5×, đủ mẫu).
* **Cấm:** tune tham số Donchian trên bất kỳ dữ liệu nào thuộc Validation.

## 5. Trạng thái module Platform

* [x] **Auto Filling Mode Detection** , [FEAT-P0-001], đã kiểm chứng trong file SMC
* [x] **Risk Management theo R** , partial/trailing/cooldown, đã kiểm chứng
* [x] **HTF Bias Filter** , [FEAT-P1-010], hoàn thành, tái dùng cho STRAT-002
* [x] **Stops Level Clamp** , [FEAT-P0-012], đã merge vào file STRAT-002 (P0)
* [x] **Session/Kill-zone Filter** , [FEAT-P1-011], đã merge vào file STRAT-002
* [x] **Donchian Core** , FEAT-S2-001, hoàn thành spec và tích hợp logic
* [x] **Chandelier Trailing mode** , tích hợp trong ManagePosition
* [x] **Loss-zone cho Donchian** , đã tích hợp logic breakout range (cần A/B test ON/OFF)
* [x] **Market Closed Spam Control (Feature)** , bẫy retcode 10018 chống tràn log
* [ ] **News Filter** , chưa có; **độ ưu tiên tăng** vì breakout nhạy tin hơn SMC
* [ ] **Logging/Telemetry, State Persistence, Test harness** , debt giữ nguyên

### Roadmap

## **P0 (hoàn thành):**

1. [x] Viết spec chi tiết **FEAT-S2-001** (Donchian core + Chandelier trailing) theo khung Mục 3.
2. [x] Tạo XAU_Donchian_Trader.mq5: copy R1,R3 theo bản đồ 2.3 + merge P0-012 + merge P1-011 + Donchian core + Chandelier trailing + feature Market Closed Spam.

## **P1:**

4. Đánh giá Development theo tiêu chí 3.4 , quyết định GO/NO-GO.
5. Nếu GO , Validation theo 4.2 (forward demo + cross-broker).
6. News filter (độ nhạy tăng với breakout strategy).

## **P2:**

7. Module hóa .mqh + Signal Contract , **chỉ làm sau khi STRAT-002 pass Development**.
8. Phương án dự phòng nếu STRAT-002 fail: EMA Pullback (B) hoặc Session ORB (C) , phân tích lựa chọn xem ARCHIVE_STRAT-001_SMC.md Mục A6. **Lưu ý failure budget (M5): nếu STRAT-002 fail trên T1/T5, strategy thứ 3 PHẢI có dữ liệu mới.**

## 6. Quy chuẩn Code, Quản trị Overfit & Tái sử dụng

### 6.1. Quy chuẩn Code (Code Conventions)

* MQL5 #property strict; mọi array phải ArraySetAsSeries(arr, true) trước khi Copy.
* Indicator dùng **handle** (iATR + CopyBuffer), release trong OnDeinit.
* Mọi lệnh gửi qua CTrade với MagicNumber riêng của từng strategy (STRAT-002 dùng Magic mới, KHÔNG dùng lại 202405); mọi filter position check cả Symbol + Magic.
* **Execution an toàn cho XAUUSD (BẮT BUỘC):**
* KHÔNG hard-code filling mode, luôn dò SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE) rồi mới Trade.SetTypeFilling() (FOK , IOC , RETURN).
* MỌI giá SL/TP trước khi gửi/modify phải thỏa: khoảng cách tới giá thị trường ≥ GetMinStopDistance() (đọc động: STOPS_LEVEL/FREEZE_LEVEL + sàn 2×spread + safety 2 points).
* Sau khi clamp SL , tính lại các đại lượng phụ thuộc trên khoảng SL mới.
* Kiểm tra Trade.ResultRetcode() sau mỗi lệnh; log retcode khi thất bại, không retry mù quá 2 lần.
* **Thời gian và phiên:** Mọi logic so sánh giờ giấc quy về số phút-từ-nửa-đêm (0,1439). Tuyệt đối dùng TimeCurrent() (server time), không TimeGMT()/TimeLocal().
* Giá SL/TP phải NormalizeDouble(..., Digits_val); lot floor theo lot_step, clamp [lot_min, lot_max].
* Tham số chiến lược luôn qua input (ngoại lệ: hằng số kỹ thuật execution qua #define).
* Naming: biến global prefix g_, struct PascalCase.
* **Quy tắc file đa-strategy:** mỗi strategy 1 file XAU__Trader.mq5; file CLOSED đóng băng + tạo file archive riêng (Mục 1.1); copy module từ archive code phải ghi nguồn trong change-log file mới.
* Mọi thay đổi logic ghi vào change-log cuối file .mq5 và cập nhật MEMORY.md cùng lúc.

### 6.2. Quản trị rủi ro OVERFIT (quy trình bắt buộc)

> STRAT-001 đã minh chứng cả 4 nguồn overfit là có thật. STRAT-002 được thiết kế đối nghịch: chỉ 3 tham số tự do, ít gate, logic đơn giản.

**4 nguồn rủi ro:** O1 Parameter explosion (đối sách: 3 tham số) · O2 Data snooping quy trình (T1/T5 đã exhausted , đang xảy ra) · O3 Filter stacking (đối sách: chỉ 2 context filter, mỗi cái tự chứng minh qua A/B) · O4 Overfit khái niệm (đối sách: lưới robustness Mục 3.3).

**Acceptance Thresholds (thỏa TẤT CẢ):**

1. **Robustness lân cận:** xê dịch tham số ±50% , kết luận không đảo chiều.
2. **Đủ mẫu:** ≥ 100 lệnh trên vùng kiểm chứng; dưới mức này chỉ là "gợi ý".
3. **Out-of-sample pass:** Validation (4.2) đạt ≥ 50% expectancy in-sample, DD ≤ 1.5×.
4. **Kỳ vọng live:** live ≈ 50,70% backtest là bình thường.

### 6.3. Biện pháp bắt buộc (Measures)

| # | Biện pháp | Chi tiết |
| --- | --- | --- |
| M1 | **Phân vùng dữ liệu** | Xem Mục 4.2 , T1/T5 chỉ còn vai trò Development; Validation = forward demo + cross-broker (+ cross-symbol). Không chỉnh code/tham số sau khi chạy Validation |
| M2 | **Walk-forward** | Cửa sổ trượt: tune A , kiểm chứng B , trượt tiếp; ghi tỷ lệ window pass/fail |
| M3 | **Kỷ luật A/B** | Kết quả tệ , chẩn đoán theo thứ tự: (1) chi phí , (2) đủ mẫu? , (3) tắt từng filter , (4) mới kết luận strategy sai |
| M4 | **Cross-symbol sanity** | EURUSD/GBPUSD không được vỡ hoàn toàn |
| M5 | **Failure budget** | T1/T5 đã tiêu: 5 vòng feature + 1 âm bản SMC + 1 Development Donchian. STRAT-002 fail , strategy thứ 3 bắt buộc dữ liệu mới |
| M6 | **Ưu tiên đơn giản** | Hòa nhau , chọn ít filter/ít tham số hơn (Occam's razor) |
| M7 | **Kết luận âm bản là tài sản** | Strategy CLOSED , tạo ARCHIVE_STRAT-00X_<Tên>.md đầy đủ (mẫu A1,A7). Cấm "thử lại" strategy đã CLOSED trên cùng dữ liệu |

### 6.4. Phân loại tái sử dụng module

Đã chứng minh thực tiễn qua pivot STRAT-001 , STRAT-002 (~60,70% codebase tái sử dụng):

| Nhóm | Module | Tình trạng |
| --- | --- | --- |
| **R1 , Hạ tầng giao dịch** | SafeOrderSend, ResolveFillingMode, CalcLotSize, GetMinStopDistance, IsMarketTradeable | ✅ Copy nguyên xi |
| **R2 , Quản trị vốn & lệnh** | ManagePosition (+ Chandelier mode), daily cap, cooldown, OnTradeTransaction, loss-zone (⚠️ A/B lại) | ✅ Copy, mở rộng |
| **R3 , Bộ lọc bối cảnh** | HTF Bias (P1-010), Session (P1-011), News filter (tương lai) | ✅ Copy/merge |
| **R4 , Nguyên liệu thô** | IsPeak/IsTrough, ATR/EMA handles | ✅ Copy |
| **R5 , Strategy core (thay được)** | STRAT-001 SMC core , archive; STRAT-002 Donchian core , ACTIVE | 🔄 Thay thế theo Registry |

### 6.5. Signal Contract (hướng đi tương lai , P2)

```mql5
// Contract tín hiệu , mọi strategy mới chỉ cần trả về struct này,
// toàn bộ R1/R2/R3 chạy lại nguyên xi không sửa dòng nào
struct TradeSignal
{
   int    direction;      // +1 BUY, -1 SELL, 0 = no signal
   double sl_anchor;      // điểm neo SL (Donchian: ATR-based anchor)
   double tp_reference;   // 0 nếu strategy dùng trailing thay TP cố định
   double zone_top;       // vùng POI , Donchian: breakout range
   double zone_bottom;
   string context_tag;    // tag chiến lược cho logging ("DONCHIAN_H1_BO", ...)
};


```

* **Nguyên tắc:** mọi feature mới PHẢI giữ ON/OFF bằng input và không hard-wire vào contract.

## 7. Quy trình kỹ thuật lặp lại được (Checklist vận hành)

1. **Trước khi merge bất kỳ feature nào:** compile 0/0 , regression ON/OFF khớp build cũ , backtest A/B theo ma trận của spec.
2. **Sau khi merge:** cập nhật change-log cuối file .mq5 + MEMORY.md (Mục 5) cùng lúc.
3. **Trước mọi vòng backtest đánh giá:** kiểm tra Mục 4.2 , dữ liệu định dùng có thuộc vùng được phép không.
4. **Khi CLOSED một strategy:** tạo ARCHIVE_STRAT-00X_<Tên>.md theo mẫu A1,A7 (kết luận, bằng chứng, chẩn đoán, trạng thái code, bài học, phương án thay thế, lịch sử backtest); chuyển file code sang đóng băng; cập nhật Registry (Mục 1.1) , MEMORY.md không nhân bản chi tiết archive.

## 8. Tham chiếu Archive

| File | Nội dung | Trạng thái |
| --- | --- | --- |
| ARCHIVE_STRAT-001_SMC.md | STRAT-001 SMC: kết luận FAILED + bằng chứng backtest 7 năm, toàn bộ chi tiết logic (OB/CHoCH/Sweep/FVG/Bias/Session/Clamp), trạng thái code đóng băng, bài học A5, phương án thay thế A6 | Đóng băng 2026-08-04 |

```

```