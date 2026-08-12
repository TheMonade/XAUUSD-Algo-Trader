//+------------------------------------------------------------------+
//|                                          XAU_Donchian_Trader.mq5 |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#property tester_file "news_XAUUSD_sample.csv"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Indicators\Indicators.mqh>

// === [FEAT-P0-012] Stops Level Clamp , hang so ky thuat, KHONG phai tham so chien luoc ===
#define STOPS_SAFETY_POINTS   2     // buffer chong gia dich giua luc tinh va luc lenh toi server
#define STOPS_SPREAD_MULT     2.0   // san dong = mult * spread hien tai (cho broker bao STOPS_LEVEL=0)

enum ENUM_HTF_TF_MODE
{
   HTF_TF_H4_ONLY    = 0,   // Chi dung H4
   HTF_TF_D1_ONLY    = 1,   // Chi dung D1
   HTF_TF_BOTH_AND   = 2,   // H4 va D1 phai dong thuan
   HTF_TF_H4_PRIMARY = 3    // H4 chinh, D1 fallback khi H4 neutral
};

enum ENUM_HTF_METHOD
{
   HTF_METHOD_SWING = 0,    // Cau truc swing HH/HL (chuan SMC)
   HTF_METHOD_EMA   = 1,    // Gia vs EMA + slope
   HTF_METHOD_BOTH  = 2     // Ca hai dong thuan moi dinh huong
};

enum ENUM_HTF_NEUTRAL
{
   NEUTRAL_ALLOW_ALL = 0,   // Neutral: van cho vao lenh ca 2 chieu
   NEUTRAL_BLOCK_ALL = 1    // Neutral: chan moi entry moi
};

enum ENUM_SESSION_TIMEBASE
{
   TIMEBASE_SERVER = 0,   // Gio nhap = gio server broker (khuyen nghi cho broker GMT+2/+3)
   TIMEBASE_GMT    = 1    // Gio nhap = GMT, quy doi qua Session_GMT_Offset
};

enum ENUM_TRAIL_MODE
{
   TRAIL_CHANDELIER = 0,
   TRAIL_R_MULTIPLE = 1
};

input group "=== TRADE SETTINGS ==="
input double   RiskPercent      = 1.0;
input int      MagicNumber      = 202406;

input group "=== DONCHIAN CORE [FEAT-S2-001] ==="
input int              DC_Period         = 20;
input double           DC_SL_ATR_Mult    = 2.5;
input double           DC_Trail_ATR_Mult = 3.0;
input ENUM_TRAIL_MODE  TrailMode         = TRAIL_CHANDELIER;
input bool             UsePartialClose   = true;
input bool             UseLossZoneFilter = true;

input group "=== SL BUFFER (ATR-based) ==="
input int      ATR_Period_H1    = 14;
input double   SL_Buffer_ATR_Mult = 0.5;   // buffer = this * H1 ATR

input group "=== HTF BIAS FILTER (H4/D1) [FEAT-P1-010] ==="
input bool                 UseHTFBiasFilter     = false;             // bat/tat bias filter (A/B test)
input ENUM_HTF_TF_MODE     HTF_TF_Mode          = HTF_TF_H4_ONLY;   // khung bias: H4 / D1 / ket hop
input ENUM_HTF_METHOD      HTF_Method           = HTF_METHOD_SWING; // phuong phap: swing / EMA / both
input ENUM_HTF_NEUTRAL     HTF_NeutralPolicy    = NEUTRAL_ALLOW_ALL;// hanh vi khi bias = neutral
input int                  HTF_Lookback         = 120;              // so nen HTF quet swing
input int                  HTF_SwingDistance    = 3;                // distance xac nhan swing (2 ben)
input double               HTF_PromMult         = 0.5;              // prominence = mult * ATR(TF)
input int                  HTF_EMA_Period       = 50;               // chu ky EMA (method EMA/BOTH)
input double               HTF_EMAFlatATRMult   = 0.05;             // |slope| <= mult*ATR => EMA phang => neutral

input group "=== SESSION / KILL-ZONE FILTER [FEAT-P1-011] ==="
input bool                  UseSessionFilter      = false;             // bat/tat session filter (A/B test)
input ENUM_SESSION_TIMEBASE Session_TimeBase      = TIMEBASE_SERVER;  // gio nhap theo server hay GMT
input int                   Session_GMT_Offset    = 2;                // offset broker vs GMT (chi dung khi TIMEBASE_GMT)
input bool                  UseLondonKZ           = true;             // London Kill-zone
input double                London_StartHour      = 9.0;              // 9.0 = 09:00 server = 07:00 GMT (broker GMT+2/+3)
input double                London_EndHour        = 12.0;             // ho tro le: 12.5 = 12:30
input bool                  UseNewYorkKZ          = true;             // New York Kill-zone
input double                NewYork_StartHour     = 14.0;             // 14:00 server = 12:00 GMT
input double                NewYork_EndHour       = 17.0;
input bool                  UseCustomSession      = false;            // window tuy chinh (Asia/thi nghiem), ho tro qua nua dem
input double                Custom_StartHour      = 2.0;
input double                Custom_EndHour        = 7.0;
input int                   Session_NoEntryBeforeEndMin = 15;         // chan entry trong N phut cuoi window (0 = tat)
input bool                  UseFridayCutoff       = true;             // chan entry cuoi ngay thu 6
input double                Friday_CutoffHour     = 20.0;             // sau gio nay thu 6 khong entry moi
input bool                  UseMondayDelay        = false;            // chan entry dau ngay thu 2
input double                Monday_OpenHour       = 1.0;              // truoc gio nay thu 2 khong entry moi

input group "=== NEWS FILTER [FEAT-P1-020] ==="
input bool     UseNewsFilter        = true;  // bat/tat news filter (A/B test) - DEFAULT OFF de lay baseline
input int      News_BlockBeforeMin  = 30;     // chan entry N phut TRUOC tin
input int      News_BlockAfterMin   = 30;     // chan entry N phut SAU tin
input int      News_MinImpact       = 3;      // nguong impact: 1=Low, 2=Medium, 3=High
input string   News_Currencies      = "USD";  // danh sach currency, phan cach dau phay, VD "USD,EUR"
input string   News_CsvFile         = "";     // ten file CSV trong MQL5\Files; rong = tu dong "news_<Symbol>.csv"
input int      News_RefreshMin      = 15;     // chu ky refresh Calendar API (chi live), qua OnTimer

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

bool           g_TrailClampLogged = false;   // [FEAT-P0-012] chong spam log trailing-skip

int            hATR_H1;

datetime       g_CurrentDay        = 0;
int            g_TradesToday       = 0;
int            g_ConsecutiveLosses = 0;
datetime       g_CooldownUntilBarTime = 0;
datetime       g_MarketClosedCooldown = 0;

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

// === [FEAT-P1-010] HTF Bias result ===
struct HTFBiasInfo
{
   int      bias;            // +1 bullish, -1 bearish, 0 neutral
   int      swing_bias;      // thanh phan swing (de log/debug)
   int      ema_bias;        // thanh phan EMA (de log/debug)
   double   sh1, sh2;        // 2 swing high gan nhat (0 neu khong du)
   double   sl1, sl2;        // 2 swing low gan nhat
   datetime computed_bar;    // bar time HTF tai lan tinh (cache key)
};

#define HTF_ATR_PERIOD 14
int         hATR_H4  = INVALID_HANDLE;
int         hATR_D1  = INVALID_HANDLE;
int         hEMA_H4  = INVALID_HANDLE;
int         hEMA_D1  = INVALID_HANDLE;
HTFBiasInfo g_BiasH4;
HTFBiasInfo g_BiasD1;
int         g_BiasCached = 0;

// === [FEAT-P1-011] Session window (don vi: phut-tu-nua-dem, server time) ===
struct SessionWindow
{
   bool   enabled;
   int    start_min;   // [0, 1440)
   int    end_min;     // [0, 1440); start_min == end_min -> vo hieu
   string name;        // "LONDON_KZ" / "NY_KZ" / "CUSTOM" , cho logging
};

SessionWindow g_Windows[3];            // London, NewYork, Custom , resolve 1 lan trong OnInit
string        g_SessionState = "INIT"; // key cho transition log

// === [FEAT-P1-020] News Filter state ===
struct NewsEvent
{
   datetime time;        // server time (ca Calendar API lan CSV deu quy ve server time)
   int      impact;      // 1=Low, 2=Medium, 3=High
   string   currency;    // "USD", ...
   string   name;        // ten su kien, cho logging
};

NewsEvent g_NewsEvents[];
int       g_NewsCount        = 0;
datetime  g_NewsLastRefresh  = 0;
string    g_NewsState        = "INIT";   // key cho transition log, mau giong g_SessionState
bool      g_NewsSourceFailed = false;    // da log WARNING 1 lan

// === [FEAT-S2-001] Donchian Core state ===
struct DonchianSignal
{
   int      direction;      // +1 BUY, -1 SELL, 0 = none
   double   dc_high;
   double   dc_low;
   double   atr_entry;
   datetime signal_bar;     // cache key = iTime(H1, 1)
};
DonchianSignal g_DCSignal;

double g_ATRAtEntry        = 0.0;
double g_HighestSinceEntry = 0.0;
double g_LowestSinceEntry  = 0.0;

//+------------------------------------------------------------------+
//| Helper FEAT-P1-020: Parse Currencies                             |
//+------------------------------------------------------------------+
int NewsFilter_ParseCurrencies(string raw, string &out[])
{
   ushort u_sep = StringGetCharacter(",", 0);
   string parts[];
   int count = StringSplit(raw, u_sep, parts);
   int valid = 0;
   ArrayResize(out, count);
   for(int i = 0; i < count; i++)
   {
      string c = parts[i];
      StringTrimLeft(c);
      StringTrimRight(c);
      if(StringLen(c) > 0)
      {
         out[valid] = c;
         valid++;
      }
   }
   ArrayResize(out, valid);
   return valid;
}

//+------------------------------------------------------------------+
//| Helper FEAT-P1-020: Sort Events                                  |
//+------------------------------------------------------------------+
void NewsFilter_SortEvents()
{
   int n = g_NewsCount;
   bool swapped = true;
   while(swapped)
   {
      swapped = false;
      for(int i = 1; i < n; i++)
      {
         if(g_NewsEvents[i-1].time > g_NewsEvents[i].time)
         {
            NewsEvent temp = g_NewsEvents[i-1];
            g_NewsEvents[i-1] = g_NewsEvents[i];
            g_NewsEvents[i] = temp;
            swapped = true;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helper FEAT-P1-020: Load CSV for Strategy Tester                 |
//+------------------------------------------------------------------+
bool NewsFilter_LoadCSV()
{
   string fname = News_CsvFile;
   if(fname == "") fname = "news_" + _Symbol + ".csv";

   // --- [P2] Parse danh sach currency cho phep (dong bo voi live path) ---
   string curs[];
   int c_count = NewsFilter_ParseCurrencies(News_Currencies, curs);
   if(c_count == 0)
   {
      Print("[FEAT-P1-020] INIT_FAILED: News_Currencies khong co currency hop le");
      return false;
   }

   ResetLastError();
   // Buoc 1: Mo file trong sandbox MQL5\Files\ cua Tester Agent
   int h = FileOpen(fname, FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ, ';');

   // Buoc 2: Neu chua tim thay, thu tim trong thu muc Common\Files
   if(h == INVALID_HANDLE)
      h = FileOpen(fname, FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ|FILE_COMMON, ';');

   if(h == INVALID_HANDLE)
   {
      int err = GetLastError();
      PrintFormat("[FEAT-P1-020] INIT_FAILED: Cannot open %s in local or common sandbox, ErrorCode = %d", fname, err);
      return false;
   }

   ArrayResize(g_NewsEvents, 0);
   g_NewsCount = 0;

   // --- [P1 FIX] Bo qua TOAN BO dong header ---
   // Truoc day: FileReadString 1 lan chi an field "time" -> cac field
   // "currency;impact;name" bi day xuong vong lap -> lech cot
   // (log loi: time=currency impact=0)
   while(!FileIsEnding(h) && !FileIsLineEnding(h))
      FileReadString(h);

   while(!FileIsEnding(h))
   {
      string t_str = FileReadString(h);

      // Bo qua dong trong (trailing newline cuoi file) mot cach an toan
      if(t_str == "")
      {
         while(!FileIsEnding(h) && !FileIsLineEnding(h))
            FileReadString(h);
         continue;
      }

      string curr  = FileReadString(h);
      string imp_s = FileReadString(h);
      string name  = FileReadString(h);

      datetime t = StringToTime(t_str);
      int impact = (int)StringToInteger(imp_s);
      if(t == 0 || impact < 1 || impact > 3)
      {
         PrintFormat("[FEAT-P1-020] INIT_FAILED: CSV parse error time=%s impact=%s", t_str, imp_s);
         FileClose(h);
         return false;
      }

      // --- [P2 FIX] Loc currency giong live path ---
      bool cur_ok = false;
      for(int c = 0; c < c_count; c++)
      {
         if(curr == curs[c]) { cur_ok = true; break; }
      }
      if(!cur_ok) continue;

      if(impact >= News_MinImpact)
      {
         int idx = ArraySize(g_NewsEvents);
         ArrayResize(g_NewsEvents, idx + 1);
         g_NewsEvents[idx].time     = t;
         g_NewsEvents[idx].currency = curr;
         g_NewsEvents[idx].impact   = impact;
         g_NewsEvents[idx].name     = name;
         g_NewsCount++;
      }
   }
   FileClose(h);
   NewsFilter_SortEvents();

   if(g_NewsCount > 0)
   {
      PrintFormat("[FEAT-P1-020] Loaded %d events from %s. Range: %s to %s",
         g_NewsCount, fname, TimeToString(g_NewsEvents[0].time), TimeToString(g_NewsEvents[g_NewsCount-1].time));
   }
   else
   {
      PrintFormat("[FEAT-P1-020] WARNING: No matching events in %s", fname);
   }
   return true;
}

//+------------------------------------------------------------------+
//| Core FEAT-P1-020: Refresh Live Calendar Data                     |
//+------------------------------------------------------------------+
int NewsFilter_RefreshLive()
{
   datetime now = TimeCurrent();
   datetime from = now - News_BlockBeforeMin * 60;
   datetime to = now + 7 * 86400;
   
   string curs[];
   int c_count = NewsFilter_ParseCurrencies(News_Currencies, curs);
   
   if(c_count == 0)
   {
      if(!g_NewsSourceFailed)
      {
         PrintFormat("[FEAT-P1-020] WARNING: No valid currencies, filter disabled");
         g_NewsSourceFailed = true;
      }
      return -1;
   }

   g_NewsCount = 0;
   ArrayResize(g_NewsEvents, 0);

   for(int i = 0; i < c_count; i++)
   {
      MqlCalendarValue values[];
      if(!CalendarValueHistory(values, from, to, NULL, curs[i]))
      {
         int err = GetLastError();
         if(err == ERR_CALENDAR_TIMEOUT) continue;
         if(err == ERR_CALENDAR_MORE_DATA || err == ERR_CALENDAR_NO_DATA)
         {
            if(!g_NewsSourceFailed && err == ERR_CALENDAR_MORE_DATA)
            {
               PrintFormat("[FEAT-P1-020] WARNING: ERR_CALENDAR_MORE_DATA for %s", curs[i]);
            }
            continue;
         }
      }

      int v_len = ArraySize(values);
      for(int v = 0; v < v_len; v++)
      {
         MqlCalendarEvent ev;
         if(CalendarEventById(values[v].event_id, ev))
         {
            int impact = (int)ev.importance;
            if(impact >= News_MinImpact)
            {
               MqlCalendarCountry country;
               string c_name = curs[i];
               if(CalendarCountryById(ev.country_id, country)) c_name = country.currency;

               int idx = ArraySize(g_NewsEvents);
               ArrayResize(g_NewsEvents, idx + 1);
               g_NewsEvents[idx].time = values[v].time;
               g_NewsEvents[idx].impact = impact;
               g_NewsEvents[idx].currency = c_name;
               g_NewsEvents[idx].name = ev.name;
               g_NewsCount++;
            }
         }
      }
   }
   
   NewsFilter_SortEvents();
   g_NewsLastRefresh = TimeCurrent();
   return g_NewsCount;
}

//+------------------------------------------------------------------+
//| Core FEAT-P1-020: IsNewsBlocked                                  |
//+------------------------------------------------------------------+
bool IsNewsBlocked(string &reason)
{
   reason = "";
   if(!UseNewsFilter) return false;

   datetime now = TimeCurrent();
   datetime block_before = News_BlockBeforeMin * 60;
   datetime block_after  = News_BlockAfterMin * 60;
   bool blocked = false;

   for(int i = 0; i < g_NewsCount; i++)
   {
      datetime t_e = g_NewsEvents[i].time;
      if(t_e - block_after > now) break;

      if(now >= t_e - block_before && now <= t_e + block_after)
      {
         reason = StringFormat("NEWS:%s:%s", g_NewsEvents[i].currency, g_NewsEvents[i].name);
         blocked = true;
         break;
      }
   }

   string current_state = blocked ? reason : "";
   if(current_state != g_NewsState)
   {
      if(blocked)
         PrintFormat("[FEAT-P1-020] BLOCKED: %s @ %s server", reason, TimeToString(now, TIME_MINUTES));
      else if(g_NewsState != "INIT" && g_NewsState != "")
         PrintFormat("[FEAT-P1-020] ENTER CLEAR_NEWS @ %s server", TimeToString(now, TIME_MINUTES));
         
      g_NewsState = current_state;
   }

   return blocked;
}

//+------------------------------------------------------------------+
//| Init FEAT-P1-020                                                 |
//+------------------------------------------------------------------+
bool NewsFilter_Init()
{
   if(!UseNewsFilter) return true;

   if((bool)MQLInfoInteger(MQL_TESTER))
   {
      return NewsFilter_LoadCSV();
   }
   else
   {
      int refresh = News_RefreshMin;
      if(refresh < 5)
      {
         refresh = 5;
         PrintFormat("[FEAT-P1-020] WARNING: News_RefreshMin < 5, clamped to 5");
      }
      EventSetTimer(refresh * 60);
      NewsFilter_RefreshLive();
      return true;
   }
}

//+------------------------------------------------------------------+
//| Deinit FEAT-P1-020                                               |
//+------------------------------------------------------------------+
void NewsFilter_Deinit()
{
   if(UseNewsFilter && !(bool)MQLInfoInteger(MQL_TESTER))
   {
      EventKillTimer();
   }
}

//+------------------------------------------------------------------+
//| Timer FEAT-P1-020                                                |
//+------------------------------------------------------------------+
void NewsFilter_OnTimer()
{
   if(!(bool)MQLInfoInteger(MQL_TESTER))
   {
      NewsFilter_RefreshLive();
   }
}

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

   hATR_H1 = iATR(_Symbol, PERIOD_H1, ATR_Period_H1);

   if(hATR_H1 == INVALID_HANDLE)
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
         Print("[FEAT-P1-011] WARNING: UseSessionFilter=true nhung khong co window hop le , filter vo hieu");
   }

   if(UseNewsFilter)
   {
      if(!NewsFilter_Init()) return INIT_FAILED;
   }

   ZeroMemory(g_LossZones);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hATR_H1);
   
   if(hATR_H4 != INVALID_HANDLE) IndicatorRelease(hATR_H4);
   if(hATR_D1 != INVALID_HANDLE) IndicatorRelease(hATR_D1);
   if(hEMA_H4 != INVALID_HANDLE) IndicatorRelease(hEMA_H4);
   if(hEMA_D1 != INVALID_HANDLE) IndicatorRelease(hEMA_D1);
   
   if(UseNewsFilter) NewsFilter_Deinit();
}

//+------------------------------------------------------------------+
void OnTimer()
{
   if(UseNewsFilter) NewsFilter_OnTimer();
}

//+------------------------------------------------------------------+
bool IsMarketTradeable()
{
   if(TimeCurrent() < g_MarketClosedCooldown) return false;

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
int SessionHourToMin(const double hour)
{
   int m = (int)MathRound(hour * 60.0);
   if(m < 0) m = 0;
   if(m > 1439) m = 1439;
   return m;
}

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
bool IsInTradeSession(string &reason)
{
   reason = "";
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int cur_min = dt.hour * 60 + dt.min; // BO QUA dt.sec
   int active_idx = -1;

   if(UseFridayCutoff && dt.day_of_week == 5 && cur_min >= (int)MathRound(Friday_CutoffHour * 60.0))
   {
      reason = "FRIDAY_CUTOFF";
   }
   else if(UseMondayDelay && dt.day_of_week == 1 && cur_min < (int)MathRound(Monday_OpenHour * 60.0))
   {
      reason = "MONDAY_DELAY";
   }
   else
   {
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
      g_HasOpenZone       = false;
      PartialDone         = false;
      InitialVolume       = 0.0;
      InitialSLDistance   = 0.0;
      LastTrailSL         = 0.0;
      
      g_ATRAtEntry        = 0.0;
      g_HighestSinceEntry = 0.0;
      g_LowestSinceEntry  = 0.0;
   }
}

//+------------------------------------------------------------------+
bool GetDonchianSignal(DonchianSignal &sig)
{
   datetime bar1 = iTime(_Symbol, PERIOD_H1, 1);
   if(sig.signal_bar == bar1 && bar1 != 0) return true;

   int count = DC_Period + 3;
   double high_arr[], low_arr[], close_arr[];
   ArraySetAsSeries(high_arr, true);
   ArraySetAsSeries(low_arr, true);
   ArraySetAsSeries(close_arr, true);

   if(CopyHigh(_Symbol, PERIOD_H1, 0, count, high_arr) < count) return false;
   if(CopyLow(_Symbol, PERIOD_H1, 0, count, low_arr) < count) return false;
   if(CopyClose(_Symbol, PERIOD_H1, 0, count, close_arr) < count) return false;

   double atr_arr[];
   ArraySetAsSeries(atr_arr, true);
   if(CopyBuffer(hATR_H1, 0, 1, 1, atr_arr) < 1) return false;
   if(atr_arr[0] <= 0) return false;

   double dc_high = -1.0;
   double dc_low = 999999.0;
   for(int i = 2; i <= DC_Period + 1; i++)
   {
      if(high_arr[i] > dc_high) dc_high = high_arr[i];
      if(low_arr[i] < dc_low) dc_low = low_arr[i];
   }

   double dc_prev_high = -1.0;
   double dc_prev_low = 999999.0;
   for(int i = 3; i <= DC_Period + 2; i++)
   {
      if(high_arr[i] > dc_prev_high) dc_prev_high = high_arr[i];
      if(low_arr[i] < dc_prev_low) dc_prev_low = low_arr[i];
   }

   sig.direction = 0;
   if(close_arr[1] > dc_high && close_arr[2] <= dc_prev_high)
      sig.direction = 1;
   else if(close_arr[1] < dc_low && close_arr[2] >= dc_prev_low)
      sig.direction = -1;

   sig.dc_high = dc_high;
   sig.dc_low = dc_low;
   sig.atr_entry = atr_arr[0];
   
   if(sig.direction != 0)
   {
      string dir_str = (sig.direction > 0) ? "BUY" : "SELL";
      PrintFormat("[FEAT-S2-001] SIGNAL %s @ close=%.5f DC_High=%.5f DC_Low=%.5f ATR=%.5f", 
                  dir_str, close_arr[1], dc_high, dc_low, atr_arr[0]);
   }

   sig.signal_bar = bar1;
   return true;
}

//+------------------------------------------------------------------+
void UpdateChandelierExtremes(ENUM_POSITION_TYPE pos_type)
{
   static datetime LastExtremeBarTime = 0;
   datetime CurrBar = iTime(_Symbol, PERIOD_H1, 0);
   if(CurrBar == LastExtremeBarTime) return;
   
   if(pos_type == POSITION_TYPE_BUY)
   {
      double h1 = iHigh(_Symbol, PERIOD_H1, 1);
      if(h1 > g_HighestSinceEntry) g_HighestSinceEntry = h1;
   }
   else if(pos_type == POSITION_TYPE_SELL)
   {
      double l1 = iLow(_Symbol, PERIOD_H1, 1);
      if(l1 < g_LowestSinceEntry || g_LowestSinceEntry == 0.0) g_LowestSinceEntry = l1;
   }
   LastExtremeBarTime = CurrBar;
}

//+------------------------------------------------------------------+
double ComputeChandelierSL(ENUM_POSITION_TYPE pos_type)
{
   if(pos_type == POSITION_TYPE_BUY)
   {
      return NormalizeDouble(g_HighestSinceEntry - DC_Trail_ATR_Mult * g_ATRAtEntry, Digits_val);
   }
   else
   {
      return NormalizeDouble(g_LowestSinceEntry + DC_Trail_ATR_Mult * g_ATRAtEntry, Digits_val);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(UseNewsFilter && !(bool)MQLInfoInteger(MQL_TESTER))
   {
      if(TimeCurrent() - g_NewsLastRefresh > News_RefreshMin * 60)
         NewsFilter_RefreshLive();
   }

   UpdateDailyCounterIfNewDay();

   if(HasOpenPosition())
   {
      ManagePosition();
      return;
   }

   static datetime LastBarTime = 0;
   datetime CurrBarTime = iTime(_Symbol, PERIOD_H1, 0);
   if(CurrBarTime == LastBarTime) return;
   LastBarTime = CurrBarTime;

   if(!IsMarketTradeable())          return;
   if(InCooldown())                  return;
   if(g_TradesToday >= MaxTradesPerDay) return;

   double Ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double Bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double Spread = (Ask - Bid) / Point_val;

   if(Spread > SpreadFilter) return;

   if(UseSessionFilter)
   {
      string sess_reason;
      if(!IsInTradeSession(sess_reason)) return;
   }

   if(UseHTFBiasFilter)
   {
      if(!UpdateHTFBias()) return;
   }

   if(!GetDonchianSignal(g_DCSignal)) return;
   if(g_DCSignal.direction == 0)      return;

   if(UseHTFBiasFilter && !CheckHTFBiasDirection(g_DCSignal.direction)) return;

   if(UseLossZoneFilter && IsZoneBlocked(g_DCSignal.dc_high, g_DCSignal.dc_low)) return;

   if(UseNewsFilter)
   {
      string news_reason;
      if(IsNewsBlocked(news_reason))
         return;
   }

   double atr_e   = g_DCSignal.atr_entry;
   double sl_dist = DC_SL_ATR_Mult * atr_e;
   double min_stop = GetMinStopDistance();

   if(sl_dist < min_stop)
   {
      if(min_stop > 2.0 * sl_dist)
      {
         PrintFormat("[FEAT-S2-001] SKIP: clamp %.2f > 2x designed SL %.2f", min_stop, sl_dist);
         return;
      }
      sl_dist = min_stop;
   }

   double entry = (g_DCSignal.direction > 0) ? Ask : Bid;
   double sl    = (g_DCSignal.direction > 0)
                  ? NormalizeDouble(entry - sl_dist, Digits_val)
                  : NormalizeDouble(entry + sl_dist, Digits_val);
   
   double lot = CalcLotSize(sl_dist / Point_val);
   if(lot <= 0) return;

   bool ok = SafeOrderSend(
      (g_DCSignal.direction > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,
      lot, 0.0, sl, 0.0,
      "S2_DC_H1_BO");

   if(ok)
   {
      g_TradesToday++;
      g_OpenZoneTop    = g_DCSignal.dc_high;
      g_OpenZoneBottom = g_DCSignal.dc_low;
      g_HasOpenZone    = true;

      g_ATRAtEntry        = atr_e;
      g_HighestSinceEntry = iHigh(_Symbol, PERIOD_H1, 1);
      g_LowestSinceEntry  = iLow(_Symbol, PERIOD_H1, 1);
      CurrentTicket       = Trade.ResultOrder();
   }
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

   if(!IsMarketTradeable()) return;

   if(!GetOpenPosition(ticket, open_price, current_sl, tp, volume, pos_type))
      return;

   if(InitialVolume == 0.0) InitialVolume = volume;
   if(InitialSLDistance <= 0.0)
   {
      if(current_sl > 0) InitialSLDistance = MathAbs(open_price - current_sl);
      else return;
   }

   double Ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double Bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double profit_price   = (pos_type == POSITION_TYPE_BUY) ? (Bid - open_price) : (open_price - Ask);
   double profit_R        = profit_price / InitialSLDistance;

   if(UsePartialClose && !PartialDone && profit_R >= PartialAtR)
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
         else
         {
            uint retcode = Trade.ResultRetcode();
            if(retcode == TRADE_RETCODE_MARKET_CLOSED)
            {
               g_MarketClosedCooldown = TimeCurrent() + 60;
               return;
            }
            else if(retcode == TRADE_RETCODE_INVALID_FILL)
            {
               if(FallbackFillingMode())
               {
                  if(Trade.PositionClosePartial(ticket, lot_to_close))
                  {
                     PartialDone = true;
                  }
                  else
                  {
                     if(Trade.ResultRetcode() == TRADE_RETCODE_MARKET_CLOSED) g_MarketClosedCooldown = TimeCurrent() + 60;
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
               PrintFormat("[FEAT-P0-001] PositionClosePartial failed, retcode: %d, comment: %s", retcode, Trade.ResultComment());
            }
         }
      }
      else
      {
         PartialDone = true;
      }
   }

   if(TrailMode == TRAIL_CHANDELIER)
   {
      if(g_ATRAtEntry <= 0) return;
      UpdateChandelierExtremes(pos_type);

      double new_sl = ComputeChandelierSL(pos_type);
      bool should_modify = false;
      if(pos_type == POSITION_TYPE_BUY  && (current_sl == 0 || new_sl > current_sl + Point_val))
         should_modify = true;
      if(pos_type == POSITION_TYPE_SELL && (current_sl == 0 || new_sl < current_sl - Point_val))
         should_modify = true;

      if(should_modify)
      {
         double min_stop_t = GetMinStopDistance();
         bool sl_valid = (pos_type == POSITION_TYPE_BUY)
            ? (new_sl <= NormalizeDouble(Bid - min_stop_t, Digits_val))
            : (new_sl >= NormalizeDouble(Ask + min_stop_t, Digits_val));

         if(!sl_valid)
         {
            if(!g_TrailClampLogged)
            {
               PrintFormat("[FEAT-S2-001] Trailing skip: new_sl=%.2f vi pham min_stop=%.2f , thu lai tick sau", new_sl, min_stop_t);
               g_TrailClampLogged = true;
            }
            return;
         }
         g_TrailClampLogged = false;

         if(Trade.PositionModify(ticket, new_sl, tp))
         {
            LastTrailSL = new_sl;
            PrintFormat("[FEAT-S2-001] Trailing modify SL: %.5f -> %.5f", current_sl, new_sl);
         }
         else if(Trade.ResultRetcode() == TRADE_RETCODE_MARKET_CLOSED)
         {
            g_MarketClosedCooldown = TimeCurrent() + 60;
         }
      }
      return;
   }

   if(TrailMode == TRAIL_R_MULTIPLE)
   {
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
                  PrintFormat("[FEAT-P0-012] Trailing skip: new_sl=%.2f vi pham min_stop=%.2f , thu lai tick sau",
                              new_sl, min_stop_t);
                  g_TrailClampLogged = true;
               }
               return;
            }
            g_TrailClampLogged = false;
         }

         if(should_modify && MathAbs(new_sl - LastTrailSL) > Point_val)
         {
            if(Trade.PositionModify(ticket, new_sl, tp))
               LastTrailSL = new_sl;
            else if(Trade.ResultRetcode() == TRADE_RETCODE_MARKET_CLOSED)
               g_MarketClosedCooldown = TimeCurrent() + 60;
         }
      }
   }
}

//+------------------------------------------------------------------+
double GetMinStopDistance()
{
   long stops_pts  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze_pts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double static_min = MathMax((double)stops_pts, (double)freeze_pts) * Point_val;

   double spread = 0;
   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick)) spread = tick.ask - tick.bid;
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

      if(retcode == TRADE_RETCODE_MARKET_CLOSED)
      {
         g_MarketClosedCooldown = TimeCurrent() + 60;
         PrintFormat("[FEAT-P0-001] Order failed: Market closed. Cooldown 60s.");
         return false;
      }

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

//+------------------------------------------------------------------+
//| CHANGE LOG                                                       |
//| 2026-08-05 FEAT-S2-001: Donchian Core + Chandelier trailing      |
//|  - Source modules: giu nguyen R1-R3 tu STRAT-001 archive         |
//|  - Xoa bo MinRR theo spec thiet ke moi                           |
//|  - Them nhom input cho Donchian va Trail Mode                    |
//|  - Bo sung ham GetDonchianSignal, ComputeChandelierSL            |
//|  - Cap nhat pipeline OnTick thay the khoi POI logic              |
//|  - Them chuc nang Chandelier Trailing trong ManagePosition       |
//|  - Cap nhat reset global state trong OnTradeTransaction          |
//| 2026-08-05 HOTFIX: Market Closed Spam                            |
//|  - Khai bao bien global g_MarketClosedCooldown                   |
//|  - Chặn spam log do loi 10018 tai ManagePosition, SafeOrderSend  |
//| 2026-08-11 FEAT-P1-020: News Filter                              |
//|  - Spec: SPEC_FEAT-P1-020_NewsFilter.md                          |
//|  - Dual-source: Calendar API (live) / CSV (tester, MQL_TESTER)   |
//|  - Chan entry moi +-N phut quanh tin impact >= News_MinImpact    |
//|  - KHONG can thiep lenh dang mo (ManagePosition nguyen xi)       |
//|  - Hook: OnInit/OnDeinit/OnTimer/OnTick (sau loss-zone gate)     |
//+------------------------------------------------------------------+