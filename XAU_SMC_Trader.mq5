//+------------------------------------------------------------------+
//|                                    XAU_SMC_Trader.mq5            |
//| Strategy: H1 Order Block + M5 CHoCH Entry                        |
//| FIXED VERSION, see change-log at bottom of file                  |
//+------------------------------------------------------------------+
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Indicators\Indicators.mqh>

// === [FEAT-P0-012] Stops Level Clamp — hằng số kỹ thuật, KHÔNG phải tham số chiến lược ===
#define STOPS_SAFETY_POINTS   2     // buffer chống giá dịch giữa lúc tính và lúc lệnh tới server
#define STOPS_SPREAD_MULT     2.0   // sàn động = mult * spread hiện tại (cho broker báo STOPS_LEVEL=0)

enum ENUM_FVG_ENTRY_MODE
{
   FVG_MODE_FILTER = 0,   // FVG filter mode, entry market (Phase 1, implement)
   FVG_MODE_LIMIT  = 1    // Limit order at CE (Phase 2, NOT implemented)
};

enum ENUM_HTF_TF_MODE
{
   HTF_TF_H4_ONLY    = 0,   // Chỉ dùng H4
   HTF_TF_D1_ONLY    = 1,   // Chỉ dùng D1
   HTF_TF_BOTH_AND   = 2,   // H4 và D1 phải đồng thuận
   HTF_TF_H4_PRIMARY = 3    // H4 chính, D1 fallback khi H4 neutral
};

enum ENUM_HTF_METHOD
{
   HTF_METHOD_SWING = 0,    // Cấu trúc swing HH/HL (chuẩn SMC)
   HTF_METHOD_EMA   = 1,    // Giá vs EMA + slope
   HTF_METHOD_BOTH  = 2     // Cả hai đồng thuận mới định hướng
};

enum ENUM_HTF_NEUTRAL
{
   NEUTRAL_ALLOW_ALL = 0,   // Neutral: vẫn cho vào lệnh cả 2 chiều
   NEUTRAL_BLOCK_ALL = 1    // Neutral: chặn mọi entry mới
};

enum ENUM_SESSION_TIMEBASE
{
   TIMEBASE_SERVER = 0,   // Giờ nhập = giờ server broker (khuyến nghị cho broker GMT+2/+3)
   TIMEBASE_GMT    = 1    // Giờ nhập = GMT, quy đổi qua Session_GMT_Offset
};

input group "=== TRADE SETTINGS ==="
input double   RiskPercent      = 1.0;
input double   MinRR            = 1.0;
input int      MagicNumber      = 202405;

input group "=== ORDER BLOCK (H1) ==="
input int      OB_Lookback      = 100;
input int      OB_ATR_Period    = 15;
input double   OB_ATR_Mult      = 1.0;

input group "=== SL BUFFER (ATR-based, not fixed $) ==="
input double   SL_Buffer_ATR_Mult = 0.15;   // buffer = this * M5 ATR (was fixed $0.50)

input group "=== CHoCH (M5) ==="
input int      CHoCH_Lookback   = 100;
input int      ATR_Period_M5    = 14;
input double   CHoCH_Prom_Mult  = 0.2;
input int      Peak_Distance    = 5;

input group "=== LIQUIDITY SWEEP (M5) ==="
input bool     UseSweepFilter          = true;  // bật/tắt filter sweep (A/B test)
input double   Sweep_MinPen_ATR_Mult   = 0.05;  // độ xuyên tối thiểu = mult * ATR(M5)
input double   Sweep_MaxPen_ATR_Mult   = 2.0;   // độ xuyên tối đa (quá sâu = breakdown)
input int      Sweep_MaxAgeBars        = 36;    // sweep phải xảy ra trong N nến M5 gần nhất
input double   Sweep_BodyClosePct      = 0.0;   // % thân nến tối thiểu đóng trên ref_level

input group "=== FVG (M5) [FEAT-P1-009] ==="
input bool                UseFVGFilter           = false;   // bật/tắt filter FVG (A/B test)
input ENUM_FVG_ENTRY_MODE FVG_EntryMode          = FVG_MODE_FILTER; // Phase 2 chưa dùng
input double              FVG_MinGapATRMult      = 0.10;   // gap tối thiểu = mult * ATR(M5)
input double              FVG_MaxGapATRMult      = 3.0;    // gap tối đa (quá lớn = news spike)
input double              FVG_DispATRMult        = 1.0;    // nến giữa phải có body > mult * ATR
input int                 FVG_MaxAgeBars         = 24;     // FVG phải hình thành trong N nến M5 gần nhất
input bool                FVG_RequireUnmitigated = true;   // loại FVG đã bị close xuyên qua
input bool                FVG_MustOverlapOB      = false;  // yêu cầu FVG overlap vùng OB H1
input double              FVG_EntryLevelPct      = 0.5;    // [Phase 2] mức vào trong gap: 0.5 = CE
input int                 FVG_ExpiryBars         = 12;     // [Phase 2] pending hết hạn sau N nến M5

input group "=== HTF BIAS FILTER (H4/D1) [FEAT-P1-010] ==="
input bool                 UseHTFBiasFilter     = false;             // bật/tắt bias filter (A/B test)
input ENUM_HTF_TF_MODE     HTF_TF_Mode          = HTF_TF_H4_ONLY;   // khung bias: H4 / D1 / kết hợp
input ENUM_HTF_METHOD      HTF_Method           = HTF_METHOD_SWING; // phương pháp: swing / EMA / both
input ENUM_HTF_NEUTRAL     HTF_NeutralPolicy    = NEUTRAL_ALLOW_ALL;// hành vi khi bias = neutral
input int                  HTF_Lookback         = 120;              // số nến HTF quét swing
input int                  HTF_SwingDistance    = 3;                // distance xác nhận swing (2 bên)
input double               HTF_PromMult         = 0.5;              // prominence = mult * ATR(TF)
input int                  HTF_EMA_Period       = 50;               // chu kỳ EMA (method EMA/BOTH)
input double               HTF_EMAFlatATRMult   = 0.05;             // |slope| <= mult*ATR => EMA phẳng => neutral

input group "=== SESSION / KILL-ZONE FILTER [FEAT-P1-011] ==="
// LUU Y: default gio SERVER cho broker GMT+2/+3 (US DST). Broker khac timezone
// phai chinh lai gio, hoac dung TIMEBASE_GMT + Session_GMT_Offset.
input bool                  UseSessionFilter      = false;             // bật/tắt session filter (A/B test)
input ENUM_SESSION_TIMEBASE Session_TimeBase      = TIMEBASE_SERVER;  // giờ nhập theo server hay GMT
input int                   Session_GMT_Offset    = 2;                // offset broker vs GMT (chỉ dùng khi TIMEBASE_GMT)
input bool                  UseLondonKZ           = true;             // London Kill-zone
input double                London_StartHour      = 9.0;              // 9.0 = 09:00 server ≈ 07:00 GMT (broker GMT+2/+3)
input double                London_EndHour        = 12.0;             // hỗ trợ lẻ: 12.5 = 12:30
input bool                  UseNewYorkKZ          = true;             // New York Kill-zone
input double                NewYork_StartHour     = 14.0;             // 14:00 server ≈ 12:00 GMT
input double                NewYork_EndHour       = 17.0;
input bool                  UseCustomSession      = false;            // window tùy chỉnh (Asia/thí nghiệm), hỗ trợ qua nửa đêm
input double                Custom_StartHour      = 2.0;
input double                Custom_EndHour        = 7.0;
input int                   Session_NoEntryBeforeEndMin = 15;         // chặn entry trong N phút cuối window (0 = tắt)
input bool                  UseFridayCutoff       = true;             // chặn entry cuối ngày thứ 6
input double                Friday_CutoffHour     = 20.0;             // sau giờ này thứ 6 không entry mới
input bool                  UseMondayDelay        = false;            // chặn entry đầu ngày thứ 2
input double                Monday_OpenHour       = 1.0;              // trước giờ này thứ 2 không entry mới

input group "=== POSITION MANAGEMENT (R-multiple based) ==="
input double   PartialAtR       = 1.0;   // start partial close once profit >= 1.0 x initial risk
input double   PartialClosePct  = 0.66;  // close 66% of volume at PartialAtR
input double   TrailingStartR   = 1.0;   // start trailing once profit >= 1.0 x initial risk
input double   TrailingStepR    = 1.0;   // Khoang cach trailing cach gia hien tai 1R
input double   TrailingBufferR  = 0.10;  // minimum improvement (in R) before re-modifying SL

input group "=== OVERTRADE / COOLDOWN CONTROL ==="
input int      MaxTradesPerDay      = 4;   // hard cap on new entries per calendar day
input int      MaxConsecutiveLosses = 2;   // after this many losses in a row, pause
input int      CooldownBarsH1       = 12;  // pause duration (H1 bars) after hitting loss streak
input double   ZoneProximityATRMult = 1.0; // block re-entry near a zone that just caused a loss
input int      ZoneCooldownBarsH1   = 24;  // how long (H1 bars) a losing zone stays blocked

input group "=== MISC ==="
input int      SpreadFilter     = 80;   // in points

CTrade         Trade;
CPositionInfo  PosInfo;

double         Point_val;
int            Digits_val;
bool           PartialDone      = false;
double         InitialVolume    = 0.0;
double         InitialSLDistance = 0.0;
double         LastTrailSL      = 0.0;
ulong          CurrentTicket    = 0;
ENUM_ORDER_TYPE_FILLING g_FillingMode      = ORDER_FILLING_FOK;
int                     g_FillingFallbacks = 0;

bool           g_TrailClampLogged = false;   // [FEAT-P0-012] chống spam log trailing-skip

int            hATR_H1;
int            hATR_M5;

datetime       g_CurrentDay        = 0;
int            g_TradesToday       = 0;
int            g_ConsecutiveLosses = 0;
datetime       g_CooldownUntilBarTime = 0;

double         g_OpenZoneTop    = 0.0;
double         g_OpenZoneBottom = 0.0;
bool           g_HasOpenZone    = false;

struct LossZone
{
   double   top;
   double   bottom;
   datetime blockedUntilBarTime;
};
#define MAX_LOSS_ZONES 10
LossZone g_LossZones[MAX_LOSS_ZONES];
int      g_LossZoneCount = 0;

struct OBZone
{
   int    ob_type;
   double top;
   double bottom;
   datetime time_found;
};

// === [FEAT-P1-008] Sweep result ===
struct SweepInfo
{
   bool     found;          // có sweep hợp lệ không
   int      sweep_bar;      // index nến sweep (series, 1 = nến vừa đóng)
   double   ref_level;      // mức thanh khoản bị quét (swing low/high cũ)
   double   sweep_extreme;  // low của sweep candle (bullish) / high (bearish)
   datetime sweep_time;     // thời điểm sweep (logging)
};

// === [FEAT-P1-009] FVG result ===
struct FVGZone
{
   bool     found;
   int      fvg_type;      // +1 bullish, -1 bearish
   double   top;
   double   bottom;
   double   ce;            // consequent encroachment = (top+bottom)/2
   double   gap_size;      // top - bottom
   int      bar_index;     // index nến C (mới nhất của cụm 3 nến), series
   datetime time_found;
};

struct CHoCHResult
{
   string choch_type;
   double smart_sl;
   bool   sweep_confirmed;  // [FEAT-P1-008]
   double sweep_level;      // [FEAT-P1-008]
   int    sweep_bar;        // [FEAT-P1-009] index nến sweep (-1 nếu UseSweepFilter=false)
   int    trigger_peak_idx; // [FEAT-P1-009] index swing bị phá
};

// === [FEAT-P1-010] HTF Bias result ===
struct HTFBiasInfo
{
   int      bias;            // +1 bullish, -1 bearish, 0 neutral
   int      swing_bias;      // thành phần swing (để log/debug)
   int      ema_bias;        // thành phần EMA (để log/debug)
   double   sh1, sh2;        // 2 swing high gần nhất (0 nếu không đủ)
   double   sl1, sl2;        // 2 swing low gần nhất
   datetime computed_bar;    // bar time HTF tại lần tính (cache key)
};

#define HTF_ATR_PERIOD 14
int         hATR_H4  = INVALID_HANDLE;
int         hATR_D1  = INVALID_HANDLE;
int         hEMA_H4  = INVALID_HANDLE;
int         hEMA_D1  = INVALID_HANDLE;
HTFBiasInfo g_BiasH4;
HTFBiasInfo g_BiasD1;
int         g_BiasCached = 0;

// === [FEAT-P1-011] Session window (đơn vị: phút-từ-nửa-đêm, server time) ===
struct SessionWindow
{
   bool   enabled;
   int    start_min;   // [0, 1440)
   int    end_min;     // [0, 1440); start_min == end_min -> vô hiệu
   string name;        // "LONDON_KZ" / "NY_KZ" / "CUSTOM" , cho logging
};

SessionWindow g_Windows[3];            // London, NewYork, Custom , resolve 1 lần trong OnInit
string        g_SessionState = "INIT"; // tên window đang active / "OFF" , key cho transition log


//+------------------------------------------------------------------+
int OnInit()
{
   Trade.SetExpertMagicNumber(MagicNumber);
   Trade.SetDeviationInPoints(30);
   
   g_FillingMode = ResolveFillingMode(_Symbol);
   Trade.SetTypeFilling(g_FillingMode);
   PrintFormat("[FEAT-P0-001] Filling mode selected: %s", EnumToString(g_FillingMode));

   Point_val  = _Point;
   Digits_val = _Digits;

   hATR_H1 = iATR(_Symbol, PERIOD_H1, OB_ATR_Period);
   hATR_M5 = iATR(_Symbol, PERIOD_M5, ATR_Period_M5);

   if(hATR_H1 == INVALID_HANDLE || hATR_M5 == INVALID_HANDLE)
   {
      Print("Init Failed: ATR handle error");
      return INIT_FAILED;
   }
   
   if(UseHTFBiasFilter)
   {
      bool use_h4 = (HTF_TF_Mode == HTF_TF_H4_ONLY || HTF_TF_Mode == HTF_TF_BOTH_AND || HTF_TF_Mode == HTF_TF_H4_PRIMARY);
      bool use_d1 = (HTF_TF_Mode == HTF_TF_D1_ONLY || HTF_TF_Mode == HTF_TF_BOTH_AND || HTF_TF_Mode == HTF_TF_H4_PRIMARY);
      bool use_ema = (HTF_Method == HTF_METHOD_EMA || HTF_Method == HTF_METHOD_BOTH);

      if(use_h4)
      {
         hATR_H4 = iATR(_Symbol, PERIOD_H4, HTF_ATR_PERIOD);
         if(hATR_H4 == INVALID_HANDLE) { Print("Init Failed: ATR H4 handle error"); return INIT_FAILED; }
         
         if(use_ema)
         {
            hEMA_H4 = iMA(_Symbol, PERIOD_H4, HTF_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
            if(hEMA_H4 == INVALID_HANDLE) { Print("Init Failed: EMA H4 handle error"); return INIT_FAILED; }
         }
      }
      
      if(use_d1)
      {
         hATR_D1 = iATR(_Symbol, PERIOD_D1, HTF_ATR_PERIOD);
         if(hATR_D1 == INVALID_HANDLE) { Print("Init Failed: ATR D1 handle error"); return INIT_FAILED; }
         
         if(use_ema)
         {
            hEMA_D1 = iMA(_Symbol, PERIOD_D1, HTF_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
            if(hEMA_D1 == INVALID_HANDLE) { Print("Init Failed: EMA D1 handle error"); return INIT_FAILED; }
         }
      }
      
      ZeroMemory(g_BiasH4);
      ZeroMemory(g_BiasD1);
   }

   if(UseSessionFilter)
   {
      if(!ResolveSessionWindows())
         Print("[FEAT-P1-011] WARNING: UseSessionFilter=true nhưng không có window hợp lệ , filter vô hiệu");
   }

   ZeroMemory(g_LossZones);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hATR_H1);
   IndicatorRelease(hATR_M5);
   
   if(hATR_H4 != INVALID_HANDLE) IndicatorRelease(hATR_H4);
   if(hATR_D1 != INVALID_HANDLE) IndicatorRelease(hATR_D1);
   if(hEMA_H4 != INVALID_HANDLE) IndicatorRelease(hEMA_H4);
   if(hEMA_D1 != INVALID_HANDLE) IndicatorRelease(hEMA_D1);
}

//+------------------------------------------------------------------+
bool IsMarketTradeable()
{
   long trade_mode = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(trade_mode == SYMBOL_TRADE_MODE_DISABLED || trade_mode == SYMBOL_TRADE_MODE_CLOSEONLY)
      return false;

   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   datetime from, to;
   if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, 0, from, to))
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| [FEAT-P1-011] Helper: SessionHourToMin                           |
//+------------------------------------------------------------------+
int SessionHourToMin(const double hour)
{
   int m = (int)MathRound(hour * 60.0);
   if(m < 0) m = 0;
   if(m > 1439) m = 1439;
   return m;
}

//+------------------------------------------------------------------+
//| [FEAT-P1-011] Convert input hours -> SessionWindow[] (phút)       |
//| Gọi 1 lần trong OnInit. Trả false nếu KHÔNG có window nào hợp lệ |
//+------------------------------------------------------------------+
bool ResolveSessionWindows()
{
   g_Windows[0].name = "LONDON_KZ";
   g_Windows[0].enabled = UseLondonKZ;
   g_Windows[1].name = "NY_KZ";
   g_Windows[1].enabled = UseNewYorkKZ;
   g_Windows[2].name = "CUSTOM";
   g_Windows[2].enabled = UseCustomSession;

   double starts[3] = {London_StartHour, NewYork_StartHour, Custom_StartHour};
   double ends[3]   = {London_EndHour, NewYork_EndHour, Custom_EndHour};

   int enabled_count = 0;
   int shortest_window = 1440;

   for(int i = 0; i < 3; i++)
   {
      if(!g_Windows[i].enabled) continue;

      if(starts[i] < 0.0 || starts[i] >= 24.0 || ends[i] < 0.0 || ends[i] >= 24.0)
      {
         PrintFormat("[FEAT-P1-011] WARNING: %s hours out of bounds [0, 24). Clamping applied.", g_Windows[i].name);
      }

      int s_min = SessionHourToMin(starts[i]);
      int e_min = SessionHourToMin(ends[i]);

      if(Session_TimeBase == TIMEBASE_GMT)
      {
         s_min = (s_min + Session_GMT_Offset * 60 + 1440) % 1440;
         e_min = (e_min + Session_GMT_Offset * 60 + 1440) % 1440;
      }

      g_Windows[i].start_min = s_min;
      g_Windows[i].end_min   = e_min;

      if(s_min == e_min)
      {
         PrintFormat("[FEAT-P1-011] WARNING: %s start == end. Disabling window.", g_Windows[i].name);
         g_Windows[i].enabled = false;
         continue;
      }

      int len = (e_min > s_min) ? (e_min - s_min) : (e_min - s_min + 1440);
      if(len < shortest_window) shortest_window = len;

      enabled_count++;
   }

   if(Session_NoEntryBeforeEndMin >= shortest_window && shortest_window != 1440)
   {
      PrintFormat("[FEAT-P1-011] WARNING: Session_NoEntryBeforeEndMin (%d) >= shortest window (%d). May block all entries.", Session_NoEntryBeforeEndMin, shortest_window);
   }

   PrintFormat("[FEAT-P1-011] Resolved Config | TimeBase: %s | Buffer: %d min | FriCutoff: %s (%.1f) | MonDelay: %s (%.1f)",
               EnumToString(Session_TimeBase), Session_NoEntryBeforeEndMin,
               UseFridayCutoff ? "ON" : "OFF", Friday_CutoffHour,
               UseMondayDelay ? "ON" : "OFF", Monday_OpenHour);

   for(int i=0; i<3; i++)
   {
      if(g_Windows[i].enabled)
         PrintFormat("[FEAT-P1-011] - %s: %02d:%02d to %02d:%02d (server time)",
                     g_Windows[i].name,
                     g_Windows[i].start_min / 60, g_Windows[i].start_min % 60,
                     g_Windows[i].end_min / 60, g_Windows[i].end_min % 60);
   }

   if(enabled_count == 0) return false;
   return true;
}

//+------------------------------------------------------------------+
//| [FEAT-P1-011] Kiểm tra thời điểm hiện tại có được entry mới không|
//| reason: OUT-param mô tả lý do chặn (logging). "" nếu được phép.  |
//+------------------------------------------------------------------+
bool IsInTradeSession(string &reason)
{
   reason = "";
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int cur_min = dt.hour * 60 + dt.min; // BỎ QUA dt.sec
   int active_idx = -1;

   // 1. Friday cutoff
   if(UseFridayCutoff && dt.day_of_week == 5 && cur_min >= (int)MathRound(Friday_CutoffHour * 60.0))
   {
      reason = "FRIDAY_CUTOFF";
   }
   // 2. Monday delay
   else if(UseMondayDelay && dt.day_of_week == 1 && cur_min < (int)MathRound(Monday_OpenHour * 60.0))
   {
      reason = "MONDAY_DELAY";
   }
   else
   {
      // 3. Kill-zone membership
      bool in_any = false;
      for(int i = 0; i < 3; i++)
      {
         if(!g_Windows[i].enabled) continue;
         int s = g_Windows[i].start_min;
         int e = g_Windows[i].end_min;
         bool inside = (s < e) ? (cur_min >= s && cur_min < e) : (cur_min >= s || cur_min < e);
         
         if(inside)
         {
            in_any = true;
            active_idx = i;
            break;
         }
      }

      if(!in_any)
      {
         reason = "OUTSIDE_KILLZONE";
      }
      else
      {
         // 4. End buffer
         if(Session_NoEntryBeforeEndMin > 0)
         {
            int e = g_Windows[active_idx].end_min;
            int min_to_end = (e - cur_min + 1440) % 1440;
            if(min_to_end < Session_NoEntryBeforeEndMin)
            {
               reason = g_Windows[active_idx].name + "_END_BUFFER";
            }
         }
      }
   }

   string current_state = (reason == "") ? g_Windows[active_idx].name : ("OFF:" + reason);

   if(current_state != g_SessionState)
   {
      if(reason == "")
         PrintFormat("[FEAT-P1-011] ENTER %s @ %02d:%02d server", g_Windows[active_idx].name, dt.hour, dt.min);
      else
         PrintFormat("[FEAT-P1-011] BLOCKED: %s @ %02d:%02d server", reason, dt.hour, dt.min);
      g_SessionState = current_state;
   }

   return (reason == "");
}


//+------------------------------------------------------------------+
bool IsZoneBlocked(double top, double bottom)
{
   datetime nowBar = iTime(_Symbol, PERIOD_H1, 0);
   double atr_h1[];
   ArraySetAsSeries(atr_h1, true);
   double proximity = 0;
   if(CopyBuffer(hATR_H1, 0, 0, 1, atr_h1) > 0)
      proximity = atr_h1[0] * ZoneProximityATRMult;

   int limit = MathMin(g_LossZoneCount, MAX_LOSS_ZONES);

   for(int i = 0; i < limit; i++)
   {
      if(g_LossZones[i].blockedUntilBarTime <= nowBar) continue;
      if(top >= g_LossZones[i].bottom - proximity && bottom <= g_LossZones[i].top + proximity)
         return true;
   }
   return false;
}

void RegisterLossZone(double top, double bottom)
{
   datetime nowBar = iTime(_Symbol, PERIOD_H1, 0);
   datetime blockUntil = nowBar + ZoneCooldownBarsH1 * PeriodSeconds(PERIOD_H1);

   int slot = g_LossZoneCount % MAX_LOSS_ZONES;
   g_LossZones[slot].top    = top;
   g_LossZones[slot].bottom = bottom;
   g_LossZones[slot].blockedUntilBarTime = blockUntil;
   g_LossZoneCount++;
}

//+------------------------------------------------------------------+
void UpdateDailyCounterIfNewDay()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime today = StructToTime(dt);

   if(today != g_CurrentDay)
   {
      g_CurrentDay  = today;
      g_TradesToday = 0;
   }
}

bool InCooldown()
{
   datetime nowBar = iTime(_Symbol, PERIOD_H1, 0);
   return (nowBar < g_CooldownUntilBarTime);
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     request,
                        const MqlTradeResult&      result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != MagicNumber) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   if(profit < 0)
   {
      g_ConsecutiveLosses++;
      if(g_HasOpenZone)
         RegisterLossZone(g_OpenZoneTop, g_OpenZoneBottom);

      if(g_ConsecutiveLosses >= MaxConsecutiveLosses)
      {
         datetime nowBar = iTime(_Symbol, PERIOD_H1, 0);
         g_CooldownUntilBarTime = nowBar + CooldownBarsH1 * PeriodSeconds(PERIOD_H1);
         g_ConsecutiveLosses = 0;
      }
   }
   else if(profit > 0)
   {
      g_ConsecutiveLosses = 0;
   }

   if(!HasOpenPosition())
   {
      g_HasOpenZone     = false;
      PartialDone       = false;
      InitialVolume     = 0.0;
      InitialSLDistance = 0.0;
      LastTrailSL       = 0.0;
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   UpdateDailyCounterIfNewDay();

   if(HasOpenPosition())
   {
      ManagePosition();
      return;
   }

   static datetime LastBarTime = 0;
   datetime CurrBarTime = iTime(_Symbol, PERIOD_M5, 0);
   if(CurrBarTime == LastBarTime) return;
   LastBarTime = CurrBarTime;

   if(!IsMarketTradeable())          return;
   if(InCooldown())                  return;
   if(g_TradesToday >= MaxTradesPerDay) return;

   double Ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double Bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double Spread = (Ask - Bid) / Point_val;

   if(Spread > SpreadFilter) return;

   // === [FEAT-P1-011] Session / Kill-zone gate ===
   if(UseSessionFilter)
   {
      string sess_reason;
      if(!IsInTradeSession(sess_reason)) return;   // log transition đã xử lý bên trong
   }
   // === end FEAT-P1-011 ===

   // === [FEAT-P1-010] HTF Bias update (cached per HTF bar) ===
   if(UseHTFBiasFilter)
   {
      if(!UpdateHTFBias()) return;   // thiếu dữ liệu HTF -> không giao dịch (fail-safe)
   }
   // === end FEAT-P1-010 (update) ===

   OBZone ob;
   if(!GetOB_H1(ob)) return;

   // === [FEAT-P1-010] Bias direction gate ===
   if(UseHTFBiasFilter && !CheckHTFBiasDirection(ob.ob_type))
   {
      PrintFormat("[FEAT-P1-010] Reject: OB %s ngược bias H4=%+d D1=%+d (cached=%+d)",
                  ob.ob_type == 1 ? "BULL" : "BEAR",
                  g_BiasH4.bias, g_BiasD1.bias, g_BiasCached);
      return;
   }
   // === end FEAT-P1-010 (gate) ===

   if(IsZoneBlocked(ob.top, ob.bottom)) return;

   CHoCHResult choch;
   if(!DetectCHoCH_M5(ob, choch)) return;

   // === [FEAT-P1-009] FVG confluence ===
   FVGZone fvg;
   if(UseFVGFilter)
   {
      if(!CheckFVGConfluence(ob, choch, fvg))
      {
         PrintFormat("[FEAT-P1-009] Reject: no valid FVG | OB %s [%.2f-%.2f]",
                     ob.ob_type == 1 ? "BULL" : "BEAR", ob.bottom, ob.top);
         return;
      }
      PrintFormat("[FEAT-P1-009] FVG %s [%.2f-%.2f] CE=%.2f gap=%.2f bar=%d",
                  fvg.fvg_type == 1 ? "BULL" : "BEAR",
                  fvg.bottom, fvg.top, fvg.ce, fvg.gap_size, fvg.bar_index);
   }
   // === end FEAT-P1-009 ===

   double entry, sl_price, tp_price;
   ENUM_ORDER_TYPE order_type;

   double atr_m5[];
   ArraySetAsSeries(atr_m5, true);
   double atr_val = 0;
   if(CopyBuffer(hATR_M5, 0, 0, 1, atr_m5) > 0) atr_val = atr_m5[0];
   double sl_buffer = atr_val * SL_Buffer_ATR_Mult;

   if(ob.ob_type == 1) // BULLISH
   {
      entry      = Ask;
      sl_price   = NormalizeDouble(choch.smart_sl - sl_buffer, Digits_val);
      double sl_dist  = entry - sl_price;
      if(sl_dist <= 0) return;

      // === [FEAT-P0-012] Clamp SL theo STOPS_LEVEL / FREEZE_LEVEL ===
      double min_stop = GetMinStopDistance();
      if(sl_dist < min_stop)
      {
         double old_sl = sl_price;
         sl_dist  = min_stop;
         sl_price = NormalizeDouble(entry - sl_dist, Digits_val);
         PrintFormat("[FEAT-P0-012] SL clamped: %.2f -> %.2f (min_stop=%.2f)",
                     old_sl, sl_price, min_stop);
      }
      // === end FEAT-P0-012 ===

      double min_tp   = NormalizeDouble(entry + sl_dist * MinRR, Digits_val);
      tp_price        = MathMax(ob.top, min_tp);
      order_type      = ORDER_TYPE_BUY;
   }
   else // BEARISH
   {
      entry      = Bid;
      sl_price   = NormalizeDouble(choch.smart_sl + sl_buffer, Digits_val);
      double sl_dist  = sl_price - entry;
      if(sl_dist <= 0) return;

      // === [FEAT-P0-012] Clamp SL theo STOPS_LEVEL / FREEZE_LEVEL ===
      double min_stop = GetMinStopDistance();
      if(sl_dist < min_stop)
      {
         double old_sl = sl_price;
         sl_dist  = min_stop;
         sl_price = NormalizeDouble(entry + sl_dist, Digits_val);
         PrintFormat("[FEAT-P0-012] SL clamped: %.2f -> %.2f (min_stop=%.2f)",
                     old_sl, sl_price, min_stop);
      }
      // === end FEAT-P0-012 ===

      double min_tp   = NormalizeDouble(entry - sl_dist * MinRR, Digits_val);
      tp_price        = MathMin(ob.bottom, min_tp);
      order_type      = ORDER_TYPE_SELL;
   }

   double sl_points = MathAbs(entry - sl_price) / Point_val;
   double tp_points = MathAbs(tp_price - entry) / Point_val;

   if(sl_points <= 0) return;
   double actual_rr = tp_points / sl_points;
   if(actual_rr < MinRR) return;

   double lot = CalcLotSize(sl_points);
   if(lot < 0.01) return;

   bool placed = false;
   if(order_type == ORDER_TYPE_BUY)
      placed = SafeOrderSend(ORDER_TYPE_BUY, lot, entry, sl_price, tp_price, "SMC Bot - BUY");
   else
      placed = SafeOrderSend(ORDER_TYPE_SELL, lot, entry, sl_price, tp_price, "SMC Bot - SELL");

   if(placed)
   {
      CurrentTicket     = Trade.ResultOrder();
      InitialVolume     = lot;
      InitialSLDistance = MathAbs(entry - sl_price);
      PartialDone       = false;
      LastTrailSL       = 0.0;

      g_OpenZoneTop    = ob.top;
      g_OpenZoneBottom = ob.bottom;
      g_HasOpenZone    = true;

      g_TradesToday++;

      if(choch.sweep_confirmed)
         PrintFormat("[FEAT-P1-008] Entry with sweep @ ref=%.*f, sweep_extreme=%.*f, bar_age=%d",
                     Digits_val, choch.sweep_level, Digits_val, choch.smart_sl, 0); 
   }
}

//+------------------------------------------------------------------+
bool GetOB_H1(OBZone &ob)
{
   int    bars    = OB_Lookback + 2;
   double atr_h1[];
   double high_h1[], low_h1[], open_h1[], close_h1[];

   ArraySetAsSeries(atr_h1,   true);
   ArraySetAsSeries(high_h1,  true);
   ArraySetAsSeries(low_h1,   true);
   ArraySetAsSeries(open_h1,  true);
   ArraySetAsSeries(close_h1, true);

   if(CopyBuffer(hATR_H1,  0, 0, bars, atr_h1)   < bars) return false;
   if(CopyHigh(_Symbol,  PERIOD_H1, 0, bars, high_h1)  < bars) return false;
   if(CopyLow(_Symbol,   PERIOD_H1, 0, bars, low_h1)   < bars) return false;
   if(CopyOpen(_Symbol,  PERIOD_H1, 0, bars, open_h1)  < bars) return false;
   if(CopyClose(_Symbol, PERIOD_H1, 0, bars, close_h1) < bars) return false;

   for(int i = 1; i < OB_Lookback - 1; i++)
   {
      if(atr_h1[i] <= 0) continue;
      double body_size = MathAbs(close_h1[i] - open_h1[i]);

      if(close_h1[i] > open_h1[i] && body_size > atr_h1[i] * OB_ATR_Mult)
      {
         if(close_h1[i+1] < open_h1[i+1])
         {
            double ob_top    = high_h1[i+1];
            double ob_bottom = low_h1[i+1];

            bool is_valid = true;
            for(int j = i; j >= 1; j--) {
               if(close_h1[j] < ob_bottom) { is_valid = false; break; }
            }

            if(is_valid)
            {
               ob.ob_type    = 1;
               ob.top        = ob_top;
               ob.bottom     = ob_bottom;
               ob.time_found = iTime(_Symbol, PERIOD_H1, i+1);
               return true;
            }
         }
      }

      if(close_h1[i] < open_h1[i] && body_size > atr_h1[i] * OB_ATR_Mult)
      {
         if(close_h1[i+1] > open_h1[i+1])
         {
            double ob_top    = high_h1[i+1];
            double ob_bottom = low_h1[i+1];

            bool is_valid = true;
            for(int j = i; j >= 1; j--) {
               if(close_h1[j] > ob_top) { is_valid = false; break; }
            }

            if(is_valid)
            {
               ob.ob_type    = -1;
               ob.top        = ob_top;
               ob.bottom     = ob_bottom;
               ob.time_found = iTime(_Symbol, PERIOD_H1, i+1);
               return true;
            }
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| [FEAT-P1-008] Liquidity Sweep Detection on M5                    |
//| direction: +1 = bullish sweep, -1 = bearish sweep                |
//| Trả về true nếu có sweep hợp lệ; fill đầy đủ struct `sweep`      |
//+------------------------------------------------------------------+
bool DetectLiquiditySweep_M5(const int direction,
                             const OBZone &ob,
                             const int trigger_peak_idx,
                             const double &high[],
                             const double &low[],
                             const double &close[],
                             const double atr_val,
                             SweepInfo &sweep)
{
   sweep.found = false;
   sweep.sweep_bar = -1;
   sweep.ref_level = 0;
   sweep.sweep_extreme = 0;
   sweep.sweep_time = 0;

   int window_end = MathMin(trigger_peak_idx - 1, Sweep_MaxAgeBars);
   double prom = atr_val * CHoCH_Prom_Mult;

   if(direction == 1) // Bullish
   {
      double ref_level = ob.bottom;
      for(int i = trigger_peak_idx + Peak_Distance; i < CHoCH_Lookback; i++)
      {
         if(IsTrough(low, i, Peak_Distance, prom))
         {
            ref_level = low[i];
            break;
         }
      }
      sweep.ref_level = ref_level;

      int deepest_bar = -1;
      double deepest_low = DBL_MAX;

      for(int i = 2; i <= window_end; i++)
      {
         if(i >= ArraySize(low) || i >= ArraySize(close)) continue;
         double pen = ref_level - low[i];
         if(pen >= atr_val * Sweep_MinPen_ATR_Mult && 
            pen <= atr_val * Sweep_MaxPen_ATR_Mult && 
            close[i] > ref_level)
         {
            if(low[i] < deepest_low)
            {
               deepest_low = low[i];
               deepest_bar = i;
            }
         }
      }

      for(int i = 2; i <= window_end; i++)
      {
         if(i >= ArraySize(close)) continue;
         if(close[i] < ref_level - atr_val * Sweep_MinPen_ATR_Mult) 
            return false;
      }

      if(deepest_bar >= 2)
      {
         sweep.found = true;
         sweep.sweep_bar = deepest_bar;
         sweep.sweep_extreme = deepest_low;
         sweep.sweep_time = iTime(_Symbol, PERIOD_M5, deepest_bar);
         return true;
      }
   }
   else if(direction == -1) // Bearish
   {
      double ref_level = ob.top;
      for(int i = trigger_peak_idx + Peak_Distance; i < CHoCH_Lookback; i++)
      {
         if(IsPeak(high, i, Peak_Distance, prom))
         {
            ref_level = high[i];
            break;
         }
      }
      sweep.ref_level = ref_level;

      int highest_bar = -1;
      double highest_high = -DBL_MAX;

      for(int i = 2; i <= window_end; i++)
      {
         if(i >= ArraySize(high) || i >= ArraySize(close)) continue;
         double pen = high[i] - ref_level;
         if(pen >= atr_val * Sweep_MinPen_ATR_Mult && 
            pen <= atr_val * Sweep_MaxPen_ATR_Mult && 
            close[i] < ref_level)
         {
            if(high[i] > highest_high)
            {
               highest_high = high[i];
               highest_bar = i;
            }
         }
      }

      for(int i = 2; i <= window_end; i++)
      {
         if(i >= ArraySize(close)) continue;
         if(close[i] > ref_level + atr_val * Sweep_MinPen_ATR_Mult) 
            return false;
      }

      if(highest_bar >= 2)
      {
         sweep.found = true;
         sweep.sweep_bar = highest_bar;
         sweep.sweep_extreme = highest_high;
         sweep.sweep_time = iTime(_Symbol, PERIOD_M5, highest_bar);
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| [FEAT-P1-009] Fair Value Gap Detection on M5                     |
//| direction: +1 = bullish FVG, -1 = bearish FVG                    |
//| max_bar: biên trên cửa sổ quét (= choch.trigger_peak_idx)        |
//| Arrays: series, đã copy đủ CHoCH_Lookback + 3 bars               |
//+------------------------------------------------------------------+
bool DetectFVG_M5(const int direction,
                  const int max_bar,
                  const double &high[],
                  const double &low[],
                  const double &open[],
                  const double &close[],
                  const double atr_val,
                  FVGZone &fvg)
{
   ZeroMemory(fvg); 
   fvg.found = false; 
   fvg.bar_index = -1;
   
   if(atr_val <= 0) return false;
   
   int window_end = MathMin(max_bar - 2, FVG_MaxAgeBars);
   double min_gap = atr_val * FVG_MinGapATRMult;
   double max_gap = atr_val * FVG_MaxGapATRMult;
   double disp    = atr_val * FVG_DispATRMult;
   
   for(int i = 1; i <= window_end; i++)
   {
      if(i + 2 >= ArraySize(high) || i + 2 >= ArraySize(low) || 
         i + 2 >= ArraySize(open) || i + 2 >= ArraySize(close)) continue;
         
      if(direction == 1) // Bullish
      {
         if(close[i+1] > open[i+1] && MathAbs(close[i+1] - open[i+1]) > disp)
         {
            if(low[i] > high[i+2])
            {
               double gap_top = low[i];
               double gap_bottom = high[i+2];
               double gap_size = gap_top - gap_bottom;
               
               if(gap_size >= min_gap && gap_size <= max_gap)
               {
                  bool is_mitigated = false;
                  if(FVG_RequireUnmitigated)
                  {
                     for(int j = i - 1; j >= 1; j--)
                     {
                        if(close[j] < gap_bottom)
                        {
                           is_mitigated = true;
                           break;
                        }
                     }
                  }
                  if(!is_mitigated)
                  {
                     fvg.found = true;
                     fvg.fvg_type = 1;
                     fvg.top = gap_top;
                     fvg.bottom = gap_bottom;
                     fvg.ce = (gap_top + gap_bottom) / 2.0;
                     fvg.gap_size = gap_size;
                     fvg.bar_index = i;
                     fvg.time_found = iTime(_Symbol, PERIOD_M5, i);
                     return true;
                  }
               }
            }
         }
      }
      else if(direction == -1) // Bearish
      {
         if(close[i+1] < open[i+1] && MathAbs(close[i+1] - open[i+1]) > disp)
         {
            if(high[i] < low[i+2])
            {
               double gap_top = low[i+2];
               double gap_bottom = high[i];
               double gap_size = gap_top - gap_bottom;
               
               if(gap_size >= min_gap && gap_size <= max_gap)
               {
                  bool is_mitigated = false;
                  if(FVG_RequireUnmitigated)
                  {
                     for(int j = i - 1; j >= 1; j--)
                     {
                        if(close[j] > gap_top)
                        {
                           is_mitigated = true;
                           break;
                        }
                     }
                  }
                  if(!is_mitigated)
                  {
                     fvg.found = true;
                     fvg.fvg_type = -1;
                     fvg.top = gap_top;
                     fvg.bottom = gap_bottom;
                     fvg.ce = (gap_top + gap_bottom) / 2.0;
                     fvg.gap_size = gap_size;
                     fvg.bar_index = i;
                     fvg.time_found = iTime(_Symbol, PERIOD_M5, i);
                     return true;
                  }
               }
            }
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| [FEAT-P1-009] Orchestrator: copy M5 arrays + gọi DetectFVG_M5    |
//| Gọi SAU DetectCHoCH_M5 thành công, TRƯỚC khi tính SL/TP          |
//+------------------------------------------------------------------+
bool CheckFVGConfluence(const OBZone &ob, const CHoCHResult &choch, FVGZone &fvg)
{
   int bars = CHoCH_Lookback + 3;
   double high_m5[], low_m5[], open_m5[], close_m5[], atr_m5[];
   
   ArraySetAsSeries(high_m5, true);
   ArraySetAsSeries(low_m5, true);
   ArraySetAsSeries(open_m5, true);
   ArraySetAsSeries(close_m5, true);
   ArraySetAsSeries(atr_m5, true);
   
   if(CopyHigh(_Symbol, PERIOD_M5, 0, bars, high_m5) < bars) return false;
   if(CopyLow(_Symbol, PERIOD_M5, 0, bars, low_m5) < bars) return false;
   if(CopyOpen(_Symbol, PERIOD_M5, 0, bars, open_m5) < bars) return false;
   if(CopyClose(_Symbol, PERIOD_M5, 0, bars, close_m5) < bars) return false;
   if(CopyBuffer(hATR_M5, 0, 0, 2, atr_m5) < 2) return false;
   
   double atr_val = atr_m5[1];
   if(atr_val <= 0) return false;
   
   if(!DetectFVG_M5(ob.ob_type, choch.trigger_peak_idx, high_m5, low_m5, open_m5, close_m5, atr_val, fvg))
      return false;
      
   if(FVG_MustOverlapOB && fvg.found)
   {
      if(ob.ob_type == 1) // Bullish
      {
         if(fvg.bottom > ob.top) 
         {
            fvg.found = false;
            return false;
         }
      }
      else if(ob.ob_type == -1) // Bearish
      {
         if(fvg.top < ob.bottom)
         {
            fvg.found = false;
            return false;
         }
      }
   }
   
   return true;
}

//+------------------------------------------------------------------+
bool DetectCHoCH_M5(const OBZone &ob, CHoCHResult &result)
{
   int bars = CHoCH_Lookback + 3;
   double atr_m5[];
   double high_m5[], low_m5[], close_m5[];

   ArraySetAsSeries(atr_m5,   true);
   ArraySetAsSeries(high_m5,  true);
   ArraySetAsSeries(low_m5,   true);
   ArraySetAsSeries(close_m5, true);

   if(CopyBuffer(hATR_M5,  0, 0, bars, atr_m5)   < bars) return false;
   if(CopyHigh(_Symbol,  PERIOD_M5, 0, bars, high_m5)  < bars) return false;
   if(CopyLow(_Symbol,   PERIOD_M5, 0, bars, low_m5)   < bars) return false;
   if(CopyClose(_Symbol, PERIOD_M5, 0, bars, close_m5) < bars) return false;

   double atr_val = atr_m5[1];
   if(atr_val <= 0) return false;

   if(ob.ob_type == 1)
   {
      bool has_touch = false;
      for(int i = 1; i < CHoCH_Lookback; i++)
      {
         if(low_m5[i] <= ob.top && low_m5[i] >= ob.bottom)
         {
            has_touch = true;
            break;
         }
      }
      if(!has_touch) return false;

      int    last_peak_idx   = -1;
      double last_swing_high = 0;
      double prominence      = atr_val * CHoCH_Prom_Mult;

      for(int i = Peak_Distance; i < CHoCH_Lookback - Peak_Distance; i++)
      {
         if(IsPeak(high_m5, i, Peak_Distance, prominence))
         {
            last_peak_idx   = i;
            last_swing_high = high_m5[i];
            break;
         }
      }

      if(last_peak_idx < 0) return false;

      if(close_m5[1] > last_swing_high && close_m5[2] <= last_swing_high)
      {
         result.trigger_peak_idx = last_peak_idx;
         if(UseSweepFilter)
         {
            SweepInfo sweep;
            if(!DetectLiquiditySweep_M5(1, ob, last_peak_idx, high_m5, low_m5, close_m5, atr_val, sweep)) 
               return false;
               
            result.smart_sl = sweep.sweep_extreme;
            result.sweep_confirmed = true;
            result.sweep_level = sweep.ref_level;
            result.sweep_bar = sweep.sweep_bar;
         }
         else
         {
            double lowest_low = low_m5[last_peak_idx];
            for(int i = 1; i <= last_peak_idx; i++)
               if(low_m5[i] < lowest_low) lowest_low = low_m5[i];
               
            result.smart_sl = lowest_low;
            result.sweep_confirmed = false;
            result.sweep_level = 0.0;
            result.sweep_bar = -1;
         }

         if(result.smart_sl > ob.top) return false;

         result.choch_type = "Bullish CHoCH";
         return true;
      }
   }
   else if(ob.ob_type == -1)
   {
      bool has_touch = false;
      for(int i = 1; i < CHoCH_Lookback; i++)
      {
         if(high_m5[i] >= ob.bottom && high_m5[i] <= ob.top)
         {
            has_touch = true;
            break;
         }
      }
      if(!has_touch) return false;

      int    last_trough_idx = -1;
      double last_swing_low  = DBL_MAX;
      double prominence      = atr_val * CHoCH_Prom_Mult;

      for(int i = Peak_Distance; i < CHoCH_Lookback - Peak_Distance; i++)
      {
         if(IsTrough(low_m5, i, Peak_Distance, prominence))
         {
            last_trough_idx = i;
            last_swing_low  = low_m5[i];
            break;
         }
      }

      if(last_trough_idx < 0) return false;

      if(close_m5[1] < last_swing_low && close_m5[2] >= last_swing_low)
      {
         result.trigger_peak_idx = last_trough_idx;
         if(UseSweepFilter)
         {
            SweepInfo sweep;
            if(!DetectLiquiditySweep_M5(-1, ob, last_trough_idx, high_m5, low_m5, close_m5, atr_val, sweep)) 
               return false;
               
            result.smart_sl = sweep.sweep_extreme;
            result.sweep_confirmed = true;
            result.sweep_level = sweep.ref_level;
            result.sweep_bar = sweep.sweep_bar;
         }
         else
         {
            double highest_high = high_m5[last_trough_idx];
            for(int i = 1; i <= last_trough_idx; i++)
               if(high_m5[i] > highest_high) highest_high = high_m5[i];
               
            result.smart_sl = highest_high;
            result.sweep_confirmed = false;
            result.sweep_level = 0.0;
            result.sweep_bar = -1;
         }

         if(result.smart_sl < ob.bottom) return false;

         result.choch_type = "Bearish CHoCH";
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
bool IsPeak(const double &high[], int idx, int dist, double prominence)
{
   double center = high[idx];
   for(int d = 1; d <= dist; d++)
   {
      if(idx - d < 0 || idx + d >= ArraySize(high)) return false;
      if(high[idx-d] >= center) return false;
      if(high[idx+d] >= center) return false;
   }
   double left_min  = center, right_min = center;
   for(int d = 1; d <= dist * 2; d++)
   {
      if(idx + d < ArraySize(high)) left_min  = MathMin(left_min,  high[idx+d]);
      if(idx - d >= 0)              right_min = MathMin(right_min, high[idx-d]);
   }
   return (center - MathMax(left_min, right_min)) >= prominence;
}

//+------------------------------------------------------------------+
bool IsTrough(const double &low[], int idx, int dist, double prominence)
{
   double center = low[idx];
   for(int d = 1; d <= dist; d++)
   {
      if(idx - d < 0 || idx + d >= ArraySize(low)) return false;
      if(low[idx-d] <= center) return false;
      if(low[idx+d] <= center) return false;
   }
   double left_max  = center, right_max = center;
   for(int d = 1; d <= dist * 2; d++)
   {
      if(idx + d < ArraySize(low)) left_max  = MathMax(left_max,  low[idx+d]);
      if(idx - d >= 0)             right_max = MathMax(right_max, low[idx-d]);
   }
   return (MathMin(left_max, right_max) - center) >= prominence;
}

//+------------------------------------------------------------------+
//| [FEAT-P1-010] Tính bias cho 1 khung thời gian (H4 hoặc D1)       |
//| Tự cache theo computed_bar; chỉ recompute khi có nến TF mới      |
//+------------------------------------------------------------------+
bool ComputeTFBias(const ENUM_TIMEFRAMES tf,
                   const int atr_handle,
                   const int ema_handle,
                   HTFBiasInfo &info)
{
   datetime tf_bar = iTime(_Symbol, tf, 0);
   if(info.computed_bar == tf_bar) return true;

   int old_bias = info.bias;
   
   info.bias = 0;
   info.swing_bias = 0;
   info.ema_bias = 0;
   info.sh1 = 0; info.sh2 = 0;
   info.sl1 = 0; info.sl2 = 0;
   
   int bars = HTF_Lookback + HTF_SwingDistance + 3;
   
   double high_arr[], low_arr[], close_arr[];
   ArraySetAsSeries(high_arr, true);
   ArraySetAsSeries(low_arr, true);
   ArraySetAsSeries(close_arr, true);
   
   if(CopyHigh(_Symbol, tf, 0, bars, high_arr) < bars) return false;
   if(CopyLow(_Symbol, tf, 0, bars, low_arr) < bars) return false;
   if(CopyClose(_Symbol, tf, 0, bars, close_arr) < bars) return false;
   
   double atr_ref = 0;
   bool need_swing = (HTF_Method == HTF_METHOD_SWING || HTF_Method == HTF_METHOD_BOTH);
   bool need_ema = (HTF_Method == HTF_METHOD_EMA || HTF_Method == HTF_METHOD_BOTH);

   if(atr_handle != INVALID_HANDLE)
   {
      double atr_arr[];
      ArraySetAsSeries(atr_arr, true);
      if(CopyBuffer(atr_handle, 0, 0, HTF_SwingDistance + 2, atr_arr) >= HTF_SwingDistance + 2)
      {
         atr_ref = atr_arr[HTF_SwingDistance + 1];
      }
   }

   if(need_swing)
   {
      if(atr_handle == INVALID_HANDLE || atr_ref <= 0) return false;
      
      double prom = atr_ref * HTF_PromMult;
      
      int p_count = 0;
      for(int i = HTF_SwingDistance + 1; i < bars - HTF_SwingDistance; i++)
      {
         if(IsPeak(high_arr, i, HTF_SwingDistance, prom))
         {
            if(p_count == 0) { info.sh1 = high_arr[i]; p_count++; }
            else if(p_count == 1) { info.sh2 = high_arr[i]; p_count++; break; }
         }
      }
      
      int t_count = 0;
      for(int i = HTF_SwingDistance + 1; i < bars - HTF_SwingDistance; i++)
      {
         if(IsTrough(low_arr, i, HTF_SwingDistance, prom))
         {
            if(t_count == 0) { info.sl1 = low_arr[i]; t_count++; }
            else if(t_count == 1) { info.sl2 = low_arr[i]; t_count++; break; }
         }
      }
      
      if(p_count == 2 && t_count == 2)
      {
         if(info.sh1 > info.sh2 && info.sl1 > info.sl2) info.swing_bias = 1;
         else if(info.sh1 < info.sh2 && info.sl1 < info.sl2) info.swing_bias = -1;
      }
   }
   
   if(need_ema)
   {
      if(ema_handle == INVALID_HANDLE) return false;
      double ema_arr[];
      ArraySetAsSeries(ema_arr, true);
      if(CopyBuffer(ema_handle, 0, 0, 3, ema_arr) < 3) return false;
      
      if(atr_ref <= 0) return false; 
      
      bool flat = (MathAbs(ema_arr[1] - ema_arr[2]) <= atr_ref * HTF_EMAFlatATRMult);
      if(!flat)
      {
         if(close_arr[1] > ema_arr[1] && ema_arr[1] > ema_arr[2]) info.ema_bias = 1;
         else if(close_arr[1] < ema_arr[1] && ema_arr[1] < ema_arr[2]) info.ema_bias = -1;
      }
   }
   
   if(HTF_Method == HTF_METHOD_SWING) info.bias = info.swing_bias;
   else if(HTF_Method == HTF_METHOD_EMA) info.bias = info.ema_bias;
   else if(HTF_Method == HTF_METHOD_BOTH)
   {
      if(info.swing_bias == info.ema_bias) info.bias = info.swing_bias;
      else info.bias = 0;
   }
   
   if(info.bias != old_bias)
   {
      PrintFormat("[FEAT-P1-010] Bias flip TF %s: %d -> %d | sh1=%.2f sh2=%.2f sl1=%.2f sl2=%.2f",
                  EnumToString(tf), old_bias, info.bias, info.sh1, info.sh2, info.sl1, info.sl2);
   }
   
   info.computed_bar = tf_bar;
   return true;
}

//+------------------------------------------------------------------+
//| [FEAT-P1-010] Cập nhật bias tổng hợp theo HTF_TF_Mode            |
//| Gọi 1 lần mỗi nến M5 mới trong OnTick, TRƯỚC GetOB_H1            |
//+------------------------------------------------------------------+
bool UpdateHTFBias()
{
   bool use_h4 = (HTF_TF_Mode == HTF_TF_H4_ONLY || HTF_TF_Mode == HTF_TF_BOTH_AND || HTF_TF_Mode == HTF_TF_H4_PRIMARY);
   bool use_d1 = (HTF_TF_Mode == HTF_TF_D1_ONLY || HTF_TF_Mode == HTF_TF_BOTH_AND || HTF_TF_Mode == HTF_TF_H4_PRIMARY);

   if(use_h4)
   {
      if(!ComputeTFBias(PERIOD_H4, hATR_H4, hEMA_H4, g_BiasH4)) return false;
   }
   if(use_d1)
   {
      if(!ComputeTFBias(PERIOD_D1, hATR_D1, hEMA_D1, g_BiasD1)) return false;
   }

   if(HTF_TF_Mode == HTF_TF_H4_ONLY)
      g_BiasCached = g_BiasH4.bias;
   else if(HTF_TF_Mode == HTF_TF_D1_ONLY)
      g_BiasCached = g_BiasD1.bias;
   else if(HTF_TF_Mode == HTF_TF_BOTH_AND)
   {
      if(g_BiasH4.bias == g_BiasD1.bias && g_BiasH4.bias != 0)
         g_BiasCached = g_BiasH4.bias;
      else
         g_BiasCached = 0;
   }
   else if(HTF_TF_Mode == HTF_TF_H4_PRIMARY)
   {
      if(g_BiasH4.bias != 0)
         g_BiasCached = g_BiasH4.bias;
      else
         g_BiasCached = g_BiasD1.bias;
   }

   return true;
}

//+------------------------------------------------------------------+
//| [FEAT-P1-010] Kiểm tra hướng setup có khớp bias không            |
//+------------------------------------------------------------------+
bool CheckHTFBiasDirection(const int setup_direction)
{
   if(g_BiasCached == 0) return (HTF_NeutralPolicy == NEUTRAL_ALLOW_ALL);
   return (setup_direction == g_BiasCached);
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(PosInfo.SelectByIndex(i))
      {
         if(PosInfo.Symbol() == _Symbol && PosInfo.Magic() == MagicNumber)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
bool GetOpenPosition(ulong &ticket, double &open_price, double &current_sl,
                     double &tp, double &volume, ENUM_POSITION_TYPE &pos_type)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(PosInfo.SelectByIndex(i))
      {
         if(PosInfo.Symbol() == _Symbol && PosInfo.Magic() == MagicNumber)
         {
            ticket      = PosInfo.Ticket();
            open_price  = PosInfo.PriceOpen();
            current_sl  = PosInfo.StopLoss();
            tp          = PosInfo.TakeProfit();
            volume      = PosInfo.Volume();
            pos_type    = PosInfo.PositionType();
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
void ManagePosition()
{
   ulong                ticket;
   double               open_price, current_sl, tp, volume;
   ENUM_POSITION_TYPE   pos_type;

   if(!GetOpenPosition(ticket, open_price, current_sl, tp, volume, pos_type))
      return;

   if(InitialVolume == 0.0) InitialVolume = volume;
   if(InitialSLDistance <= 0.0)
   {
      if(current_sl > 0) InitialSLDistance = MathAbs(open_price - current_sl);
      else return;
   }

   if(!IsMarketTradeable()) return;

   double Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double profit_price   = (pos_type == POSITION_TYPE_BUY) ? (Bid - open_price) : (open_price - Ask);
   double profit_R        = profit_price / InitialSLDistance;

   if(!PartialDone && profit_R >= PartialAtR)
   {
      double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double lot_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

      double lot_to_close = MathFloor((volume * PartialClosePct) / lot_step) * lot_step;
      double remaining = volume - lot_to_close;

      if(lot_to_close >= lot_min && remaining >= lot_min)
      {
         if(Trade.PositionClosePartial(ticket, lot_to_close))
         {
            PartialDone = true;
         }
         else if(Trade.ResultRetcode() == TRADE_RETCODE_INVALID_FILL)
         {
            if(FallbackFillingMode())
            {
               if(Trade.PositionClosePartial(ticket, lot_to_close))
               {
                  PartialDone = true;
               }
               else
               {
                  PrintFormat("[FEAT-P0-001] Retry partial close failed, retcode: %d, comment: %s", Trade.ResultRetcode(), Trade.ResultComment());
               }
            }
            else
            {
               PrintFormat("[FEAT-P0-001] FATAL: All filling modes failed for partial close");
            }
         }
         else
         {
            PrintFormat("[FEAT-P0-001] PositionClosePartial failed, retcode: %d, comment: %s", Trade.ResultRetcode(), Trade.ResultComment());
         }
      }
      else
      {
         PartialDone = true;
      }
   }

   if(profit_R >= TrailingStartR)
   {
      if(!GetOpenPosition(ticket, open_price, current_sl, tp, volume, pos_type))
         return;

      double trail_distance_price = InitialSLDistance * TrailingStepR;
      double buffer_price         = InitialSLDistance * TrailingBufferR;
      double new_sl = 0;
      bool   should_modify = false;

      if(pos_type == POSITION_TYPE_BUY)
      {
         new_sl = NormalizeDouble(Bid - trail_distance_price, Digits_val);
         if(current_sl == 0 || new_sl > current_sl + buffer_price)
            should_modify = true;
      }
      else if(pos_type == POSITION_TYPE_SELL)
      {
         new_sl = NormalizeDouble(Ask + trail_distance_price, Digits_val);
         if(current_sl == 0 || new_sl < current_sl - buffer_price)
            should_modify = true;
      }

      // === [FEAT-P0-012] Trailing SL phải tôn trọng STOPS_LEVEL ===
      if(should_modify)
      {
         double min_stop_t = GetMinStopDistance();
         bool   sl_valid    = true;
         if(pos_type == POSITION_TYPE_BUY)
            sl_valid = (new_sl <= NormalizeDouble(Bid - min_stop_t, Digits_val));
         else
            sl_valid = (new_sl >= NormalizeDouble(Ask + min_stop_t, Digits_val));

         if(!sl_valid)
         {
            if(!g_TrailClampLogged)
            {
               PrintFormat("[FEAT-P0-012] Trailing skip: new_sl=%.2f vi phạm min_stop=%.2f — thử lại tick sau",
                           new_sl, min_stop_t);
               g_TrailClampLogged = true;
            }
            return;   // skip lần modify này — KHÔNG đẩy SL lùi (giữ kỷ luật R-multiple)
         }
         g_TrailClampLogged = false;
      }
      // === end FEAT-P0-012 ===

      if(should_modify && MathAbs(new_sl - LastTrailSL) > Point_val)
      {
         if(Trade.PositionModify(ticket, new_sl, tp))
            LastTrailSL = new_sl;
      }
   }
}

//+------------------------------------------------------------------+
//| [FEAT-P0-012] Khoảng cách tối thiểu hợp lệ từ giá thị trường     |
//| tới SL/TP (đơn vị GIÁ). Đọc động mỗi lần gọi — broker có thể     |
//| thay STOPS_LEVEL intraday. Bao gồm sàn động theo spread hiện tại |
//+------------------------------------------------------------------+
double GetMinStopDistance()
{
   long stops_pts  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze_pts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double static_min = MathMax((double)stops_pts, (double)freeze_pts) * Point_val;

   double spread = 0;
   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick)) spread = tick.ask - tick.bid;   // fail → spread = 0 (fallback an toàn)
   double dynamic_min = STOPS_SPREAD_MULT * spread;

   return MathMax(static_min, dynamic_min) + STOPS_SAFETY_POINTS * Point_val;
}

//+------------------------------------------------------------------+
double CalcLotSize(double sl_points)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amt   = balance * (RiskPercent / 100.0);
   double tick_val   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double value_per_point = tick_val / (tick_size / Point_val);

   if(value_per_point <= 0 || sl_points <= 0) return 0.01;

   double lot = risk_amt / (sl_points * value_per_point);

   double lot_min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lot_max  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / lot_step) * lot_step;
   return MathMax(lot_min, MathMin(lot_max, lot));
}

//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING ResolveFillingMode(const string symbol)
{
   long mask = SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   long exemode = SymbolInfoInteger(symbol, SYMBOL_TRADE_EXEMODE);
   if((mask & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((mask & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   if(exemode == SYMBOL_TRADE_EXECUTION_EXCHANGE || exemode == SYMBOL_TRADE_EXECUTION_REQUEST || exemode == SYMBOL_TRADE_EXECUTION_INSTANT) return ORDER_FILLING_RETURN;
   return ORDER_FILLING_FOK;
}

//+------------------------------------------------------------------+
bool FallbackFillingMode()
{
   if(g_FillingMode == ORDER_FILLING_FOK)
      g_FillingMode = ORDER_FILLING_IOC;
   else if(g_FillingMode == ORDER_FILLING_IOC)
      g_FillingMode = ORDER_FILLING_RETURN;
   else
      return false;

   g_FillingFallbacks++;
   Trade.SetTypeFilling(g_FillingMode);
   PrintFormat("[FEAT-P0-001] Fallback filling mode selected: %s", EnumToString(g_FillingMode));
   return true;
}

//+------------------------------------------------------------------+
bool SafeOrderSend(const ENUM_ORDER_TYPE type, const double lot,
                   const double price, const double sl, const double tp,
                   const string comment)
{
   int MAX_RETRY = 2;
   for(int i = 0; i <= MAX_RETRY; i++)
   {
      bool placed = false;
      if(type == ORDER_TYPE_BUY)
         placed = Trade.Buy(lot, _Symbol, price, sl, tp, comment);
      else
         placed = Trade.Sell(lot, _Symbol, price, sl, tp, comment);

      uint retcode = Trade.ResultRetcode();
      if(placed && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED))
         return true;

      if(retcode == TRADE_RETCODE_INVALID_FILL)
      {
         if(!FallbackFillingMode())
         {
            PrintFormat("[FEAT-P0-001] FATAL: All filling modes failed for retcode 10030");
            return false;
         }
         continue;
      }

      PrintFormat("[FEAT-P0-001] Order failed with retcode: %d, comment: %s", retcode, Trade.ResultComment());
      return false;
   }
   return false;
}

// [FEAT-P0-001] Auto Filling Mode Detection: FOK->IOC->RETURN, runtime fallback on retcode 10030
//+------------------------------------------------------------------+
//| CHANGE LOG                                                       |
//| [FEAT-P1-008] 2026-07-24: Liquidity Sweep Detection , thêm input |
//| group SWEEP, struct SweepInfo, hàm DetectLiquiditySweep_M5,      |
//| tích hợp filter + Smart SL theo sweep_extreme vào DetectCHoCH_M5 |
//| [FEAT-P1-009] 2026-07-24: FVG (Fair Value Gap) Detection, thêm   |
//| input group FVG, struct FVGZone, mở rộng CHoCHResult (+sweep_bar,|
//| +trigger_peak_idx), hàm DetectFVG_M5 + CheckFVGConfluence, gate  |
//| confluence sau CHoCH trong OnTick (Phase 1: filter mode).        |
//| [FEAT-P1-010] 2026-07-26: HTF Bias Filter (H4/D1), swing structure|
//| (tái dùng IsPeak/IsTrough) + EMA, 4 chế độ đa khung, neutral policy,|
//| cache bias theo nến HTF, gate hướng sau GetOB_H1 trong OnTick.   |
//| [FEAT-P1-011] 2026-07-26: Session/Kill-zone Filter , London KZ + |
//| NY KZ (default giờ server broker GMT+2/+3), custom window hỗ trợ |
//| qua nửa đêm, Friday cutoff, Monday delay, end-buffer chặn entry  |
//| cuối session, time base SERVER/GMT, log theo transition.         |
//| [FEAT-P0-012] 2026-07-26: Stops Level Clamp — GetMinStopDistance()|
//| đọc động STOPS_LEVEL/FREEZE_LEVEL + sàn 2x spread, clamp SL entry|
//| (TP/RR/Lot tự tính lại trên sl_dist mới), guard skip trailing    |
//| modify khi vi phạm min distance / vùng FREEZE. Hoàn thành debt P0.|
//+------------------------------------------------------------------+