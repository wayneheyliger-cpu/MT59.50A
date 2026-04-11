//+------------------------------------------------------------------+
//| MA Crossover EA - Hedge + ATR Risk Sizing + Drawdown Pause (v3.55)|
//| PATCHED: Real hedge trigger, basket close, anti-chop, post-SL    |
//| aggressive hedge trailing / immediate hedge close options         |
//| v3.52: FIX - hedge trigger now runs every tick (not per-candle)  |
//| v3.53: DIAG - preset-override warnings, per-candle hedge status  |
//| v3.54: FIX - MaxHedgesPerPrimaryTrade=0 now means unlimited      |
//| v3.55: FIX - MinProfitPipsToCloseRecovery now requires basket>=0 |
//+------------------------------------------------------------------+
#property copyright "xAI Grok"
#property version   "3.53"
#property strict
#include <Trade/Trade.mqh>

//=== CONFIG =========================================================
input string EA_Name        = "MA_Crossover_EA_Hedge_Double_v3_55";
input double LotSize        = 0.10;
input double MaxLotSize     = 2.0;

enum ENUM_MODE {MODE_DAYTRADING=0, MODE_SCALPING=1};
input ENUM_MODE TradingMode = MODE_DAYTRADING;
input bool UsePresets       = true;

input ENUM_MA_METHOD     MAFastMethod   = MODE_SMA;
input ENUM_APPLIED_PRICE MAFastPrice    = PRICE_CLOSE;
input ENUM_MA_METHOD     MASlowMethod   = MODE_SMA;
input ENUM_APPLIED_PRICE MASlowPrice    = PRICE_CLOSE;

input int    InpMAFastPeriod         = 5;
input int    InpMASlowPeriod         = 100;
input double MinMASepEntryPips       = 0.0;   // Min fast/slow MA separation to allow entry (0 = disabled)

input int    InpATR_Period           = 14;
input double InpATR_SL_Mult          = 3.0;
input double InpATR_TP_Mult          = 6.0;
input double InpATR_TrailStart_Mult  = 3.0;
input double InpATR_TrailStep_Mult   = 1.0;

input double InpRiskPercent          = 0.50;
input int    InpMaxTradesPerDirection= 2;
input int    InpCooldownCandles      = 20;

input double MaxDrawdownPercent      = 15.0;
input int    MagicNumber             = 17635;

input bool   EnableAlerts            = true;
input bool   EnableNotifications     = false;
input bool   EnableEmail             = false;

input bool   UseTrailingStop         = true;
input bool   UseBreakEven            = true;
input double BreakEvenTriggerPips    = 150;
input double BreakEvenPlusPips       = 10;

input bool   UsePartialClose         = false;
input double PartialClosePips        = 20.0;
input double PartialClosePercent     = 50.0;

input double TrailBufferPips         = 0.0;
input double HedgeLotMultiplier      = 1.30;

input bool   UseSessionFilter        = true;
input int    LondonOpenHour          = 8;
input int    NYCloseHour             = 22;


input bool   DebugMode               = true;

//=== HEDGE PATCH SETTINGS ===========================================
input bool   UseHedgeTriggerPips          = true;
input double HedgeTriggerPips             = 50.0;
input double HedgeTriggerATRMult          = 0.50;

input bool   CloseHedgeOnlyOnBasketProfit = true;
input double BasketCloseProfitMoney       = 5.0;
input double MinProfitPipsToCloseRecovery = 2.0; // Primary must be at least this many pips positive before recovery is auto-closed

input int    MaxHedgesPerPrimaryTrade     = 1;  // Max hedge trades per primary (0 = unlimited)

input double MinATRForHedgePips           = 25.0;
input double MinMAGapPips                 = 0.0;

input int    MaxHedgeBarsOpen             = 0;     // 0 = disabled

//=== RECOVERY/HEDGE TRADE PROTECTION =================================
input double HedgeTPPips                = 40.0;  // Fixed TP on hedge trade in pips (0 = disabled)
input double HedgeBreakEvenTriggerPips  = 0.0;   // Move hedge SL to BE after this many pips profit (0 = disabled)
input double HedgeBreakEvenPlusPips     = 5.0;   // Lock in this many extra pips when BE triggers
input double HedgeTrailStartPips        = 0.0;   // Start trailing hedge after this many pips profit (0 = disabled)
input double HedgeTrailDistancePips     = 15.0;  // Trailing distance for hedge (pips)
input double HedgeTrailStepPips         = 3.0;   // Min step before moving hedge trail SL (pips)

//=== POST-PRIMARY-CLOSE HEDGE MANAGEMENT ============================
input bool   CloseHedgeImmediatelyAfterPrimarySL = false;
input bool   UseAggressiveTrailAfterPrimarySL    = true;
input double AggTrailStartPips                   = 5.0;
input double AggTrailDistancePips                = 10.0;
input double AggTrailStepPips                    = 3.0;

//=== PRESETS =========================================================
#define DAY_MA_FAST_PERIOD       5
#define DAY_MA_SLOW_PERIOD       34
#define DAY_ATR_SL_MULT          2.5
#define DAY_ATR_TP_MULT          5.0
#define DAY_ATR_TRAIL_START_MULT 3.0
#define DAY_ATR_TRAIL_STEP_MULT  1.0
#define DAY_RISK_PERCENT         0.3
#define DAY_MAX_TRADES_PER_DIR   2
#define DAY_COOLDOWN_CANDLES     15

#define SCALP_MA_FAST_PERIOD       2
#define SCALP_MA_SLOW_PERIOD       7
#define SCALP_ATR_SL_MULT          1.0
#define SCALP_ATR_TP_MULT          1.5
#define SCALP_ATR_TRAIL_START_MULT 1.0
#define SCALP_ATR_TRAIL_STEP_MULT  0.5
#define SCALP_RISK_PERCENT         0.1
#define SCALP_MAX_TRADES_PER_DIR   1
#define SCALP_COOLDOWN_CANDLES     3

//=== RUNTIME VARIABLES ==============================================
int    MAFastPeriod, MASlowPeriod;
int    ATR_Period;
double ATR_SL_Mult, ATR_TP_Mult, ATR_TrailStart_Mult, ATR_TrailStep_Mult;
double RiskPercent;
int    MaxTradesPerDirection, CooldownCandles;

//=== GLOBALS ========================================================
enum ENUM_TRADE_SIGNAL { SIGNAL_BUY=1, SIGNAL_SELL=-1, SIGNAL_NEUTRAL=0 };
CTrade trade;
int     FastMAHandle  = INVALID_HANDLE;
int     SlowMAHandle  = INVALID_HANDLE;
int     ATRHandle     = INVALID_HANDLE;
double  FastMA[];
double  SlowMA[];
double  ATRBuf[];
datetime lastCandleTime = 0;
double   PeakEquity  = 0.0;
int      buyCount=0,sellCount=0;
int      cooldownBarsRemaining=0;
ulong    trackedTickets[];
datetime trackedOpenCandle[];
double   trackedVolume[];
int      trackedType[];
bool     trackedIsSecond[];
int      trackedHedgeCount[];
ulong    trackedParentTicket[];
bool     trackedPostSLTrail[];
bool     g_PartialClosed = false;
datetime g_lastHedgeStatusBar = 0;  // throttle per-candle hedge status print

//+------------------------------------------------------------------+
void ApplyModeSettings()
{
   MAFastPeriod          = InpMAFastPeriod;
   MASlowPeriod          = InpMASlowPeriod;
   ATR_Period            = InpATR_Period;
   ATR_SL_Mult           = InpATR_SL_Mult;
   ATR_TP_Mult           = InpATR_TP_Mult;
   ATR_TrailStart_Mult   = InpATR_TrailStart_Mult;
   ATR_TrailStep_Mult    = InpATR_TrailStep_Mult;
   RiskPercent           = InpRiskPercent;
   MaxTradesPerDirection = InpMaxTradesPerDirection;
   CooldownCandles       = InpCooldownCandles;

   if(!UsePresets) return;

   if(TradingMode == MODE_DAYTRADING)
   {
      MAFastPeriod          = DAY_MA_FAST_PERIOD;
      MASlowPeriod          = DAY_MA_SLOW_PERIOD;
      ATR_SL_Mult           = DAY_ATR_SL_MULT;
      ATR_TP_Mult           = DAY_ATR_TP_MULT;
      ATR_TrailStart_Mult   = DAY_ATR_TRAIL_START_MULT;
      ATR_TrailStep_Mult    = DAY_ATR_TRAIL_STEP_MULT;
      RiskPercent           = DAY_RISK_PERCENT;
      MaxTradesPerDirection = DAY_MAX_TRADES_PER_DIR;
      CooldownCandles       = DAY_COOLDOWN_CANDLES;
   }
   else
   {
      MAFastPeriod          = SCALP_MA_FAST_PERIOD;
      MASlowPeriod          = SCALP_MA_SLOW_PERIOD;
      ATR_SL_Mult           = SCALP_ATR_SL_MULT;
      ATR_TP_Mult           = SCALP_ATR_TP_MULT;
      ATR_TrailStart_Mult   = SCALP_ATR_TRAIL_START_MULT;
      ATR_TrailStep_Mult    = SCALP_ATR_TRAIL_STEP_MULT;
      RiskPercent           = SCALP_RISK_PERCENT;
      MaxTradesPerDirection = SCALP_MAX_TRADES_PER_DIR;
      CooldownCandles       = SCALP_COOLDOWN_CANDLES;
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   Print(EA_Name,": Init v3.55 - Fix: MinProfitPipsToCloseRecovery now requires basket net >= 0");
   ApplyModeSettings();
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   // Warn the user when UsePresets silently overrides their manual inputs
   if(UsePresets)
   {
      string mode = (TradingMode == MODE_DAYTRADING) ? "DAY" : "SCALP";
      double presetSL   = (TradingMode == MODE_DAYTRADING) ? DAY_ATR_SL_MULT   : SCALP_ATR_SL_MULT;
      double presetTP   = (TradingMode == MODE_DAYTRADING) ? DAY_ATR_TP_MULT   : SCALP_ATR_TP_MULT;
      int    presetFast = (TradingMode == MODE_DAYTRADING) ? DAY_MA_FAST_PERIOD : SCALP_MA_FAST_PERIOD;
      int    presetSlow = (TradingMode == MODE_DAYTRADING) ? DAY_MA_SLOW_PERIOD : SCALP_MA_SLOW_PERIOD;
      Print("--- UsePresets=true (",mode," mode) is ACTIVE: your manual inputs below are OVERRIDDEN ---");
      if(InpATR_SL_Mult != presetSL)
         PrintFormat("  InpATR_SL_Mult   : %.2f (your input) IGNORED -> %.2f (preset)", InpATR_SL_Mult, presetSL);
      if(InpATR_TP_Mult != presetTP)
         PrintFormat("  InpATR_TP_Mult   : %.2f (your input) IGNORED -> %.2f (preset)", InpATR_TP_Mult, presetTP);
      if(InpMAFastPeriod != presetFast)
         PrintFormat("  InpMAFastPeriod  : %d (your input) IGNORED -> %d (preset)", InpMAFastPeriod, presetFast);
      if(InpMASlowPeriod != presetSlow)
         PrintFormat("  InpMASlowPeriod  : %d (your input) IGNORED -> %d (preset)", InpMASlowPeriod, presetSlow);
      PrintFormat("  Effective SL = %.2f x ATR  |  Hedge fires at %.0f pips adverse (%.1f%% of SL if ATR=MinATR)",
                  ATR_SL_Mult, HedgeTriggerPips, MinATRForHedgePips>0 ? HedgeTriggerPips/(ATR_SL_Mult*MinATRForHedgePips)*100.0 : 0.0);
      if(UseHedgeTriggerPips && MinATRForHedgePips > 0 && HedgeTriggerPips >= ATR_SL_Mult * MinATRForHedgePips)
         PrintFormat("  *** WARNING: HedgeTriggerPips (%.0f) >= effective min-SL (%.0f). Hedge may never fire before SL! Set HedgeTriggerPips < %.0f ***",
                     HedgeTriggerPips, ATR_SL_Mult * MinATRForHedgePips, ATR_SL_Mult * MinATRForHedgePips);
      Print("----------------------------------------------------------------------");
   }

   if(MAFastPeriod < 2)
   {
      Print("ERROR: MAFastPeriod must be >= 2 (current value: ",MAFastPeriod,"). Period of 1 is not valid.");
      return(INIT_FAILED);
   }
   if(MASlowPeriod <= MAFastPeriod)
   {
      Print("ERROR: MASlowPeriod (",MASlowPeriod,") must be greater than MAFastPeriod (",MAFastPeriod,").");
      return(INIT_FAILED);
   }
   if(ATR_Period < 1)
   {
      Print("ERROR: ATR_Period must be >= 1 (current value: ",ATR_Period,").");
      return(INIT_FAILED);
   }

   FastMAHandle = iMA(_Symbol,_Period,MAFastPeriod,0,MAFastMethod,MAFastPrice);
   SlowMAHandle = iMA(_Symbol,_Period,MASlowPeriod,0,MASlowMethod,MASlowPrice);
   ATRHandle    = iATR(_Symbol,_Period,ATR_Period);

   if(FastMAHandle == INVALID_HANDLE || SlowMAHandle == INVALID_HANDLE || ATRHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handle");
      return(INIT_FAILED);
   }

   ArraySetAsSeries(FastMA,true);
   ArraySetAsSeries(SlowMA,true);
   ArraySetAsSeries(ATRBuf,true);

   ArrayResize(trackedTickets,0);
   ArrayResize(trackedOpenCandle,0);
   ArrayResize(trackedVolume,0);
   ArrayResize(trackedType,0);
   ArrayResize(trackedIsSecond,0);
   ArrayResize(trackedHedgeCount,0);
   ArrayResize(trackedParentTicket,0);
   ArrayResize(trackedPostSLTrail,0);

   PeakEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   Print("INIT SUCCESS - v3.55 Ready");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
bool IsNewCandle()
{
   datetime t = iTime(_Symbol,_Period,0);
   if(t == lastCandleTime) return false;
   lastCandleTime = t;
   return true;
}

ENUM_TRADE_SIGNAL GetSignal()
{
   if(ArraySize(FastMA) < 3 || ArraySize(SlowMA) < 3) return SIGNAL_NEUTRAL;
   if(FastMA[2] <= SlowMA[2] && FastMA[1] > SlowMA[1]) return SIGNAL_BUY;
   if(FastMA[2] >= SlowMA[2] && FastMA[1] < SlowMA[1]) return SIGNAL_SELL;
   return SIGNAL_NEUTRAL;
}

void SendSignal(const string sig)
{
   string msg = EA_Name + " " + _Symbol + " -> " + sig + " signal";
   if(EnableAlerts) Alert(msg);
   if(EnableNotifications) SendNotification(msg);
   if(EnableEmail) SendMail(EA_Name + " Signal", msg);
   Print(msg);
}

//+------------------------------------------------------------------+
int FindTrackedIndex(ulong ticket)
{
   for(int i=0; i<ArraySize(trackedTickets); i++)
      if(trackedTickets[i] == ticket) return i;
   return -1;
}

bool IsTicketTracked(ulong ticket)
{
   return (FindTrackedIndex(ticket) >= 0);
}

bool IsHedgePosition(ulong ticket)
{
   int idx = FindTrackedIndex(ticket);
   if(idx < 0) return false;
   return trackedIsSecond[idx];
}

bool HaveOpenHedge()
{
   for(int i=0; i<ArraySize(trackedTickets); i++)
   {
      if(!trackedIsSecond[i]) continue;
      if(PositionSelectByTicket(trackedTickets[i]))
         return true;
   }
   return false;
}

ulong GetPrimaryTicket()
{
   for(int i=0; i<ArraySize(trackedTickets); i++)
   {
      if(trackedIsSecond[i]) continue;
      if(PositionSelectByTicket(trackedTickets[i]))
         return trackedTickets[i];
   }
   return 0;
}

int GetPrimaryHedgeCount(ulong primaryTicket)
{
   int idx = FindTrackedIndex(primaryTicket);
   if(idx < 0) return 0;
   return trackedHedgeCount[idx];
}

void IncrementPrimaryHedgeCount(ulong primaryTicket)
{
   int idx = FindTrackedIndex(primaryTicket);
   if(idx >= 0)
      trackedHedgeCount[idx]++;
}

int BarsSinceTrackedOpen(ulong ticket)
{
   int idx = FindTrackedIndex(ticket);
   if(idx < 0) return 0;
   datetime tOpen = trackedOpenCandle[idx];
   if(tOpen <= 0) return 0;

   int shiftOpen = iBarShift(_Symbol, _Period, tOpen, false);
   int shiftNow  = iBarShift(_Symbol, _Period, iTime(_Symbol, _Period, 0), false);
   if(shiftOpen < 0 || shiftNow < 0) return 0;
   return MathAbs(shiftOpen - shiftNow);
}

void ActivateAggressiveTrailForHedge(ulong hedgeTicket)
{
   int idx = FindTrackedIndex(hedgeTicket);
   if(idx < 0) return;
   trackedPostSLTrail[idx] = true;

   if(DebugMode)
      PrintFormat("[%s] Hedge %I64u switched to aggressive trailing after primary close", EA_Name, hedgeTicket);
}

//+------------------------------------------------------------------+
void ManageHedgeRecovery()
{
   if(CountOpenPositions() == 0) return;

   ulong firstTicket = 0;
   ulong hedgeTicket = 0;
   double firstProfit = 0.0;
   double hedgeProfit = 0.0;

   for(int idx = 0; idx < ArraySize(trackedTickets); idx++)
   {
      ulong t = trackedTickets[idx];
      if(!PositionSelectByTicket(t)) continue;

      if(!trackedIsSecond[idx])
      {
         firstTicket = t;
         firstProfit = PositionGetDouble(POSITION_PROFIT);
      }
      else
      {
         hedgeTicket = t;
         hedgeProfit = PositionGetDouble(POSITION_PROFIT);
      }
   }

   if(firstTicket == 0 && hedgeTicket != 0)
   {
      if(CloseHedgeImmediatelyAfterPrimarySL)
      {
         trade.PositionClose(hedgeTicket);
         UntrackPosition(hedgeTicket);
         PrintFormat("[%s] Primary trade closed -> hedge closed immediately", EA_Name);
         return;
      }

      if(UseAggressiveTrailAfterPrimarySL)
      {
         ActivateAggressiveTrailForHedge(hedgeTicket);
         return;
      }
   }

   if(firstTicket != 0 && hedgeTicket != 0)
   {
      double basketProfit = firstProfit + hedgeProfit;

      if(CloseHedgeOnlyOnBasketProfit)
      {
         if(basketProfit >= BasketCloseProfitMoney)
         {
            trade.PositionClose(hedgeTicket);
            UntrackPosition(hedgeTicket);
            PrintFormat("[%s] Basket profit %.2f reached -> hedge closed", EA_Name, basketProfit);
            return;
         }
      }

      if(MaxHedgeBarsOpen > 0)
      {
         int barsOpen = BarsSinceTrackedOpen(hedgeTicket);
         if(barsOpen >= MaxHedgeBarsOpen)
         {
            trade.PositionClose(hedgeTicket);
            UntrackPosition(hedgeTicket);
            PrintFormat("[%s] Hedge max bars reached (%d) -> hedge closed", EA_Name, barsOpen);
            return;
         }
      }
   }

   // AUTO-CLOSE RECOVERY WHEN PRIMARY RETURNS TO PROFIT
   // When the primary is at least MinProfitPipsToCloseRecovery pips positive AND
   // the basket (primary + recovery) is net >= 0, close the linked recovery.
   // IMPORTANT: we require basket >= 0 to prevent the bleed cycle where the
   // recovery is closed at a large loss (e.g. -52 pips) the moment the primary
   // ticks 2 pips positive, then an unlimited new recovery opens and the cycle
   // repeats. Without the basket check, each cycle burns spread + the recovery loss.
   if(MinProfitPipsToCloseRecovery > 0.0)
   {
      double minPips = MinProfitPipsToCloseRecovery * PipPoint();
      for(int i=0; i<ArraySize(trackedTickets); i++)
      {
         if(trackedIsSecond[i]) continue; // look at primaries only

         ulong primaryTkt = trackedTickets[i];
         if(!PositionSelectByTicket(primaryTkt)) continue;

         double openPx  = PositionGetDouble(POSITION_PRICE_OPEN);
         ENUM_POSITION_TYPE primType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double mktPx   = (primType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                           : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double pipProfit = (primType == POSITION_TYPE_BUY) ? (mktPx - openPx) : (openPx - mktPx);
         if(pipProfit < minPips) continue; // not sufficiently positive yet

         double primaryMoneyProfit = PositionGetDouble(POSITION_PROFIT);

         // Primary is sufficiently positive — close its linked recovery only if basket is net >= 0
         for(int j=ArraySize(trackedTickets)-1; j>=0; j--)
         {
            if(!trackedIsSecond[j]) continue;
            if(trackedParentTicket[j] != primaryTkt) continue;

            ulong recTkt = trackedTickets[j];
            if(!PositionSelectByTicket(recTkt)) continue;

            double recProfit   = PositionGetDouble(POSITION_PROFIT);
            double basketProfit = primaryMoneyProfit + recProfit;

            // Guard: never close recovery at a net basket loss — this prevents the bleed
            // cycle (recovery closes at -52 pips, immediately re-opens, repeat forever).
            if(basketProfit < 0.0)
            {
               if(DebugMode)
                  PrintFormat("[%s] MinProfitPips met (%.1f pips) but basket still negative (%.2f) — keeping recovery open",
                              EA_Name, pipProfit / PipPoint(), basketProfit);
               continue;
            }

            if(trade.PositionClose(recTkt))
            {
               PrintFormat("[%s] Auto-closed recovery %I64u — primary %I64u returned to profit (%.1f pips, basket=%.2f)",
                           EA_Name, recTkt, primaryTkt, pipProfit / PipPoint(), basketProfit);
               UntrackPosition(recTkt);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   TrailingAndBreakeven();
   ManageHedgeRecovery();

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > PeakEquity) PeakEquity = eq;

   // Refresh indicator buffers every tick so the hedge trigger and new-candle logic
   // both have current ATR / MA values available.
   if(CopyBuffer(FastMAHandle,0,0,3,FastMA) < 3) return;
   if(CopyBuffer(SlowMAHandle,0,0,3,SlowMA) < 3) return;
   if(ATRHandle != INVALID_HANDLE && CopyBuffer(ATRHandle,0,0,2,ATRBuf) < 2) return;

   // --- Hedge/recovery trigger: runs EVERY TICK ---
   // Must be checked per-tick, not per-candle: the primary trade can hit its SL
   // (and disappear) mid-candle before the next candle open ever arrives.
   // NOTE: if MODE_SCALPING is selected, ensure HedgeTriggerPips < primary ATR*SL_Mult
   //       (e.g. ATR=15 pips, SL_Mult=1.0 → set HedgeTriggerPips ≤ 10).
   if(CountOpenPositions() == 1 && !HaveOpenHedge())
   {
      ulong primaryTicket = GetPrimaryTicket();
      if(primaryTicket != 0 && (MaxHedgesPerPrimaryTrade == 0 || GetPrimaryHedgeCount(primaryTicket) < MaxHedgesPerPrimaryTrade))
      {
         if(PositionSelectByTicket(primaryTicket) && PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double firstLots = PositionGetDouble(POSITION_VOLUME);

            double pip   = PipPoint();
            double price = (ptype == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                        : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

            double adversePips = (ptype == POSITION_TYPE_BUY) ? (openPrice - price) / pip
                                                              : (price - openPrice) / pip;

            if(adversePips > 0.0)
            {
               double hedgeTrigger = HedgeTriggerPips;
               if(!UseHedgeTriggerPips)
                  hedgeTrigger = (ATRBuf[0] * HedgeTriggerATRMult) / pip;

               // Per-candle diagnostic: print hedge status once per new bar so the user can
               // see exactly why the hedge hasn't fired yet (no spam on every tick).
               if(DebugMode)
               {
                  datetime barTime = iTime(_Symbol, _Period, 0);
                  if(barTime != g_lastHedgeStatusBar)
                  {
                     g_lastHedgeStatusBar = barTime;
                     double atrPipsD   = ATRBuf[0] / pip;
                     double maGapPipsD = MathAbs(FastMA[1] - SlowMA[1]) / pip;
                     string reason = "";
                     if(adversePips < hedgeTrigger)
                        reason = StringFormat("need %.1f more pips adverse", hedgeTrigger - adversePips);
                     else if(atrPipsD < MinATRForHedgePips)
                        reason = StringFormat("ATR too low (%.1f < %.1f)", atrPipsD, MinATRForHedgePips);
                     else if(maGapPipsD < MinMAGapPips)
                        reason = StringFormat("MA gap too low (%.1f < %.1f)", maGapPipsD, MinMAGapPips);
                     else
                        reason = "WILL FIRE THIS TICK";
                     PrintFormat("[%s] HedgeStatus: adverse=%.1f pips | trigger=%.1f | SL~%.1f pips | %s",
                                 EA_Name, adversePips, hedgeTrigger, ATR_SL_Mult * atrPipsD, reason);
                  }
               }

               if(adversePips >= hedgeTrigger)
               {
                  double atrPips   = ATRBuf[0] / pip;
                  double maGapPips = MathAbs(FastMA[1] - SlowMA[1]) / pip;

                  if(atrPips < MinATRForHedgePips)
                  {
                     if(DebugMode) PrintFormat("[%s] Hedge blocked: ATR too low (%.1f pips)", EA_Name, atrPips);
                  }
                  else if(maGapPips < MinMAGapPips)
                  {
                     if(DebugMode) PrintFormat("[%s] Hedge blocked: MA gap too low (%.1f pips)", EA_Name, maGapPips);
                  }
                  else
                  {
                     double hedgeLots = firstLots * HedgeLotMultiplier;
                     if(adversePips >= hedgeTrigger * 1.5)
                        hedgeLots = firstLots * MathMin(HedgeLotMultiplier + 0.3, 2.0);

                     if(hedgeLots > MaxLotSize) hedgeLots = MaxLotSize;

                     double vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
                     int vol_digits = (vol_step > 0.0 && vol_step < 1.0) ? (int)MathRound(-MathLog10(vol_step)) : 2;
                     if(vol_step > 0.0) hedgeLots = MathFloor(hedgeLots / vol_step) * vol_step;
                     hedgeLots = NormalizeDouble(hedgeLots, vol_digits);

                     ENUM_ORDER_TYPE htype = (ptype == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

                     if(OpenTrade(htype, hedgeLots, true, primaryTicket))
                     {
                        IncrementPrimaryHedgeCount(primaryTicket);
                        PrintFormat("[%s] Hedge recovery opened: %.2f lots, adverse=%.1f pips, trigger=%.1f pips",
                                    EA_Name, hedgeLots, adversePips, hedgeTrigger);
                     }
                  }
               }
            }
         }
      }
   }
   // --- End per-tick hedge trigger ---

   if(!IsNewCandle()) return;

   if(cooldownBarsRemaining > 0) { cooldownBarsRemaining--; return; }

   if(buyCount >= MaxTradesPerDirection || sellCount >= MaxTradesPerDirection)
   {
      PrintFormat("[%s] Max trades per direction reached -> cooldown", EA_Name);
      buyCount = 0; sellCount = 0;
      cooldownBarsRemaining = CooldownCandles;
      return;
   }

   for(int idx=ArraySize(trackedTickets)-1; idx>=0; idx--)
   {
      ulong t = trackedTickets[idx];
      bool exists = false;
      for(int p=PositionsTotal()-1; p>=0; p--)
      {
         ulong pt = PositionGetTicket(p);
         if(pt == t) { exists = true; break; }
      }
      if(!exists) UntrackPosition(t);
   }

   double dd = 0.0;
   if(PeakEquity > 0.0)
      dd = (PeakEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / PeakEquity * 100.0;

   if(dd >= MaxDrawdownPercent)
   {
      PrintFormat("[%s] Drawdown pause %.2f%%", EA_Name, dd);
      return;
   }

   if(UseSessionFilter && !IsTradingSession()) return;

   ENUM_TRADE_SIGNAL sig = GetSignal();

   if(CountOpenPositions() == 0)
   {
      if(sig == SIGNAL_NEUTRAL) return;

      // MA separation filter: skip entry if fast/slow MAs are too close (consolidation)
      if(MinMASepEntryPips > 0.0)
      {
         double pip = (SymbolInfoInteger(_Symbol, SYMBOL_DIGITS) % 2 == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0 : SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         double maSepPips = MathAbs(FastMA[1] - SlowMA[1]) / pip;
         if(maSepPips < MinMASepEntryPips)
         {
            if(DebugMode) PrintFormat("[%s] Entry blocked: MA separation too small (%.1f pips < %.1f required)", EA_Name, maSepPips, MinMASepEntryPips);
            return;
         }
      }

      double sl_pips = SL_Pips_From_ATR();
      double lots = ComputeRiskLots(sl_pips);
      if(lots <= 0) return;

      if(sig == SIGNAL_BUY)  { if(OpenTrade(ORDER_TYPE_BUY,  lots, false, 0)) SendSignal("BUY");  }
      if(sig == SIGNAL_SELL) { if(OpenTrade(ORDER_TYPE_SELL, lots, false, 0)) SendSignal("SELL"); }
      return;
   }
}

//+------------------------------------------------------------------+
void TrailingAndBreakeven()
{
   double trailStartPips = TrailingStart_From_ATR();
   double trailStepPips  = TrailingStep_From_ATR();

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      bool isHedge = IsHedgePosition(ticket);
      int idxTracked = FindTrackedIndex(ticket);
      bool useAggTrail = false;

      if(isHedge && idxTracked >= 0)
         useAggTrail = trackedPostSLTrail[idxTracked];

      if(isHedge && !useAggTrail)
      {
         // Apply hedge-specific BE and trailing if configured
         bool hedgeNeedsWork = (HedgeBreakEvenTriggerPips > 0.0 || HedgeTrailStartPips > 0.0);
         if(!hedgeNeedsWork) continue;

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL = PositionGetDouble(POSITION_SL);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double pip = PipPoint();
         double price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                    : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitPips = (type == POSITION_TYPE_BUY) ? (price - openPrice) / pip
                                                         : (openPrice - price) / pip;

         if(HedgeBreakEvenTriggerPips > 0.0 && profitPips >= HedgeBreakEvenTriggerPips)
         {
            double newSL = (type == POSITION_TYPE_BUY) ? openPrice + HedgeBreakEvenPlusPips * pip
                                                       : openPrice - HedgeBreakEvenPlusPips * pip;
            if(currentSL == 0.0 || (type == POSITION_TYPE_BUY && newSL > currentSL)
                                 || (type == POSITION_TYPE_SELL && newSL < currentSL))
               ModifyPositionSL(ticket, newSL);
         }

         if(HedgeTrailStartPips > 0.0 && profitPips >= HedgeTrailStartPips)
         {
            double trailDistance = HedgeTrailDistancePips * pip;
            double step          = HedgeTrailStepPips * pip;
            double newSL         = 0.0;
            bool   doModify      = false;
            currentSL = PositionGetDouble(POSITION_SL); // re-read in case BE just modified it

            if(type == POSITION_TYPE_BUY)
            {
               newSL = price - trailDistance;
               if(currentSL == 0.0 || newSL > currentSL + step) doModify = true;
            }
            else
            {
               newSL = price + trailDistance;
               if(currentSL == 0.0 || newSL < currentSL - step) doModify = true;
            }

            if(doModify) ModifyPositionSL(ticket, newSL);
         }

         continue;
      }

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double volume = PositionGetDouble(POSITION_VOLUME);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double pip = PipPoint();
      double price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                 : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPips = (type == POSITION_TYPE_BUY) ? (price - openPrice) / pip
                                                      : (openPrice - price) / pip;

      if(useAggTrail)
      {
         if(profitPips >= AggTrailStartPips)
         {
            double newSL = 0.0;
            bool doModify = false;
            double trailDistance = AggTrailDistancePips * pip;
            double step = AggTrailStepPips * pip;

            if(type == POSITION_TYPE_BUY)
            {
               newSL = price - trailDistance;
               if(currentSL == 0.0 || newSL > currentSL + step)
                  doModify = true;
            }
            else
            {
               newSL = price + trailDistance;
               if(currentSL == 0.0 || newSL < currentSL - step)
                  doModify = true;
            }

            if(doModify)
               ModifyPositionSL(ticket, newSL);
         }

         continue;
      }

      if(UsePartialClose && profitPips >= PartialClosePips && volume > 0.0 && !g_PartialClosed)
      {
         double vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double vol_min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         int vol_digits = (vol_step > 0.0 && vol_step < 1.0) ? (int)MathRound(-MathLog10(vol_step)) : 0;
         double closeVol = volume * (PartialClosePercent / 100.0);
         if(vol_step > 0.0) closeVol = MathFloor(closeVol / vol_step) * vol_step;
         closeVol = NormalizeDouble(closeVol, vol_digits);
         if(closeVol >= vol_min && closeVol < volume)
         {
            if(trade.PositionClosePartial(ticket, closeVol))
               g_PartialClosed = true;
         }
      }

      if(UseBreakEven && profitPips >= BreakEvenTriggerPips)
      {
         double newSL = (type == POSITION_TYPE_BUY) ? openPrice + BreakEvenPlusPips * pip
                                                    : openPrice - BreakEvenPlusPips * pip;

         if(currentSL == 0.0 || (type == POSITION_TYPE_BUY && newSL > currentSL) || (type == POSITION_TYPE_SELL && newSL < currentSL))
            ModifyPositionSL(ticket, newSL);
      }

      if(UseTrailingStop && profitPips >= trailStartPips)
      {
         double buffer = (TrailBufferPips > 0.0) ? TrailBufferPips * pip : 0.0;
         double step = trailStepPips * pip;
         double trailDistance = trailStartPips * pip + buffer;
         double newSL = 0.0;
         bool doModify = false;

         if(type == POSITION_TYPE_BUY)
         {
            newSL = price - trailDistance;
            if(currentSL == 0.0 || newSL > currentSL + step) doModify = true;
         }
         else
         {
            newSL = price + trailDistance;
            if(currentSL == 0.0 || newSL < currentSL - step) doModify = true;
         }

         if(doModify) ModifyPositionSL(ticket, newSL);
      }
   }
}

//+------------------------------------------------------------------+
bool OpenTrade(const ENUM_ORDER_TYPE type, double lotsParam, bool isHedge=false, ulong parentTicket=0)
{
   double pip = PipPoint();
   double sl_pips = SL_Pips_From_ATR();
   double tp_pips = TP_Pips_From_ATR();
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double sl = (type == ORDER_TYPE_BUY) ? price - sl_pips * pip : price + sl_pips * pip;
   double tp = (type == ORDER_TYPE_BUY) ? price + tp_pips * pip : price - tp_pips * pip;

   if(isHedge)
   {
      sl = 0.0;
      if(HedgeTPPips > 0.0)
         tp = (type == ORDER_TYPE_BUY) ? price + HedgeTPPips * pip : price - HedgeTPPips * pip;
      else
         tp = 0.0;
   }

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   AdjustStopsForBroker(sl, tp, type);

   double dd = 0.0;
   if(PeakEquity > 0.0)
      dd = (PeakEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / PeakEquity * 100.0;

   if(dd >= MaxDrawdownPercent) return false;

   double lots = (lotsParam > 0.0) ? lotsParam : ComputeRiskLots(sl_pips);
   double vol_max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lots > vol_max) lots = vol_max;

   bool ok = (type == ORDER_TYPE_BUY) ?
               trade.Buy(lots, _Symbol, 0.0, sl, tp, EA_Name + (isHedge ? " HEDGE" : " BUY")) :
               trade.Sell(lots, _Symbol, 0.0, sl, tp, EA_Name + (isHedge ? " HEDGE" : " SELL"));

   if(!ok)
   {
      PrintFormat("[%s] Open failed, retcode=%d", EA_Name, trade.ResultRetcode());
      return false;
   }

   if(type == ORDER_TYPE_BUY) buyCount++; else sellCount++;
   g_PartialClosed = false;

   Sleep(100);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(!IsTicketTracked(t))
      {
         TrackPositionOpen(t, isHedge, parentTicket);
         break;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
void AdjustStopsForBroker(double &sl_price, double &tp_price, ENUM_ORDER_TYPE order_type)
{
   double stop_level_points = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stop_level_points <= 0) return;

   double min_distance = stop_level_points * _Point + 5 * _Point;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(order_type == ORDER_TYPE_BUY)
   {
      if(sl_price > 0 && sl_price > ask - min_distance) sl_price = ask - min_distance;
      if(tp_price > 0 && tp_price < ask + min_distance) tp_price = ask + min_distance;
   }
   else if(order_type == ORDER_TYPE_SELL)
   {
      if(sl_price > 0 && sl_price < bid + min_distance) sl_price = bid + min_distance;
      if(tp_price > 0 && tp_price > bid - min_distance) tp_price = bid - min_distance;
   }

   sl_price = NormalizeDouble(sl_price, _Digits);
   tp_price = NormalizeDouble(tp_price, _Digits);
}

//+------------------------------------------------------------------+
void TrackPositionOpen(ulong ticket, bool isSecond, ulong parentTicket=0)
{
   if(ticket == 0) return;
   if(!PositionSelectByTicket(ticket)) return;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return;
   if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) return;

   datetime t_open = iTime(_Symbol, _Period, 1);
   double vol = PositionGetDouble(POSITION_VOLUME);
   int type = (int)PositionGetInteger(POSITION_TYPE);
   int sz = ArraySize(trackedTickets);

   ArrayResize(trackedTickets, sz + 1);
   ArrayResize(trackedOpenCandle, sz + 1);
   ArrayResize(trackedVolume, sz + 1);
   ArrayResize(trackedType, sz + 1);
   ArrayResize(trackedIsSecond, sz + 1);
   ArrayResize(trackedHedgeCount, sz + 1);
   ArrayResize(trackedParentTicket, sz + 1);
   ArrayResize(trackedPostSLTrail, sz + 1);

   trackedTickets[sz] = ticket;
   trackedOpenCandle[sz] = t_open;
   trackedVolume[sz] = vol;
   trackedType[sz] = type;
   trackedIsSecond[sz] = isSecond;
   trackedParentTicket[sz] = parentTicket;
   trackedHedgeCount[sz] = 0;
   trackedPostSLTrail[sz] = false;

   if(DebugMode)
      PrintFormat("[%s] Tracked t=%I64u vol=%.2f type=%d hedge=%s parent=%I64u",
                  EA_Name, ticket, vol, type, isSecond?"Y":"N", parentTicket);
}

void UntrackPosition(ulong ticket)
{
   int sz = ArraySize(trackedTickets);
   for(int i=0; i<sz; i++)
   {
      if(trackedTickets[i] != ticket) continue;

      for(int j=i; j<sz-1; j++)
      {
         trackedTickets[j]      = trackedTickets[j+1];
         trackedOpenCandle[j]   = trackedOpenCandle[j+1];
         trackedVolume[j]       = trackedVolume[j+1];
         trackedType[j]         = trackedType[j+1];
         trackedIsSecond[j]     = trackedIsSecond[j+1];
         trackedHedgeCount[j]   = trackedHedgeCount[j+1];
         trackedParentTicket[j] = trackedParentTicket[j+1];
         trackedPostSLTrail[j]  = trackedPostSLTrail[j+1];
      }

      ArrayResize(trackedTickets,      sz-1);
      ArrayResize(trackedOpenCandle,   sz-1);
      ArrayResize(trackedVolume,       sz-1);
      ArrayResize(trackedType,         sz-1);
      ArrayResize(trackedIsSecond,     sz-1);
      ArrayResize(trackedHedgeCount,   sz-1);
      ArrayResize(trackedParentTicket, sz-1);
      ArrayResize(trackedPostSLTrail,  sz-1);

      if(DebugMode) PrintFormat("[%s] Untracked ticket=%I64u", EA_Name, ticket);
      return;
   }
}

double PipPoint()
{
   return (_Digits==3 || _Digits==5) ? _Point*10.0 : _Point;
}

double SL_Pips_From_ATR()
{
   if(ATRHandle==INVALID_HANDLE) return 0.0;
   if(CopyBuffer(ATRHandle,0,0,1,ATRBuf) < 1) return 0.0;
   return (ATRBuf[0]*ATR_SL_Mult)/PipPoint();
}

double TP_Pips_From_ATR()
{
   if(ATRHandle==INVALID_HANDLE) return 0.0;
   if(CopyBuffer(ATRHandle,0,0,1,ATRBuf) < 1) return 0.0;
   return (ATRBuf[0]*ATR_TP_Mult)/PipPoint();
}

double TrailingStart_From_ATR()
{
   if(ATRHandle==INVALID_HANDLE) return 0.0;
   if(CopyBuffer(ATRHandle,0,0,1,ATRBuf) < 1) return 0.0;
   return (ATRBuf[0]*ATR_TrailStart_Mult)/PipPoint();
}

double TrailingStep_From_ATR()
{
   if(ATRHandle==INVALID_HANDLE) return 0.0;
   if(CopyBuffer(ATRHandle,0,0,1,ATRBuf) < 1) return 0.0;
   return (ATRBuf[0]*ATR_TrailStep_Mult)/PipPoint();
}

bool ModifyPositionSL(ulong ticket,double newSL)
{
   if(!PositionSelectByTicket(ticket)) return false;
   double tp = PositionGetDouble(POSITION_TP);
   newSL = NormalizeDouble(newSL,_Digits);
   return trade.PositionModify(ticket, newSL, tp);
}

int CountOpenPositions()
{
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      c++;
   }
   return c;
}

bool IsTradingSession()
{
   if(!UseSessionFilter) return true;
   MqlDateTime tm; TimeToStruct(TimeCurrent(),tm);
   if(LondonOpenHour==NYCloseHour) return true;
   if(LondonOpenHour < NYCloseHour)
      return (tm.hour >= LondonOpenHour && tm.hour < NYCloseHour);
   return (tm.hour >= LondonOpenHour || tm.hour < NYCloseHour);
}

double ComputeRiskLots(double sl_pips)
{
   double vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vol_min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vol_max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(RiskPercent <= 0.0)
   {
      double desired = LotSize;
      if(vol_step > 0.0) desired = MathFloor(desired / vol_step) * vol_step;
      desired = NormalizeDouble(desired, (vol_step < 1.0) ? (int)MathRound(-MathLog10(vol_step)) : 2);
      return MathMax(vol_min, MathMin(vol_max, desired));
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amount = equity * (RiskPercent / 100.0);
   double pip_value_per_lot = 0.0;
   if(tick_value > 0.0 && tick_size > 0.0)
      pip_value_per_lot = (tick_value / tick_size) * PipPoint();
   if(pip_value_per_lot <= 0.0) pip_value_per_lot = 1.0;

   double sl_value_per_lot = sl_pips * pip_value_per_lot;
   if(sl_value_per_lot <= 0.0) sl_value_per_lot = 1.0;

   double raw_lots = risk_amount / sl_value_per_lot;
   if(raw_lots > MaxLotSize) raw_lots = MaxLotSize;
   if(raw_lots < vol_min) raw_lots = vol_min;

   if(vol_step > 0.0)
   {
      raw_lots = MathFloor(raw_lots / vol_step) * vol_step;
      int vol_digits = (vol_step < 1.0) ? (int)MathRound(-MathLog10(vol_step)) : 0;
      raw_lots = NormalizeDouble(raw_lots, vol_digits);
   }
   else
   {
      raw_lots = NormalizeDouble(raw_lots, 2);
   }

   return MathMax(vol_min, MathMin(vol_max, raw_lots));
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(FastMAHandle != INVALID_HANDLE) IndicatorRelease(FastMAHandle);
   if(SlowMAHandle != INVALID_HANDLE) IndicatorRelease(SlowMAHandle);
   if(ATRHandle    != INVALID_HANDLE) IndicatorRelease(ATRHandle);
}
//+------------------------------------------------------------------+