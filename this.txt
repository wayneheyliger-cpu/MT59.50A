//+------------------------------------------------------------------+
//| GoldPulse_BurstTrend_v3_10_TradeFlow.mq5                                    |
//| Edge first. Speed second.                                         |
//| M5/H1 trend bias + M1 candle/tick impulse + probe -> burst engine |
//+------------------------------------------------------------------+
#property copyright "Wayne Heyliger / OpenAI"
#property version   "3.10"
#property strict
#property description "GoldPulse BurstTrend v3.10: looser trade-flow version. M5 trend edge, M1 confirmation, probe-first burst, smaller basket targets, reduced friction."

#include <Trade/Trade.mqh>
CTrade trade;

//====================================================================
// ENUMS
//====================================================================
enum ENUM_GBT_SIGNAL_MODE
{
   GBT_BOTH_DIRECTIONS = 0,
   GBT_BUY_ONLY        = 1,
   GBT_SELL_ONLY       = 2
};

enum ENUM_GBT_LOT_MODE
{
   GBT_LOT_FIXED        = 0,
   GBT_LOT_RISK_PERCENT = 1
};

enum ENUM_GBT_STOP_MODE
{
   GBT_STOP_FIXED_POINTS = 0,
   GBT_STOP_ATR          = 1
};

enum ENUM_GBT_PROBE_STYLE
{
   GBT_PROBE_TREND_ONLY       = 0, // trend + M1 candle confirmation
   GBT_PROBE_TREND_AND_TICK   = 1  // trend + M1 candle + tick burst
};

//====================================================================
// INPUTS
//====================================================================
input group "=== EA IDENTITY ==="
input string InpEAName                  = "GoldPulse_BurstTrend_v3_10_TradeFlow";
input long   InpMagicNumber             = 26042530;
input bool   InpShowDashboard           = true;
input bool   InpDebug                   = false;

input group "=== TRADE DIRECTION ==="
input ENUM_GBT_SIGNAL_MODE InpSignalMode = GBT_BOTH_DIRECTIONS;
input bool   InpAllowHedgeBuySell       = false;   // default false: one direction at a time

input group "=== TIMEFRAMES ==="
input ENUM_TIMEFRAMES InpEntryTF         = PERIOD_M1;
input ENUM_TIMEFRAMES InpTrendTF         = PERIOD_M5;
input ENUM_TIMEFRAMES InpBiasTF          = PERIOD_H1;
input ENUM_TIMEFRAMES InpATRTF           = PERIOD_M1;

input group "=== TREND FILTERS ==="
input bool   InpUseTrendFilter           = true;
input int    InpTrendFastEMA             = 20;
input int    InpTrendSlowEMA             = 50;
input int    InpTrendAnchorEMA           = 200;
input bool   InpUseTrendAnchor           = true;
input bool   InpUseTrendSlopeFilter      = true;
input int    InpTrendSlopeLookback       = 3;
input bool   InpUseBiasFilter            = false;     // v3.10: H1 bias was too restrictive
input int    InpBiasEMA                  = 200;

input group "=== ADX / DI FILTER ==="
input bool   InpUseADXFilter             = true;
input int    InpADXPeriod                = 14;
input double InpADXMin                   = 14.0;
input bool   InpUseDIFilter              = false;

input group "=== M1 CANDLE / EMA CONFIRMATION ==="
input bool   InpUseM1CandleConfirm       = true;
input int    InpEntryFastEMA             = 20;
input int    InpEntrySlowEMA             = 50;
input double InpMinBodyATR               = 0.03;
input bool   InpRequireCloseBeyondPrev   = false;
input double InpMaxCloseDistanceATR      = 1.80;

input group "=== TICK IMPULSE CONFIRMATION ==="
input ENUM_GBT_PROBE_STYLE InpProbeStyle = GBT_PROBE_TREND_ONLY;
input int    InpTickLookback             = 6;
input double InpTickImpulsePoints        = 20.0;
input int    InpMinDirectionalTicks      = 3;
input double InpMaxImpulseSeconds        = 3.0;

input group "=== SPREAD / VOLATILITY FILTER ==="
input int    InpMaxSpreadPoints          = 80;
input bool   InpUseSpreadATRFilter       = true;
input double InpMaxSpreadATRRatio        = 0.25;    // spread must be <= ATR points x this
input int    InpATRPeriod                = 14;
input bool   InpUseATRRangeFilter        = true;
input double InpMinATRPoints             = 80.0;
input double InpMaxATRPoints             = 1500.0;
input int    InpExtraStopBufferPoints    = 5;
input int    InpSlippagePoints           = 30;

input group "=== LOT / EXPOSURE ==="
input ENUM_GBT_LOT_MODE InpLotMode       = GBT_LOT_FIXED;
input double InpFixedLot                 = 0.01;
input double InpRiskPercent              = 0.25;
input double InpProbeLot                 = 0.01;
input double InpBurstLot                 = 0.01;
input double InpMaxLot                   = 1.00;
input int    InpMaxPositionsPerSide      = 3;       // includes probe
input int    InpMaxTotalPositions        = 3;
input double InpMaxTotalLots             = 0.03;

input group "=== PROBE -> BURST LOGIC ==="
input double InpProbeConfirmPoints       = 45.0;
input double InpProbeConfirmMoney        = 0.30;
input double InpProbeConfirmSpreadMult   = 0.80;    // dynamic confirm = max(confirm points, spread x mult)
input double InpProbeFailPoints          = 80.0;
input double InpProbeFailMoney           = -0.90;
input int    InpProbeMaxSeconds          = 90;
input double InpProbeTimeoutMinPoints    = -10.0;
input int    InpDirectionPauseAfterProbeFailSec = 120;
input int    InpMaxProbeFailsBeforeLongPause = 2;
input int    InpLongDirectionPauseSec    = 600;

input group "=== BURST ADD RULES ==="
input int    InpBurstOrdersPerAdd        = 1;
input int    InpMinSecondsBetweenAdds    = 5;
input double InpMinBasketProfitToAdd     = -0.10;
input double InpMinSameSideSpacingPoints = 30.0;
input bool   InpRequireFreshSignalToAdd  = true;
input bool   InpAddOnlyIfPriceImproves   = true;

input group "=== BROKER STOP / TRADE MANAGEMENT ==="
input ENUM_GBT_STOP_MODE InpStopMode     = GBT_STOP_ATR;
input double InpFixedSLPoints            = 450.0;
input double InpATRSLMultiplier          = 0.85;
input bool   InpUseBreakEven             = true;
input double InpBETriggerPoints          = 70.0;
input double InpBEPlusPoints             = 8.0;
input bool   InpUseTrailing              = true;
input double InpTrailStartPoints         = 100.0;
input double InpTrailATRMultiplier       = 0.60;
input double InpTrailMinPoints           = 70.0;
input double InpTrailStepPoints          = 15.0;
input int    InpMinSecondsBetweenTrailUpdates = 2;

input group "=== BASKET EXITS ==="
input bool   InpUseBasketClose           = true;
input double InpBasketProfitMoney        = 1.50;
input double InpBasketLossMoney          = -2.00;
input bool   InpUseBasketProfitTrail     = true;
input double InpBasketTrailStartMoney    = 1.00;
input double InpBasketTrailGivebackMoney = 0.55;
input int    InpBasketMaxLifeSeconds     = 900;
input int    InpCooldownAfterBasketProfitSec = 10;
input int    InpCooldownAfterBasketLossSec   = 180;

input group "=== SESSION / DAILY PROTECTION ==="
input bool   InpUseSessionFilter         = true;
input int    InpSessionStartHourServer   = 7;
input int    InpSessionEndHourServer     = 21;
input bool   InpTradeMondayToFridayOnly  = true;
input int    InpMaxTradesPerDay          = 120;
input int    InpMaxConsecutiveBasketLosses = 4;
input double InpDailyProfitTargetMoney   = 0.0;     // 0 = off
input double InpDailyLossLimitMoney      = 150.0;   // 0 = off
input double InpDailyLossLimitPercent    = 2.00;    // 0 = off

input group "=== ALERTS ==="
input bool   InpEnableAlerts             = false;
input bool   InpEnableSound              = false;
input string InpBuySound                 = "alert.wav";
input string InpSellSound                = "request.wav";

//====================================================================
// CONSTANTS / GLOBALS
//====================================================================
#define GBT_TICK_BUF 128

int hTrendFast  = INVALID_HANDLE;
int hTrendSlow  = INVALID_HANDLE;
int hTrendAnchor= INVALID_HANDLE;
int hBiasEMA    = INVALID_HANDLE;
int hEntryFast  = INVALID_HANDLE;
int hEntrySlow  = INVALID_HANDLE;
int hATR        = INVALID_HANDLE;
int hADX        = INVALID_HANDLE;

double bufTrendFast[];
double bufTrendSlow[];
double bufTrendAnchor[];
double bufBiasEMA[];
double bufEntryFast[];
double bufEntrySlow[];
double bufATR[];
double bufADX[];
double bufPlusDI[];
double bufMinusDI[];

MqlRates ratesTrend[];
MqlRates ratesBias[];
MqlRates ratesEntry[];

double g_midTicks[GBT_TICK_BUF];
long   g_tickMS[GBT_TICK_BUF];
int    g_tickCount = 0;
long   g_lastTickMS = 0;

bool     g_confirmed[2];
datetime g_basketStartTime[2];
double   g_basketPeakProfit[2];
datetime g_directionPauseUntil[2];
int      g_probeFailsToday[2];
datetime g_globalPauseUntil = 0;
datetime g_lastBasketCloseTime = 0;
long     g_lastAddMS[2];
long     g_lastEntryMS = 0;

int      g_dayKey = -1;
double   g_dayStartEquity = 0.0;
double   g_dayProfit = 0.0;
int      g_tradesToday = 0;
int      g_consecutiveBasketLosses = 0;
bool     g_dayLocked = false;

string   g_lastStatus = "Starting";

//====================================================================
// BASIC HELPERS
//====================================================================
string TicketToString(ulong ticket)
{
   return StringFormat("%I64u", ticket);
}

string StateKey(ulong ticket, string field)
{
   return "GBT_" + _Symbol + "_" + IntegerToString((int)InpMagicNumber) + "_" + TicketToString(ticket) + "_" + field;
}

double NormalizePrice(double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

int VolumeDigits()
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return 2;

   int digits = 0;
   double x = step;
   while(digits < 8 && MathAbs(x - MathRound(x)) > 0.00000001)
   {
      x *= 10.0;
      digits++;
   }
   return digits;
}

double NormalizeVolumeFloor(double volume)
{
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minV <= 0.0 || maxV <= 0.0 || step <= 0.0)
      return 0.0;

   double cap = MathMin(maxV, MathMin(InpMaxLot, InpMaxTotalLots));
   volume = MathMin(volume, cap);

   if(volume < minV)
      return 0.0;

   double steps = MathFloor((volume + 0.0000000001) / step);
   double out = steps * step;

   if(out < minV)
      return 0.0;

   return NormalizeDouble(out, VolumeDigits());
}

bool IsHedgingAccount()
{
   ENUM_ACCOUNT_MARGIN_MODE mode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return (mode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

int DirToIndex(int dir)
{
   return (dir > 0 ? 0 : 1);
}

int IndexToDir(int idx)
{
   return (idx == 0 ? 1 : -1);
}

long DirToPositionType(int dir)
{
   return (dir > 0 ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
}

string DirName(int dir)
{
   return (dir > 0 ? "BUY" : "SELL");
}

int CurrentSpreadPoints()
{
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
}

double BrokerStopDistancePoints()
{
   int stops  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)(MathMax(stops, freeze) + InpExtraStopBufferPoints);
}

bool TradingAllowed()
{
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      g_lastStatus = "MQL trading disabled";
      return false;
   }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      g_lastStatus = "Terminal algo trading disabled";
      return false;
   }

   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED)
   {
      g_lastStatus = "Symbol trading disabled";
      return false;
   }

   return true;
}

bool IsAllowedDay()
{
   if(!InpTradeMondayToFridayOnly)
      return true;

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   return (tm.day_of_week >= 1 && tm.day_of_week <= 5);
}

bool HourInWindow(int hour, int startHour, int endHour)
{
   if(startHour == endHour)
      return true;

   if(startHour < endHour)
      return (hour >= startHour && hour < endHour);

   return (hour >= startHour || hour < endHour);
}

bool SessionOK()
{
   if(!IsAllowedDay())
   {
      g_lastStatus = "Day blocked";
      return false;
   }

   if(!InpUseSessionFilter)
      return true;

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);

   if(!HourInWindow(tm.hour, InpSessionStartHourServer, InpSessionEndHourServer))
   {
      g_lastStatus = "Outside session";
      return false;
   }

   return true;
}

void ResetDailyStatsIfNeeded()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);

   int key = tm.year * 10000 + tm.mon * 100 + tm.day;

   if(g_dayKey != key)
   {
      g_dayKey = key;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_dayProfit = 0.0;
      g_tradesToday = 0;
      g_consecutiveBasketLosses = 0;
      g_dayLocked = false;

      g_probeFailsToday[0] = 0;
      g_probeFailsToday[1] = 0;
      g_directionPauseUntil[0] = 0;
      g_directionPauseUntil[1] = 0;
      g_globalPauseUntil = 0;

      g_lastStatus = "New day";
   }

   if(InpDailyLossLimitPercent > 0.0 && g_dayStartEquity > 0.0)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double ddPct = 100.0 * (g_dayStartEquity - equity) / g_dayStartEquity;

      if(ddPct >= InpDailyLossLimitPercent)
      {
         g_dayLocked = true;
         g_lastStatus = StringFormat("Daily loss percent lock %.2f%%", ddPct);
      }
   }

   if(InpDailyLossLimitMoney > 0.0 && g_dayProfit <= -MathAbs(InpDailyLossLimitMoney))
   {
      g_dayLocked = true;
      g_lastStatus = "Daily money loss lock";
   }

   if(InpDailyProfitTargetMoney > 0.0 && g_dayProfit >= InpDailyProfitTargetMoney)
   {
      g_dayLocked = true;
      g_lastStatus = "Daily profit target reached";
   }

   if(InpMaxConsecutiveBasketLosses > 0 &&
      g_consecutiveBasketLosses >= InpMaxConsecutiveBasketLosses)
   {
      g_dayLocked = true;
      g_lastStatus = "Consecutive basket loss lock";
   }
}

//====================================================================
// DATA / INDICATORS
//====================================================================
bool RefreshMarketData()
{
   ArraySetAsSeries(bufTrendFast, true);
   ArraySetAsSeries(bufTrendSlow, true);
   ArraySetAsSeries(bufTrendAnchor, true);
   ArraySetAsSeries(bufBiasEMA, true);
   ArraySetAsSeries(bufEntryFast, true);
   ArraySetAsSeries(bufEntrySlow, true);
   ArraySetAsSeries(bufATR, true);
   ArraySetAsSeries(bufADX, true);
   ArraySetAsSeries(bufPlusDI, true);
   ArraySetAsSeries(bufMinusDI, true);
   ArraySetAsSeries(ratesTrend, true);
   ArraySetAsSeries(ratesBias, true);
   ArraySetAsSeries(ratesEntry, true);

   int slopeNeed = MathMax(3, InpTrendSlopeLookback + 3);

   if(CopyRates(_Symbol, InpTrendTF, 0, MathMax(10, slopeNeed), ratesTrend) < MathMax(10, slopeNeed))
   {
      g_lastStatus = "Waiting trend rates";
      return false;
   }

   if(CopyRates(_Symbol, InpEntryTF, 0, 10, ratesEntry) < 10)
   {
      g_lastStatus = "Waiting entry rates";
      return false;
   }

   if(CopyBuffer(hTrendFast, 0, 0, MathMax(10, slopeNeed), bufTrendFast) < MathMax(10, slopeNeed))
   {
      g_lastStatus = "Waiting trend fast";
      return false;
   }

   if(CopyBuffer(hTrendSlow, 0, 0, MathMax(10, slopeNeed), bufTrendSlow) < MathMax(10, slopeNeed))
   {
      g_lastStatus = "Waiting trend slow";
      return false;
   }

   if(InpUseTrendAnchor)
   {
      if(CopyBuffer(hTrendAnchor, 0, 0, MathMax(10, slopeNeed), bufTrendAnchor) < MathMax(10, slopeNeed))
      {
         g_lastStatus = "Waiting trend anchor";
         return false;
      }
   }

   if(InpUseBiasFilter)
   {
      if(CopyRates(_Symbol, InpBiasTF, 0, 10, ratesBias) < 10)
      {
         g_lastStatus = "Waiting bias rates";
         return false;
      }

      if(CopyBuffer(hBiasEMA, 0, 0, 10, bufBiasEMA) < 10)
      {
         g_lastStatus = "Waiting bias EMA";
         return false;
      }
   }

   if(CopyBuffer(hEntryFast, 0, 0, 10, bufEntryFast) < 10)
   {
      g_lastStatus = "Waiting entry fast";
      return false;
   }

   if(CopyBuffer(hEntrySlow, 0, 0, 10, bufEntrySlow) < 10)
   {
      g_lastStatus = "Waiting entry slow";
      return false;
   }

   if(CopyBuffer(hATR, 0, 0, 10, bufATR) < 10)
   {
      g_lastStatus = "Waiting ATR";
      return false;
   }

   if(InpUseADXFilter || InpUseDIFilter)
   {
      if(CopyBuffer(hADX, 0, 0, 10, bufADX) < 10)
      {
         g_lastStatus = "Waiting ADX";
         return false;
      }

      if(CopyBuffer(hADX, 1, 0, 10, bufPlusDI) < 10)
      {
         g_lastStatus = "Waiting +DI";
         return false;
      }

      if(CopyBuffer(hADX, 2, 0, 10, bufMinusDI) < 10)
      {
         g_lastStatus = "Waiting -DI";
         return false;
      }
   }

   return true;
}

double ATRPoints()
{
   if(ArraySize(bufATR) < 2 || bufATR[1] <= 0.0)
      return 0.0;

   return bufATR[1] / _Point;
}

bool VolatilityAndSpreadOK()
{
   int spread = CurrentSpreadPoints();

   if(spread > InpMaxSpreadPoints)
   {
      g_lastStatus = StringFormat("Spread blocked %d > %d", spread, InpMaxSpreadPoints);
      return false;
   }

   double atrPts = ATRPoints();

   if(atrPts <= 0.0)
   {
      g_lastStatus = "ATR invalid";
      return false;
   }

   if(InpUseATRRangeFilter)
   {
      if(atrPts < InpMinATRPoints)
      {
         g_lastStatus = "ATR too low";
         return false;
      }

      if(atrPts > InpMaxATRPoints)
      {
         g_lastStatus = "ATR too high";
         return false;
      }
   }

   if(InpUseSpreadATRFilter)
   {
      if((double)spread > atrPts * InpMaxSpreadATRRatio)
      {
         g_lastStatus = StringFormat("Spread/ATR blocked %d > %.1f", spread, atrPts * InpMaxSpreadATRRatio);
         return false;
      }
   }

   return true;
}

//====================================================================
// TICK BUFFER
//====================================================================
bool UpdateTickBuffer(MqlTick &tick)
{
   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   if(tick.bid <= 0.0 || tick.ask <= 0.0)
      return false;

   long ms = (long)tick.time_msc;

   if(ms <= 0)
      ms = (long)TimeCurrent() * 1000;

   double mid = (tick.bid + tick.ask) * 0.5;

   for(int i = GBT_TICK_BUF - 1; i > 0; i--)
   {
      g_midTicks[i] = g_midTicks[i - 1];
      g_tickMS[i] = g_tickMS[i - 1];
   }

   g_midTicks[0] = mid;
   g_tickMS[0] = ms;
   g_tickCount = MathMin(g_tickCount + 1, GBT_TICK_BUF);
   g_lastTickMS = ms;

   return true;
}

int CountDirectionalTicks(int lookback, bool up)
{
   int count = 0;
   int maxI = MathMin(lookback, g_tickCount - 1);

   for(int i = 0; i < maxI; i++)
   {
      double diff = g_midTicks[i] - g_midTicks[i + 1];

      if(up && diff > 0.0)
         count++;

      if(!up && diff < 0.0)
         count++;
   }

   return count;
}

int TickImpulseDirection()
{
   int lookback = MathMax(2, MathMin(InpTickLookback, GBT_TICK_BUF - 2));

   if(g_tickCount <= lookback + 1)
      return 0;

   long elapsedMS = g_tickMS[0] - g_tickMS[lookback];

   if(elapsedMS <= 0)
      elapsedMS = 1;

   double elapsedSec = (double)elapsedMS / 1000.0;

   if(elapsedSec > InpMaxImpulseSeconds)
      return 0;

   double deltaPts = (g_midTicks[0] - g_midTicks[lookback]) / _Point;
   int upTicks = CountDirectionalTicks(lookback, true);
   int dnTicks = CountDirectionalTicks(lookback, false);

   if(deltaPts >= InpTickImpulsePoints && upTicks >= InpMinDirectionalTicks)
      return 1;

   if(deltaPts <= -InpTickImpulsePoints && dnTicks >= InpMinDirectionalTicks)
      return -1;

   return 0;
}

//====================================================================
// SIGNAL LOGIC
//====================================================================
int TrendDirection()
{
   if(!InpUseTrendFilter)
      return 0;

   if(ArraySize(bufTrendFast) < InpTrendSlopeLookback + 3 ||
      ArraySize(bufTrendSlow) < InpTrendSlopeLookback + 3)
      return 0;

   double fast = bufTrendFast[1];
   double slow = bufTrendSlow[1];
   double slowPast = bufTrendSlow[1 + MathMax(1, InpTrendSlopeLookback)];
   double trendClose = ratesTrend[1].close;

   bool buy = (fast > slow);
   bool sell = (fast < slow);

   if(InpUseTrendAnchor)
   {
      if(ArraySize(bufTrendAnchor) < 2)
         return 0;

      double anchor = bufTrendAnchor[1];

      buy = buy && trendClose > anchor && slow > anchor;
      sell = sell && trendClose < anchor && slow < anchor;
   }

   if(InpUseTrendSlopeFilter)
   {
      buy = buy && slow > slowPast;
      sell = sell && slow < slowPast;
   }

   if(InpUseBiasFilter)
   {
      if(ArraySize(bufBiasEMA) < 2 || ArraySize(ratesBias) < 2)
         return 0;

      buy = buy && ratesBias[1].close > bufBiasEMA[1];
      sell = sell && ratesBias[1].close < bufBiasEMA[1];
   }

   if(buy && !sell)
      return 1;

   if(sell && !buy)
      return -1;

   return 0;
}

bool ADXOK(int dir)
{
   if(!InpUseADXFilter && !InpUseDIFilter)
      return true;

   if(ArraySize(bufADX) < 2 || ArraySize(bufPlusDI) < 2 || ArraySize(bufMinusDI) < 2)
      return false;

   if(InpUseADXFilter && bufADX[1] < InpADXMin)
   {
      g_lastStatus = "ADX too low";
      return false;
   }

   if(InpUseDIFilter)
   {
      if(dir > 0 && bufPlusDI[1] <= bufMinusDI[1])
      {
         g_lastStatus = "DI blocks buy";
         return false;
      }

      if(dir < 0 && bufMinusDI[1] <= bufPlusDI[1])
      {
         g_lastStatus = "DI blocks sell";
         return false;
      }
   }

   return true;
}

bool EntryCandleOK(int dir)
{
   if(!InpUseM1CandleConfirm)
      return true;

   if(ArraySize(ratesEntry) < 4 || ArraySize(bufEntryFast) < 4 || ArraySize(bufEntrySlow) < 4)
      return false;

   double o = ratesEntry[1].open;
   double c = ratesEntry[1].close;
   double h2 = ratesEntry[2].high;
   double l2 = ratesEntry[2].low;
   double body = MathAbs(c - o);
   double atr = bufATR[1];

   if(atr <= 0.0)
      return false;

   bool bodyOK = body >= atr * InpMinBodyATR;
   bool closeNear = MathAbs(c - bufEntryFast[1]) <= atr * InpMaxCloseDistanceATR;

   if(!bodyOK || !closeNear)
   {
      g_lastStatus = "Entry candle weak/far";
      return false;
   }

   if(dir > 0)
   {
      bool ok = c > o && c > bufEntryFast[1] && bufEntryFast[1] > bufEntrySlow[1];

      if(InpRequireCloseBeyondPrev)
         ok = ok && c > h2;

      return ok;
   }

   if(dir < 0)
   {
      bool ok = c < o && c < bufEntryFast[1] && bufEntryFast[1] < bufEntrySlow[1];

      if(InpRequireCloseBeyondPrev)
         ok = ok && c < l2;

      return ok;
   }

   return false;
}

int EntrySignal()
{
   int dir = TrendDirection();

   if(InpSignalMode == GBT_BUY_ONLY && dir < 0)
      return 0;

   if(InpSignalMode == GBT_SELL_ONLY && dir > 0)
      return 0;

   if(dir == 0)
   {
      g_lastStatus = "No trend direction";
      return 0;
   }

   if(!ADXOK(dir))
      return 0;

   if(!EntryCandleOK(dir))
      return 0;

   if(InpProbeStyle == GBT_PROBE_TREND_AND_TICK)
   {
      int tickDir = TickImpulseDirection();

      if(tickDir != dir)
      {
         g_lastStatus = "Waiting matching tick impulse";
         return 0;
      }
   }

   g_lastStatus = DirName(dir) + " signal confirmed";
   return dir;
}

//====================================================================
// POSITION / BASKET HELPERS
//====================================================================
int CountPositionsByType(long typeFilter)
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);

      if(type == typeFilter)
         count++;
   }

   return count;
}

int CountAllManagedPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      count++;
   }

   return count;
}

double TotalManagedLots()
{
   double lots = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      lots += PositionGetDouble(POSITION_VOLUME);
   }

   return lots;
}

bool BasketStats(long typeFilter,
                 int &count,
                 double &lots,
                 double &profit,
                 datetime &oldestTime,
                 ulong &oldestTicket,
                 double &latestEntryPrice,
                 datetime &latestTime)
{
   count = 0;
   lots = 0.0;
   profit = 0.0;
   oldestTime = 0;
   oldestTicket = 0;
   latestEntryPrice = 0.0;
   latestTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);

      if(type != typeFilter)
         continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

      count++;
      lots += PositionGetDouble(POSITION_VOLUME);
      profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      if(oldestTime == 0 || openTime < oldestTime)
      {
         oldestTime = openTime;
         oldestTicket = ticket;
      }

      if(openTime >= latestTime)
      {
         latestTime = openTime;
         latestEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }

   return (count > 0);
}

double PositionProfitPoints(long type, double openPrice, MqlTick &tick)
{
   if(type == POSITION_TYPE_BUY)
      return (tick.bid - openPrice) / _Point;

   if(type == POSITION_TYPE_SELL)
      return (openPrice - tick.ask) / _Point;

   return 0.0;
}

//====================================================================
// ORDERS
//====================================================================
double StopDistancePoints()
{
   double wanted = InpFixedSLPoints;

   if(InpStopMode == GBT_STOP_ATR)
   {
      double atrPts = ATRPoints();

      if(atrPts <= 0.0)
         return 0.0;

      wanted = atrPts * InpATRSLMultiplier;
   }

   double brokerMin = BrokerStopDistancePoints();

   return MathMax(wanted, brokerMin);
}

double CalculateLot(int dir, double entry, double sl, bool isProbe)
{
   double lot = (isProbe ? InpProbeLot : InpBurstLot);

   if(InpLotMode == GBT_LOT_RISK_PERCENT)
   {
      double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;

      if(riskMoney > 0.0 && sl > 0.0)
      {
         ENUM_ORDER_TYPE orderType = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
         double profitForOneLot = 0.0;

         if(OrderCalcProfit(orderType, _Symbol, 1.0, entry, sl, profitForOneLot))
         {
            double lossPerLot = MathAbs(profitForOneLot);

            if(lossPerLot > 0.0)
               lot = riskMoney / lossPerLot;
         }
      }
   }

   double normalized = NormalizeVolumeFloor(lot);

   return normalized;
}

bool TradeRetcodeOK()
{
   uint ret = trade.ResultRetcode();

   return (ret == TRADE_RETCODE_DONE ||
           ret == TRADE_RETCODE_PLACED ||
           ret == TRADE_RETCODE_DONE_PARTIAL);
}

bool CanOpenAny()
{
   if(g_dayLocked)
      return false;

   if(TimeCurrent() < g_globalPauseUntil)
   {
      g_lastStatus = "Global cooldown active";
      return false;
   }

   if(InpMaxTradesPerDay > 0 && g_tradesToday >= InpMaxTradesPerDay)
   {
      g_lastStatus = "Max daily trades reached";
      return false;
   }

   if(CountAllManagedPositions() >= InpMaxTotalPositions)
   {
      g_lastStatus = "Max total positions reached";
      return false;
   }

   if(TotalManagedLots() >= InpMaxTotalLots)
   {
      g_lastStatus = "Max total lots reached";
      return false;
   }

   return true;
}

bool CanOpenDirection(int dir)
{
   if(!CanOpenAny())
      return false;

   int idx = DirToIndex(dir);

   if(TimeCurrent() < g_directionPauseUntil[idx])
   {
      g_lastStatus = DirName(dir) + " pause active";
      return false;
   }

   long type = DirToPositionType(dir);
   long opposite = DirToPositionType(-dir);

   int sameCount = CountPositionsByType(type);
   int oppositeCount = CountPositionsByType(opposite);

   if(sameCount >= InpMaxPositionsPerSide)
   {
      g_lastStatus = DirName(dir) + " max side positions";
      return false;
   }

   if(oppositeCount > 0 && !InpAllowHedgeBuySell)
   {
      g_lastStatus = "Opposite basket active";
      return false;
   }

   if(oppositeCount > 0 && InpAllowHedgeBuySell && !IsHedgingAccount())
   {
      g_lastStatus = "Hedging not supported";
      return false;
   }

   return true;
}

bool OpenTrade(int dir, bool isProbe)
{
   if(!CanOpenDirection(dir))
      return false;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double entry = (dir > 0 ? tick.ask : tick.bid);

   if(entry <= 0.0)
      return false;

   double stopPts = StopDistancePoints();

   if(stopPts <= 0.0)
      return false;

   double sl = 0.0;

   if(dir > 0)
      sl = NormalizePrice(entry - stopPts * _Point);
   else
      sl = NormalizePrice(entry + stopPts * _Point);

   double lot = CalculateLot(dir, entry, sl, isProbe);

   if(lot <= 0.0)
   {
      g_lastStatus = "Lot zero";
      return false;
   }

   if(TotalManagedLots() + lot > InpMaxTotalLots + 0.0000001)
   {
      g_lastStatus = "Total lot cap";
      return false;
   }

   trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   string comment = (isProbe ? "GBT PROBE " : "GBT BURST ");
   comment += DirName(dir);

   bool sent = false;

   if(dir > 0)
      sent = trade.Buy(lot, _Symbol, 0.0, sl, 0.0, comment);
   else
      sent = trade.Sell(lot, _Symbol, 0.0, sl, 0.0, comment);

   if(!sent || !TradeRetcodeOK())
   {
      g_lastStatus = StringFormat("Open failed %u %s",
                                  trade.ResultRetcode(),
                                  trade.ResultRetcodeDescription());

      if(InpDebug)
         Print(InpEAName, ": ", g_lastStatus);

      return false;
   }

   int idx = DirToIndex(dir);

   g_tradesToday++;
   g_lastEntryMS = g_lastTickMS;

   if(isProbe)
   {
      g_confirmed[idx] = false;
      g_basketStartTime[idx] = TimeCurrent();
      g_basketPeakProfit[idx] = 0.0;
      g_lastAddMS[idx] = g_lastTickMS;
   }

   if(InpDebug)
   {
      Print(InpEAName,
            ": opened ",
            (isProbe ? "PROBE " : "BURST "),
            DirName(dir),
            " lot=",
            DoubleToString(lot, VolumeDigits()),
            " sl=",
            DoubleToString(sl, _Digits),
            " spread=",
            CurrentSpreadPoints());
   }

   if(InpEnableAlerts)
      Alert(InpEAName + " " + comment);

   if(InpEnableSound)
      PlaySound(dir > 0 ? InpBuySound : InpSellSound);

   return true;
}

//====================================================================
// CLOSE / MODIFY
//====================================================================
bool ClosePositionByTicket(ulong ticket, string reason)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   if(trade.PositionClose(ticket))
   {
      if(InpDebug)
         Print(InpEAName, ": closed ticket ", ticket, " | ", reason);

      return true;
   }

   if(InpDebug)
      Print(InpEAName, ": close failed ticket ", ticket, " | ", trade.ResultRetcodeDescription());

   return false;
}

void ClosePositionsByType(long typeFilter, string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);

      if(type != typeFilter)
         continue;

      ClosePositionByTicket(ticket, reason);
   }
}

bool ModifySLIfBetter(ulong ticket, long type, double requestedSL, double tp, string reason)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double minDist = BrokerStopDistancePoints() * _Point;
   double newSL = requestedSL;

   if(type == POSITION_TYPE_BUY)
   {
      double maxAllowed = tick.bid - minDist;

      if(newSL > maxAllowed)
         newSL = maxAllowed;

      newSL = NormalizePrice(newSL);
   }
   else
   {
      double minAllowed = tick.ask + minDist;

      if(newSL < minAllowed)
         newSL = minAllowed;

      newSL = NormalizePrice(newSL);
   }

   double currentSL = PositionGetDouble(POSITION_SL);
   double step = MathMax(1.0, InpTrailStepPoints) * _Point;

   bool better = false;

   if(type == POSITION_TYPE_BUY)
      better = (currentSL <= 0.0 || newSL > currentSL + step);
   else
      better = (currentSL <= 0.0 || newSL < currentSL - step);

   if(!better)
      return false;

   trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   if(trade.PositionModify(ticket, newSL, tp) && TradeRetcodeOK())
   {
      GlobalVariableSet(StateKey(ticket, "lasttrail"), (double)TimeCurrent());

      if(InpDebug)
      {
         Print(InpEAName,
               ": SL moved ticket ",
               ticket,
               " to ",
               DoubleToString(newSL, _Digits),
               " | ",
               reason);
      }

      return true;
   }

   return false;
}

void ProtectIndividualPositions()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double atrPts = ATRPoints();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double tp = PositionGetDouble(POSITION_TP);
      double profitPts = PositionProfitPoints(type, openPrice, tick);

      if(InpUseBreakEven && profitPts >= InpBETriggerPoints)
      {
         double beSL = 0.0;

         if(type == POSITION_TYPE_BUY)
            beSL = openPrice + InpBEPlusPoints * _Point;
         else
            beSL = openPrice - InpBEPlusPoints * _Point;

         ModifySLIfBetter(ticket, type, beSL, tp, "break-even");
      }

      if(InpUseTrailing && profitPts >= InpTrailStartPoints)
      {
         bool throttleOK = true;

         if(GlobalVariableCheck(StateKey(ticket, "lasttrail")))
         {
            datetime lastTrail = (datetime)GlobalVariableGet(StateKey(ticket, "lasttrail"));

            if((TimeCurrent() - lastTrail) < InpMinSecondsBetweenTrailUpdates)
               throttleOK = false;
         }

         if(throttleOK)
         {
            double trailPts = MathMax(InpTrailMinPoints, atrPts * InpTrailATRMultiplier);
            double trailSL = 0.0;

            if(type == POSITION_TYPE_BUY)
               trailSL = tick.bid - trailPts * _Point;
            else
               trailSL = tick.ask + trailPts * _Point;

            ModifySLIfBetter(ticket, type, trailSL, tp, "ATR trail");
         }
      }
   }
}

//====================================================================
// PROBE / BASKET MANAGEMENT
//====================================================================
double DynamicProbeConfirmPoints()
{
   return MathMax(InpProbeConfirmPoints, (double)CurrentSpreadPoints() * InpProbeConfirmSpreadMult);
}

void RegisterBasketLoss(int dir, string reason)
{
   int idx = DirToIndex(dir);

   g_probeFailsToday[idx]++;

   int pauseSec = InpDirectionPauseAfterProbeFailSec;

   if(InpMaxProbeFailsBeforeLongPause > 0 &&
      g_probeFailsToday[idx] >= InpMaxProbeFailsBeforeLongPause)
   {
      pauseSec = MathMax(pauseSec, InpLongDirectionPauseSec);
      g_probeFailsToday[idx] = 0;
   }

   g_directionPauseUntil[idx] = TimeCurrent() + pauseSec;
   g_confirmed[idx] = false;
   g_basketStartTime[idx] = 0;
   g_basketPeakProfit[idx] = 0.0;

   if(InpDebug)
   {
      Print(InpEAName,
            ": ",
            DirName(dir),
            " failed -> pause ",
            pauseSec,
            " sec | ",
            reason);
   }
}

void ResetDirectionIfFlat(int dir)
{
   long type = DirToPositionType(dir);

   if(CountPositionsByType(type) == 0)
   {
      int idx = DirToIndex(dir);
      g_confirmed[idx] = false;
      g_basketStartTime[idx] = 0;
      g_basketPeakProfit[idx] = 0.0;
      g_lastAddMS[idx] = 0;
   }
}

void ManageDirection(int dir, int freshSignal)
{
   int idx = DirToIndex(dir);
   long type = DirToPositionType(dir);

   int count;
   double lots;
   double profit;
   datetime oldestTime;
   ulong oldestTicket;
   double latestEntryPrice;
   datetime latestTime;

   bool hasBasket = BasketStats(type,
                                count,
                                lots,
                                profit,
                                oldestTime,
                                oldestTicket,
                                latestEntryPrice,
                                latestTime);

   if(!hasBasket)
   {
      ResetDirectionIfFlat(dir);
      return;
   }

   if(g_basketStartTime[idx] == 0)
      g_basketStartTime[idx] = oldestTime;

   if(profit > g_basketPeakProfit[idx])
      g_basketPeakProfit[idx] = profit;

   int basketAgeSec = (int)(TimeCurrent() - g_basketStartTime[idx]);

   if(InpUseBasketClose)
   {
      if(profit >= InpBasketProfitMoney)
      {
         ClosePositionsByType(type, "basket profit");
         g_consecutiveBasketLosses = 0;
         g_globalPauseUntil = TimeCurrent() + InpCooldownAfterBasketProfitSec;
         g_lastBasketCloseTime = TimeCurrent();
         ResetDirectionIfFlat(dir);
         return;
      }

      if(profit <= InpBasketLossMoney)
      {
         ClosePositionsByType(type, "basket loss");
         g_consecutiveBasketLosses++;
         g_globalPauseUntil = TimeCurrent() + InpCooldownAfterBasketLossSec;
         g_lastBasketCloseTime = TimeCurrent();
         RegisterBasketLoss(dir, "basket loss");
         return;
      }
   }

   if(InpUseBasketProfitTrail &&
      g_basketPeakProfit[idx] >= InpBasketTrailStartMoney &&
      (g_basketPeakProfit[idx] - profit) >= InpBasketTrailGivebackMoney)
   {
      ClosePositionsByType(type, "basket profit trail");
      g_consecutiveBasketLosses = 0;
      g_globalPauseUntil = TimeCurrent() + InpCooldownAfterBasketProfitSec;
      g_lastBasketCloseTime = TimeCurrent();
      ResetDirectionIfFlat(dir);
      return;
   }

   if(InpBasketMaxLifeSeconds > 0 && basketAgeSec >= InpBasketMaxLifeSeconds)
   {
      ClosePositionsByType(type, "basket max-life");

      if(profit < 0.0)
      {
         g_consecutiveBasketLosses++;
         g_globalPauseUntil = TimeCurrent() + InpCooldownAfterBasketLossSec;
         RegisterBasketLoss(dir, "basket max-life loss");
      }
      else
      {
         g_consecutiveBasketLosses = 0;
         g_globalPauseUntil = TimeCurrent() + InpCooldownAfterBasketProfitSec;
         ResetDirectionIfFlat(dir);
      }

      g_lastBasketCloseTime = TimeCurrent();
      return;
   }

   // Probe phase
   if(!g_confirmed[idx])
   {
      if(!PositionSelectByTicket(oldestTicket))
         return;

      MqlTick tick;

      if(!SymbolInfoTick(_Symbol, tick))
         return;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      int ageSec = (int)(TimeCurrent() - openTime);
      double probePts = PositionProfitPoints(type, openPrice, tick);
      double confirmPts = DynamicProbeConfirmPoints();

      if(probePts >= confirmPts || profit >= InpProbeConfirmMoney)
      {
         g_confirmed[idx] = true;
         g_basketPeakProfit[idx] = MathMax(g_basketPeakProfit[idx], profit);

         if(InpDebug)
         {
            Print(InpEAName,
                  ": ",
                  DirName(dir),
                  " probe confirmed | pts=",
                  DoubleToString(probePts, 1),
                  " money=",
                  DoubleToString(profit, 2),
                  " confirmPts=",
                  DoubleToString(confirmPts, 1));
         }
      }
      else if(probePts <= -MathAbs(InpProbeFailPoints) || profit <= InpProbeFailMoney)
      {
         ClosePositionsByType(type, "probe fail");
         g_consecutiveBasketLosses++;
         RegisterBasketLoss(dir, "probe fail");
         return;
      }
      else if(ageSec >= InpProbeMaxSeconds && probePts < InpProbeTimeoutMinPoints)
      {
         ClosePositionsByType(type, "probe timeout");
         if(profit < 0.0)
         {
            g_consecutiveBasketLosses++;
            RegisterBasketLoss(dir, "probe timeout loss");
         }
         else
         {
            ResetDirectionIfFlat(dir);
         }
         return;
      }
      else
      {
         return;
      }
   }

   if(!g_confirmed[idx])
      return;

   if(count >= InpMaxPositionsPerSide)
      return;

   if(CountAllManagedPositions() >= InpMaxTotalPositions)
      return;

   if(TotalManagedLots() + InpBurstLot > InpMaxTotalLots + 0.0000001)
      return;

   if(profit < InpMinBasketProfitToAdd)
      return;

   if(InpRequireFreshSignalToAdd && freshSignal != dir)
      return;

   if((g_lastTickMS - g_lastAddMS[idx]) < (long)InpMinSecondsBetweenAdds * 1000)
      return;

   if(InpAddOnlyIfPriceImproves || InpMinSameSideSpacingPoints > 0.0)
   {
      MqlTick tick;

      if(SymbolInfoTick(_Symbol, tick))
      {
         double priceNow = (dir > 0 ? tick.ask : tick.bid);

         if(InpAddOnlyIfPriceImproves)
         {
            if(dir > 0 && priceNow <= latestEntryPrice)
               return;

            if(dir < 0 && priceNow >= latestEntryPrice)
               return;
         }

         if(InpMinSameSideSpacingPoints > 0.0)
         {
            if(MathAbs(priceNow - latestEntryPrice) < InpMinSameSideSpacingPoints * _Point)
               return;
         }
      }
   }

   int adds = MathMax(1, InpBurstOrdersPerAdd);

   for(int n = 0; n < adds; n++)
   {
      if(!OpenTrade(dir, false))
         break;

      g_lastAddMS[idx] = g_lastTickMS;
   }
}

bool TryOpenProbe(int signal)
{
   if(signal == 0)
      return false;

   long type = DirToPositionType(signal);

   if(CountPositionsByType(type) > 0)
      return false;

   return OpenTrade(signal, true);
}

//====================================================================
// DASHBOARD
//====================================================================
void DrawDashboard()
{
   if(!InpShowDashboard)
   {
      Comment("");
      return;
   }

   int buyCount = CountPositionsByType(POSITION_TYPE_BUY);
   int sellCount = CountPositionsByType(POSITION_TYPE_SELL);

   int bCount;
   double bLots;
   double bProfit;
   datetime bOld;
   ulong bTicket;
   double bLatest;
   datetime bLatestTime;

   int sCount;
   double sLots;
   double sProfit;
   datetime sOld;
   ulong sTicket;
   double sLatest;
   datetime sLatestTime;

   BasketStats(POSITION_TYPE_BUY, bCount, bLots, bProfit, bOld, bTicket, bLatest, bLatestTime);
   BasketStats(POSITION_TYPE_SELL, sCount, sLots, sProfit, sOld, sTicket, sLatest, sLatestTime);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayDDPct = 0.0;

   if(g_dayStartEquity > 0.0)
      dayDDPct = 100.0 * (g_dayStartEquity - equity) / g_dayStartEquity;

   string text = StringFormat(
      "%s\nSymbol: %s | Spread: %d/%d | ATR: %.1f | Signal status: %s\nB/S/T positions: %d/%d/%d | Lots %.2f/%.2f | B P/L %.2f | S P/L %.2f\nConfirmed B/S: %s/%s | Pause B/S: %d/%d sec | Global pause: %d sec\nDay P/L %.2f | DD %.2f%% | Trades %d/%d | Basket losses %d/%d | Locked: %s",
      InpEAName,
      _Symbol,
      CurrentSpreadPoints(),
      InpMaxSpreadPoints,
      ATRPoints(),
      g_lastStatus,
      buyCount,
      sellCount,
      CountAllManagedPositions(),
      TotalManagedLots(),
      InpMaxTotalLots,
      bProfit,
      sProfit,
      g_confirmed[0] ? "YES" : "NO",
      g_confirmed[1] ? "YES" : "NO",
      (int)MathMax(0, (int)(g_directionPauseUntil[0] - TimeCurrent())),
      (int)MathMax(0, (int)(g_directionPauseUntil[1] - TimeCurrent())),
      (int)MathMax(0, (int)(g_globalPauseUntil - TimeCurrent())),
      g_dayProfit,
      dayDDPct,
      g_tradesToday,
      InpMaxTradesPerDay,
      g_consecutiveBasketLosses,
      InpMaxConsecutiveBasketLosses,
      g_dayLocked ? "YES" : "NO"
   );

   Comment(text);
}

//====================================================================
// EVENTS
//====================================================================
int OnInit()
{
   ArraySetAsSeries(bufTrendFast, true);
   ArraySetAsSeries(bufTrendSlow, true);
   ArraySetAsSeries(bufTrendAnchor, true);
   ArraySetAsSeries(bufBiasEMA, true);
   ArraySetAsSeries(bufEntryFast, true);
   ArraySetAsSeries(bufEntrySlow, true);
   ArraySetAsSeries(bufATR, true);
   ArraySetAsSeries(bufADX, true);
   ArraySetAsSeries(bufPlusDI, true);
   ArraySetAsSeries(bufMinusDI, true);
   ArraySetAsSeries(ratesTrend, true);
   ArraySetAsSeries(ratesBias, true);
   ArraySetAsSeries(ratesEntry, true);

   hTrendFast   = iMA(_Symbol, InpTrendTF, InpTrendFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hTrendSlow   = iMA(_Symbol, InpTrendTF, InpTrendSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hTrendAnchor = iMA(_Symbol, InpTrendTF, InpTrendAnchorEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEntryFast   = iMA(_Symbol, InpEntryTF, InpEntryFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEntrySlow   = iMA(_Symbol, InpEntryTF, InpEntrySlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR         = iATR(_Symbol, InpATRTF, InpATRPeriod);
   hADX         = iADX(_Symbol, InpEntryTF, InpADXPeriod);

   if(InpUseBiasFilter)
      hBiasEMA = iMA(_Symbol, InpBiasTF, InpBiasEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(hTrendFast == INVALID_HANDLE ||
      hTrendSlow == INVALID_HANDLE ||
      hTrendAnchor == INVALID_HANDLE ||
      hEntryFast == INVALID_HANDLE ||
      hEntrySlow == INVALID_HANDLE ||
      hATR == INVALID_HANDLE ||
      hADX == INVALID_HANDLE ||
      (InpUseBiasFilter && hBiasEMA == INVALID_HANDLE))
   {
      Print(InpEAName, ": indicator handle failed");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetMarginMode();

   for(int i = 0; i < GBT_TICK_BUF; i++)
   {
      g_midTicks[i] = 0.0;
      g_tickMS[i] = 0;
   }

   g_confirmed[0] = false;
   g_confirmed[1] = false;
   g_basketStartTime[0] = 0;
   g_basketStartTime[1] = 0;
   g_basketPeakProfit[0] = 0.0;
   g_basketPeakProfit[1] = 0.0;
   g_directionPauseUntil[0] = 0;
   g_directionPauseUntil[1] = 0;
   g_probeFailsToday[0] = 0;
   g_probeFailsToday[1] = 0;
   g_lastAddMS[0] = 0;
   g_lastAddMS[1] = 0;

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   g_dayKey = tm.year * 10000 + tm.mon * 100 + tm.day;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   Print("============================================================");
   Print(InpEAName, " initialized on ", _Symbol);
   Print("Mode: EDGE-FIRST BURST TREND | TrendTF=", EnumToString(InpTrendTF),
         " EntryTF=", EnumToString(InpEntryTF),
         " BiasTF=", EnumToString(InpBiasTF));
   Print("Trend: EMA ", InpTrendFastEMA, "/", InpTrendSlowEMA,
         " anchor=", InpTrendAnchorEMA,
         " bias=", (InpUseBiasFilter ? "ON" : "OFF"));
   Print("Probe confirm: ",
         DoubleToString(InpProbeConfirmPoints, 1),
         " pts or $",
         DoubleToString(InpProbeConfirmMoney, 2),
         " | spread mult ",
         DoubleToString(InpProbeConfirmSpreadMult, 2));
   Print("Basket: target $",
         DoubleToString(InpBasketProfitMoney, 2),
         " loss $",
         DoubleToString(InpBasketLossMoney, 2),
         " max life ",
         InpBasketMaxLifeSeconds,
         " sec");
   Print("Exposure: probe lot ",
         DoubleToString(InpProbeLot, 2),
         " burst lot ",
         DoubleToString(InpBurstLot, 2),
         " max positions ",
         InpMaxTotalPositions,
         " max lots ",
         DoubleToString(InpMaxTotalLots, 2));
   Print("============================================================");

   DrawDashboard();

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");

   if(hTrendFast != INVALID_HANDLE)   IndicatorRelease(hTrendFast);
   if(hTrendSlow != INVALID_HANDLE)   IndicatorRelease(hTrendSlow);
   if(hTrendAnchor != INVALID_HANDLE) IndicatorRelease(hTrendAnchor);
   if(hBiasEMA != INVALID_HANDLE)     IndicatorRelease(hBiasEMA);
   if(hEntryFast != INVALID_HANDLE)   IndicatorRelease(hEntryFast);
   if(hEntrySlow != INVALID_HANDLE)   IndicatorRelease(hEntrySlow);
   if(hATR != INVALID_HANDLE)         IndicatorRelease(hATR);
   if(hADX != INVALID_HANDLE)         IndicatorRelease(hADX);
}

void OnTick()
{
   ResetDailyStatsIfNeeded();

   MqlTick tick;

   if(!UpdateTickBuffer(tick))
   {
      DrawDashboard();
      return;
   }

   if(!RefreshMarketData())
   {
      ProtectIndividualPositions();
      DrawDashboard();
      return;
   }

   ProtectIndividualPositions();

   int signal = EntrySignal();

   ManageDirection(1, signal);
   ManageDirection(-1, signal);

   if(!TradingAllowed() || !SessionOK() || !VolatilityAndSpreadOK())
   {
      DrawDashboard();
      return;
   }

   TryOpenProbe(signal);

   DrawDashboard();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong deal = trans.deal;

   if(deal == 0 || !HistoryDealSelect(deal))
      return;

   string symbol = HistoryDealGetString(deal, DEAL_SYMBOL);
   long magic = HistoryDealGetInteger(deal, DEAL_MAGIC);
   long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);

   if(symbol != _Symbol || magic != InpMagicNumber)
      return;

   if(entry == DEAL_ENTRY_OUT ||
      entry == DEAL_ENTRY_INOUT ||
      entry == DEAL_ENTRY_OUT_BY)
   {
      double profit =
         HistoryDealGetDouble(deal, DEAL_PROFIT) +
         HistoryDealGetDouble(deal, DEAL_SWAP) +
         HistoryDealGetDouble(deal, DEAL_COMMISSION);

      g_dayProfit += profit;

      if(InpDebug)
      {
         long reason = HistoryDealGetInteger(deal, DEAL_REASON);

         Print(InpEAName,
               ": close deal ",
               deal,
               " profit=",
               DoubleToString(profit, 2),
               " dayProfit=",
               DoubleToString(g_dayProfit, 2),
               " reason=",
               reason);
      }
   }
}
//+------------------------------------------------------------------+
