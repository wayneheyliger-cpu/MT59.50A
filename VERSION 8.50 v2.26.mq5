//+------------------------------------------------------------------+
//| MA Crossover EA - Multiple Pairs + Hedge + Auto-Close (v2.26)   |
//+------------------------------------------------------------------+
#property copyright "xAI Grok"
#property version   "2.26"
#property strict

#include <Trade/Trade.mqh>

//=== CONFIG =========================================================
input string  EA_Name               = "MA_Crossover_EA_Hedge_Double_v2_26";
input double  LotSize               = 0.10;
input double  StopLossPips          = 200;
input double  TakeProfitPips        = 400;

input int     MAFastPeriod          = 1;
input ENUM_MA_METHOD MAFastMethod   = MODE_SMA;
input ENUM_APPLIED_PRICE MAFastPrice= PRICE_CLOSE;

input int     MASlowPeriod          = 100;
input ENUM_MA_METHOD MASlowMethod   = MODE_SMA;
input ENUM_APPLIED_PRICE MASlowPrice= PRICE_CLOSE;

input int     MagicNumber           = 17635;
input bool    EnableAlerts          = true;
input bool    EnableNotifications   = false;
input bool    EnableEmail           = false;

// Trailing / Break-even / Partial close inputs
input bool    UseTrailingStop       = true;
input double  TrailingStartPips     = 100;
input double  TrailingStepPips      = 20;
input bool    UseBreakEven          = true;
input double  BreakEvenTriggerPips  = 150;
input double  BreakEvenPlusPips     = 10;

input bool    UsePartialClose       = false;
input double  PartialClosePips      = 20.0;
input double  PartialClosePercent   = 50.0;
input double  TrailBufferPips       = 0.0;

input double  HedgeLotMultiplier    = 2.0;  // Recovery opens at LotSize * HedgeLotMultiplier
input int     MaxPairs              = 2;    // Max simultaneous primary trades
input double  MinProfitPipsToCloseRecovery = 2.0; // Primary must be at least this many pips positive before recovery is auto-closed (prevents spread-noise churn)
input bool    CloseOnFullRecovery    = false; // When true: if primary + recovery combined P&L >= 0, close BOTH immediately (lock in recovery, avoid pullback)

//=== SESSION CONTROL ===============================================
input bool    UseSessionFilter      = true;
input int     LondonOpenHour        = 8;
input int     NYCloseHour           = 22;
input bool    CloseNegativeAtEndOfDay = true;

// Debug toggle
input bool    DebugMode             = true;

//=== ENUMS & GLOBALS ===============================================
enum ENUM_TRADE_SIGNAL { SIGNAL_BUY=1, SIGNAL_SELL=-1, SIGNAL_NEUTRAL=0 };

CTrade trade;

int FastMAHandle = INVALID_HANDLE;
int SlowMAHandle = INVALID_HANDLE;
double FastMA[];
double SlowMA[];
datetime lastCandleTime = 0;
bool g_PartialClosed = false;
int g_LastClosedDay = -1;

// Tracking arrays
ulong    trackedTickets[];
datetime trackedOpenCandle[]; // recorded completed candle time at open (index 1)
double   trackedVolume[];
int      trackedType[];       // POSITION_TYPE_BUY or SELL
bool     trackedIsSecond[];   // true if this is a hedge/recovery trade
ulong    trackedParentTicket[]; // for recovery trades: ticket of the primary they belong to; 0 for primaries

//+------------------------------------------------------------------+
double PipPoint()
{
   if(_Digits==3||_Digits==5) return _Point*10.0;
   return _Point;
}

//+------------------------------------------------------------------+
bool IsTradingSession()
{
   if(!UseSessionFilter) return true;
   MqlDateTime tm; TimeToStruct(TimeCurrent(), tm);
   return (tm.hour >= LondonOpenHour && tm.hour < NYCloseHour);
}

//+------------------------------------------------------------------+
void CloseNegativeTrades()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol || (int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

      // BUG 1 FIX: Never EOD-close a recovery trade (it will be cleaned up
      // by the primary's own closure or when the primary recovers).
      bool isRecovery = false;
      for(int k=0;k<ArraySize(trackedTickets);k++)
         if(trackedTickets[k]==ticket && trackedIsSecond[k]) { isRecovery=true; break; }
      if(isRecovery) continue;

      // BUG 1 FIX: Never EOD-close a primary that currently has an active
      // recovery running against it. Let the recovery mechanism do its job.
      bool hasActiveRecovery = false;
      for(int k=0;k<ArraySize(trackedTickets);k++)
         if(trackedIsSecond[k] && trackedParentTicket[k]==ticket && PositionSelectByTicket(trackedTickets[k]))
            { hasActiveRecovery=true; break; }
      if(hasActiveRecovery) continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit < 0.0)
      {
         if(trade.PositionClose(ticket))
            PrintFormat("[%s] Closed negative trade at EOD (ticket=%I64u profit=%.2f)", EA_Name, ticket, profit);
         else
            PrintFormat("[%s] Failed to close negative trade (ticket=%I64u)", EA_Name, ticket);
      }
   }
}

//+------------------------------------------------------------------+
bool HasBuyOpen()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && (int)PositionGetInteger(POSITION_MAGIC)==MagicNumber &&
         (int)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) return true;
   }
   return false;
}

bool HasSellOpen()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && (int)PositionGetInteger(POSITION_MAGIC)==MagicNumber &&
         (int)PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL) return true;
   }
   return false;
}

int CountOpenPositions()
{
   int cnt=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol && (int)PositionGetInteger(POSITION_MAGIC)==MagicNumber) cnt++;
   }
   return cnt;
}

//+------------------------------------------------------------------+
// Count active PRIMARY positions (isSecond=false). Each primary = 1 pair.
int CountActivePairs()
{
   int cnt = 0;
   for(int i = 0; i < ArraySize(trackedTickets); i++)
   {
      if(trackedIsSecond[i]) continue;
      if(PositionSelectByTicket(trackedTickets[i])) cnt++;
   }
   return cnt;
}

// Returns true if at least one recovery trade is currently open
bool AnyRecoveryActive()
{
   for(int i = 0; i < ArraySize(trackedTickets); i++)
   {
      if(!trackedIsSecond[i]) continue;
      if(PositionSelectByTicket(trackedTickets[i])) return true;
   }
   return false;
}

// Returns the direction (POSITION_TYPE_BUY / POSITION_TYPE_SELL) of the first
// active primary, or -1 if none exists.
int FirstActivePrimaryType()
{
   for(int i = 0; i < ArraySize(trackedTickets); i++)
   {
      if(trackedIsSecond[i]) continue;
      if(PositionSelectByTicket(trackedTickets[i])) return trackedType[i];
   }
   return -1;
}

//+------------------------------------------------------------------+
// Tracking helpers
//+------------------------------------------------------------------+
void TrackPositionOpen(ulong ticket, bool isSecond, ulong parentTicket = 0)
{
   if(ticket==0) return;
   if(!PositionSelectByTicket(ticket)) return;
   if(PositionGetString(POSITION_SYMBOL)!=_Symbol) return;
   if((int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) return;

   datetime t_open = iTime(_Symbol,_Period,1); // last completed candle at open
   double vol = PositionGetDouble(POSITION_VOLUME);
   int type = (int)PositionGetInteger(POSITION_TYPE);

   int sz = ArraySize(trackedTickets);
   ArrayResize(trackedTickets, sz+1);
   ArrayResize(trackedOpenCandle, sz+1);
   ArrayResize(trackedVolume, sz+1);
   ArrayResize(trackedType, sz+1);
   ArrayResize(trackedIsSecond, sz+1);
   ArrayResize(trackedParentTicket, sz+1);

   trackedTickets[sz] = ticket;
   trackedOpenCandle[sz] = t_open;
   trackedVolume[sz] = vol;
   trackedType[sz] = type;
   trackedIsSecond[sz] = isSecond;
   trackedParentTicket[sz] = parentTicket;

   if(DebugMode) PrintFormat("[%s] Track open t=%I64u vol=%.2f type=%d second=%s parent=%I64u openCandle=%s",
      EA_Name, ticket, vol, type, isSecond ? "Y":"N", parentTicket, TimeToString(t_open, TIME_DATE|TIME_MINUTES));
}

void UntrackPosition(ulong ticket)
{
   int sz = ArraySize(trackedTickets);
   for(int i=0;i<sz;i++)
   {
      if(trackedTickets[i]==ticket)
      {
         for(int j=i;j<sz-1;j++)
         {
            trackedTickets[j]=trackedTickets[j+1];
            trackedOpenCandle[j]=trackedOpenCandle[j+1];
            trackedVolume[j]=trackedVolume[j+1];
            trackedType[j]=trackedType[j+1];
            trackedIsSecond[j]=trackedIsSecond[j+1];
            trackedParentTicket[j]=trackedParentTicket[j+1];
         }
         ArrayResize(trackedTickets, sz-1);
         ArrayResize(trackedOpenCandle, sz-1);
         ArrayResize(trackedVolume, sz-1);
         ArrayResize(trackedType, sz-1);
         ArrayResize(trackedIsSecond, sz-1);
         ArrayResize(trackedParentTicket, sz-1);
         if(DebugMode) PrintFormat("[%s] Untracked t=%I64u", EA_Name, ticket);
         return;
      }
   }
}

bool IsTicketTracked(ulong ticket)
{
   for(int i=0;i<ArraySize(trackedTickets);i++) if(trackedTickets[i]==ticket) return true;
   return false;
}

//+------------------------------------------------------------------+
int OnInit()
{
   Print(EA_Name,": Init v2.26");
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);

   FastMAHandle = iMA(_Symbol,_Period,MAFastPeriod,0,MAFastMethod,MAFastPrice);
   SlowMAHandle = iMA(_Symbol,_Period,MASlowPeriod,0,MASlowMethod,MASlowPrice);
   if(FastMAHandle==INVALID_HANDLE || SlowMAHandle==INVALID_HANDLE) { Print("MA handle error"); return(INIT_FAILED); }

   ArraySetAsSeries(FastMA,true); ArraySetAsSeries(SlowMA,true);
   ArrayResize(trackedTickets,0);
   ArrayResize(trackedOpenCandle,0);
   ArrayResize(trackedVolume,0);
   ArrayResize(trackedType,0);
   ArrayResize(trackedIsSecond,0);
   ArrayResize(trackedParentTicket,0);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(FastMAHandle!=INVALID_HANDLE) IndicatorRelease(FastMAHandle);
   if(SlowMAHandle!=INVALID_HANDLE) IndicatorRelease(SlowMAHandle);
}

//+------------------------------------------------------------------+
bool IsNewCandle()
{
   datetime t = iTime(_Symbol,_Period,0);
   if(t==lastCandleTime) return false;
   lastCandleTime = t;
   return true;
}

//+------------------------------------------------------------------+
ENUM_TRADE_SIGNAL GetSignal()
{
   if(CopyBuffer(FastMAHandle,0,0,3,FastMA) < 3) return SIGNAL_NEUTRAL;
   if(CopyBuffer(SlowMAHandle,0,0,3,SlowMA) < 3) return SIGNAL_NEUTRAL;
   if(FastMA[2] <= SlowMA[2] && FastMA[1] > SlowMA[1]) return SIGNAL_BUY;
   if(FastMA[2] >= SlowMA[2] && FastMA[1] < SlowMA[1]) return SIGNAL_SELL;
   return SIGNAL_NEUTRAL;
}

//+------------------------------------------------------------------+
void SendSignal(const string sig)
{
   string msg = EA_Name + " " + _Symbol + " -> " + sig + " signal";
   if(EnableAlerts) Alert(msg);
   if(EnableNotifications) SendNotification(msg);
   if(EnableEmail) SendMail(EA_Name + " Signal", msg);
   Print(msg);
}

//+------------------------------------------------------------------+
// parentTicket = 0 for primaries; = primary's ticket for recovery trades
bool OpenTrade(const ENUM_ORDER_TYPE type, double lots, bool isSecond = false, ulong parentTicket = 0)
{
   double price = (type==ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double pip = PipPoint();
   double sl = (type==ORDER_TYPE_BUY) ? price - StopLossPips*pip : price + StopLossPips*pip;
   double tp = (type==ORDER_TYPE_BUY) ? price + TakeProfitPips*pip : price - TakeProfitPips*pip;
   sl = NormalizeDouble(sl,_Digits); tp = NormalizeDouble(tp,_Digits);

   bool ok = (type==ORDER_TYPE_BUY) ? trade.Buy(lots,_Symbol,0.0,sl,tp,EA_Name+" BUY") : trade.Sell(lots,_Symbol,0.0,sl,tp,EA_Name+" SELL");
   if(!ok) { PrintFormat("[%s] Open failed ret=%d", EA_Name, trade.ResultRetcode()); return false; }

   Sleep(50);
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t = PositionGetTicket(i);
      if(t==0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      double vol = PositionGetDouble(POSITION_VOLUME);
      if(!IsTicketTracked(t) && MathAbs(vol - lots) < 0.0001)
      {
         TrackPositionOpen(t, isSecond, parentTicket);
         break;
      }
   }

   PrintFormat("[%s] %s opened (%.2f) SL/TP set isSecond=%s parent=%I64u", EA_Name, EnumToString(type), lots, isSecond ? "Y":"N", parentTicket);
   return true;
}

//+------------------------------------------------------------------+
bool ModifyPositionSL(ulong ticket, double newSL)
{
   if(!PositionSelectByTicket(ticket)) return false;
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double stopLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(posType == POSITION_TYPE_BUY  && newSL >= bid - stopLevel) return false;
   if(posType == POSITION_TYPE_SELL && newSL <= ask + stopLevel) return false;
   double tp = PositionGetDouble(POSITION_TP);
   MqlTradeRequest req={}; MqlTradeResult res={};
   req.action = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol = _Symbol;
   req.sl = NormalizeDouble(newSL,_Digits);
   req.tp = tp;
   req.magic = MagicNumber;
   if(!OrderSend(req,res)) { PrintFormat("[%s] SL modify failed ret=%d", EA_Name, res.retcode); return false; }
   return true;
}

bool PartialClosePosition(ulong ticket,double closeVol)
{
   if(!PositionSelectByTicket(ticket)) return false;
   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   MqlTradeRequest req={}; MqlTradeResult res={};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = _Symbol;
   req.volume = closeVol;
   req.type = (ptype==POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price = (req.type==ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID);
   req.position = ticket;
   req.deviation = 20;
   req.magic = MagicNumber;
   if(!OrderSend(req,res) || res.retcode != TRADE_RETCODE_DONE) { PrintFormat("[%s] Partial close failed ret=%d", EA_Name, res.retcode); return false; }
   return true;
}

//+------------------------------------------------------------------+
void TrailingAndBreakeven()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double volume = PositionGetDouble(POSITION_VOLUME);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      double pip = PipPoint();
      double price = (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol,SYMBOL_BID) : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double profitPips = (type==POSITION_TYPE_BUY) ? (price - openPrice)/pip : (openPrice - price)/pip;

      if(UsePartialClose && profitPips >= PartialClosePips && volume>0.0 && !g_PartialClosed)
      {
         double vol_step = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
         double vol_min  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
         int vol_digits = (vol_step>0.0 && vol_step<1.0) ? (int)MathRound(-MathLog10(vol_step)) : 0;
         double closeVol = volume * (PartialClosePercent/100.0);
         if(vol_step>0.0) closeVol = MathFloor(closeVol/vol_step)*vol_step;
         closeVol = NormalizeDouble(closeVol, vol_digits);
         if(closeVol >= vol_min && closeVol < volume) { if(PartialClosePosition(ticket, closeVol)) { g_PartialClosed = true; } }
      }

      if(UseBreakEven && profitPips >= BreakEvenTriggerPips)
      {
         double newSL = (type==POSITION_TYPE_BUY) ? openPrice + BreakEvenPlusPips*pip : openPrice - BreakEvenPlusPips*pip;
         if(currentSL==0.0 || (type==POSITION_TYPE_BUY && newSL>currentSL) || (type==POSITION_TYPE_SELL && newSL<currentSL))
            ModifyPositionSL(ticket, newSL);
      }

      if(UseTrailingStop && profitPips >= TrailingStartPips)
      {
         double buffer = (TrailBufferPips>0.0) ? TrailBufferPips*pip : 0.0;
         double step = TrailingStepPips*pip;
         double trailDistance = TrailingStartPips*pip + buffer;
         double newSL = 0.0; bool doModify=false;
         if(type==POSITION_TYPE_BUY) { newSL = price - trailDistance; if(currentSL==0.0 || newSL > currentSL + step) doModify=true; }
         else { newSL = price + trailDistance; if(currentSL==0.0 || newSL < currentSL - step) doModify=true; }
         if(doModify) ModifyPositionSL(ticket, newSL);
      }
   }
}

//+------------------------------------------------------------------+
// ManageTrades - opens a new standalone primary on any fresh valid
// signal, in any direction, as long as activePairs < MaxPairs.
//+------------------------------------------------------------------+
void ManageTrades(const ENUM_TRADE_SIGNAL sig)
{
   if(UseSessionFilter && !IsTradingSession()) return;

   int activePairs = CountActivePairs();

   // No more primaries allowed
   if(activePairs >= MaxPairs) return;

   double entryLots = LotSize;

   // Open a new standalone primary on any fresh valid signal
   // regardless of the direction of other primaries/recoveries.
   if(sig == SIGNAL_BUY)
   {
      if(OpenTrade(ORDER_TYPE_BUY, entryLots, false, 0))
      {
         if(activePairs == 0) SendSignal("BUY");
         else                 SendSignal("BUY (extra primary)");
      }
   }
   else if(sig == SIGNAL_SELL)
   {
      if(OpenTrade(ORDER_TYPE_SELL, entryLots, false, 0))
      {
         if(activePairs == 0) SendSignal("SELL");
         else                 SendSignal("SELL (extra primary)");
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   // trailing/breakeven first
   TrailingAndBreakeven();

   // end-of-day negative close
   if(CloseNegativeAtEndOfDay && UseSessionFilter)
   {
      MqlDateTime tm; TimeToStruct(TimeCurrent(), tm);
      if(tm.hour==NYCloseHour && g_LastClosedDay != tm.day)
      {
         CloseNegativeTrades();
         g_LastClosedDay = tm.day;
      }
   }

   // =========================
   // CLEANUP: handle positions that have disappeared (closed by broker / SL / TP / trailing)
   // =========================
   for(int idx=ArraySize(trackedTickets)-1; idx>=0; idx--)
   {
      ulong t = trackedTickets[idx];

      // Check whether the position is still open
      bool exists = false;
      for(int p=PositionsTotal()-1;p>=0;p--)
         if(PositionGetTicket(p)==t) { exists=true; break; }

      if(exists) continue; // still open - nothing to do

      // --- Position has disappeared ---
      bool wasSecond   = trackedIsSecond[idx];
      ulong parentTkt  = trackedParentTicket[idx];
      int   closedType = trackedType[idx];

      // Remove from tracking first (safe - we captured all needed fields above)
      UntrackPosition(t);

      if(wasSecond)
      {
         // A recovery trade closed (trailing stop or TP hit).
         // If its primary is still open and still negative → reopen a new recovery.

         bool primaryStillOpen = PositionSelectByTicket(parentTkt);
         double primaryProfit = primaryStillOpen ? PositionGetDouble(POSITION_PROFIT) : 0.0;

         if(primaryStillOpen && primaryProfit < 0.0)
         {
            // Check that no replacement recovery already exists for this primary
            bool replacementExists = false;
            for(int k=0;k<ArraySize(trackedTickets);k++)
               if(trackedIsSecond[k] && trackedParentTicket[k]==parentTkt && PositionSelectByTicket(trackedTickets[k]))
                  { replacementExists=true; break; }

            if(!replacementExists)
            {
               // Primary is still negative - reopen recovery at 2x lots
               double recoveryLots = LotSize * HedgeLotMultiplier;
               double vol_max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
               if(recoveryLots > vol_max) recoveryLots = vol_max;

               // Recovery is in opposite direction to primary
               ENUM_ORDER_TYPE recType = (closedType == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
               // closedType is the direction of the recovery that just closed.
               // Primary direction is opposite to closedType.
               // New recovery must also be opposite to primary = same as closedType.
               // Re-derive from primary direction to be safe:
               if(PositionSelectByTicket(parentTkt))
               {
                  ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
                  recType = (ptype == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
                  if(OpenTrade(recType, recoveryLots, true, parentTkt))
                     PrintFormat("[%s] Recovery reopened for primary %I64u (lots=%.2f)", EA_Name, parentTkt, recoveryLots);
               }
            }
         }
         // else: primary gone or profitable - recovery closing was correct, nothing more needed
      }
      else
      {
         // A primary trade's SL fired (or it closed some other way).
         // Find and immediately close any recovery trade linked to this primary.
         for(int k=ArraySize(trackedTickets)-1; k>=0; k--)
         {
            if(!trackedIsSecond[k]) continue;
            if(trackedParentTicket[k] != t) continue;
            ulong recTicket = trackedTickets[k];
            if(PositionSelectByTicket(recTicket))
            {
               if(trade.PositionClose(recTicket))
               {
                  PrintFormat("[%s] Closed recovery %I64u - primary %I64u SL fired", EA_Name, recTicket, t);
                  UntrackPosition(recTicket);
               }
            }
            else
            {
               UntrackPosition(recTicket);
            }
         }
      }
   }

   // =========================
   // AUTO-CLOSE RECOVERY WHEN PRIMARY RETURNS TO PROFIT
   // Uses explicit trackedParentTicket matching.
   // BUG 3 FIX: require primary to be at least MinProfitPipsToCloseRecovery pips
   // positive before closing recovery - prevents spread-noise churn.
   // =========================
   double minProfitPips = MinProfitPipsToCloseRecovery * PipPoint();
   for(int i=0; i<ArraySize(trackedTickets); i++)
   {
      if(trackedIsSecond[i]) continue; // look at primaries only

      ulong primaryTicket = trackedTickets[i];
      if(!PositionSelectByTicket(primaryTicket)) continue;

      double openPx   = PositionGetDouble(POSITION_PRICE_OPEN);
      int    primType = (int)PositionGetInteger(POSITION_TYPE);
      double bidAsk   = (primType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol,SYMBOL_BID) : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double pipProfit = (primType == POSITION_TYPE_BUY) ? (bidAsk - openPx) : (openPx - bidAsk);
      if(pipProfit < minProfitPips) continue; // not sufficiently positive yet

      // Primary is sufficiently positive - close its linked recovery immediately
      for(int j=ArraySize(trackedTickets)-1; j>=0; j--)
      {
         if(!trackedIsSecond[j]) continue;
         if(trackedParentTicket[j] != primaryTicket) continue;

         ulong recTicket = trackedTickets[j];
         if(PositionSelectByTicket(recTicket))
         {
            if(trade.PositionClose(recTicket))
            {
               PrintFormat("[%s] Auto-closed recovery %I64u - primary %I64u returned to profit (%.1f pips)",
                           EA_Name, recTicket, primaryTicket, pipProfit/PipPoint());
               UntrackPosition(recTicket);
            }
         }
      }
   }

   // =========================
   // CLOSE BOTH ON FULL RECOVERY
   // When CloseOnFullRecovery=true: if a primary + its recovery together
   // have a combined floating P&L >= 0, close BOTH immediately.
   // This locks in the recovery and prevents pullback from giving it all back.
   // =========================
   if(CloseOnFullRecovery)
   {
      for(int i=ArraySize(trackedTickets)-1; i>=0; i--)
      {
         if(trackedIsSecond[i]) continue; // primaries only

         ulong primaryTicket = trackedTickets[i];
         if(!PositionSelectByTicket(primaryTicket)) continue;
         double primaryProfit = PositionGetDouble(POSITION_PROFIT);
         if(primaryProfit >= 0.0) continue; // primary already positive, normal auto-close handles it

         // Find linked recovery
         ulong recTicket = 0;
         double recProfit = 0.0;
         for(int k=0; k<ArraySize(trackedTickets); k++)
         {
            if(!trackedIsSecond[k]) continue;
            if(trackedParentTicket[k] != primaryTicket) continue;
            if(!PositionSelectByTicket(trackedTickets[k])) continue;
            recTicket = trackedTickets[k];
            recProfit = PositionGetDouble(POSITION_PROFIT);
            break;
         }
         if(recTicket == 0) continue; // no recovery open yet

         double combinedPnL = primaryProfit + recProfit;
         if(combinedPnL < 0.0) continue; // not fully recovered yet

         // Combined P&L >= 0 - close both, recovery first then primary
         bool recClosed = false;
         if(PositionSelectByTicket(recTicket))
         {
            if(trade.PositionClose(recTicket))
            {
               PrintFormat("[%s] CloseOnFullRecovery: closed recovery %I64u (combined PnL=%.2f)", EA_Name, recTicket, combinedPnL);
               UntrackPosition(recTicket);
               recClosed = true;
            }
         }
         if(recClosed && PositionSelectByTicket(primaryTicket))
         {
            if(trade.PositionClose(primaryTicket))
            {
               PrintFormat("[%s] CloseOnFullRecovery: closed primary %I64u (combined PnL=%.2f)", EA_Name, primaryTicket, combinedPnL);
               UntrackPosition(primaryTicket);
            }
         }
      }
   }

   // =========================
   // IMMEDIATE HEDGE (RECOVERY OPEN)
   // For each primary that is currently negative and has no active recovery,
   // open a recovery in the opposite direction at 2x lots.
   // =========================
   for(int i=0; i<ArraySize(trackedTickets); i++)
   {
      if(trackedIsSecond[i]) continue; // only look at primaries

      ulong primaryTicket = trackedTickets[i];
      if(!PositionSelectByTicket(primaryTicket)) continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit >= 0.0) continue; // not negative yet

      // Check if a recovery already exists for this primary
      bool recoveryExists = false;
      for(int k=0; k<ArraySize(trackedTickets); k++)
      {
         if(!trackedIsSecond[k]) continue;
         if(trackedParentTicket[k] == primaryTicket && PositionSelectByTicket(trackedTickets[k]))
         {
            recoveryExists = true;
            break;
         }
      }
      if(recoveryExists) continue;

      // Open recovery at 2x lots in the opposite direction
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double recoveryLots = LotSize * HedgeLotMultiplier;
      double vol_max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      if(recoveryLots > vol_max)
      {
         PrintFormat("[%s] Recovery lot size %.2f exceeds broker max %.2f - skipping", EA_Name, recoveryLots, vol_max);
         continue;
      }

      ENUM_ORDER_TYPE openType = (ptype == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

      if(OpenTrade(openType, recoveryLots, true, primaryTicket))
         PrintFormat("[%s] Recovery opened for primary %I64u (lots=%.2f)", EA_Name, primaryTicket, recoveryLots);

      break; // one recovery open per tick
   }

   // =========================
   // NORMAL FLOW (candle-close logic + new signal)
   // =========================
   if(!IsNewCandle()) return;

   datetime closedCandle = iTime(_Symbol,_Period,1);

   // --- CANDLE-CLOSE RULE 1 ---
   // Close recovery when its specific primary is profitable at candle close.
   // Uses trackedParentTicket to find the exact pair.
   for(int i=0; i<ArraySize(trackedTickets); i++)
   {
      if(trackedIsSecond[i]) continue;

      ulong primaryTicket = trackedTickets[i];
      if(!PositionSelectByTicket(primaryTicket)) continue;
      if(closedCandle <= trackedOpenCandle[i]) continue; // must have a closed candle after primary opened

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      int type = trackedType[i];
      double closePrice = iClose(_Symbol,_Period,1);
      double pip = PipPoint();
      double profitPips = (type==POSITION_TYPE_BUY) ?
         (closePrice - openPrice)/pip :
         (openPrice - closePrice)/pip;

      if(profitPips > 0)
      {
         // Close the recovery that is explicitly linked to this primary
         for(int j=ArraySize(trackedTickets)-1; j>=0; j--)
         {
            if(!trackedIsSecond[j]) continue;
            if(trackedParentTicket[j] != primaryTicket) continue;

            ulong recTicket = trackedTickets[j];
            if(PositionSelectByTicket(recTicket))
            {
               if(trade.PositionClose(recTicket))
               {
                  Print("Closed recovery (primary profitable at candle close)");
                  UntrackPosition(recTicket);
               }
            }
         }
      }

      // BUG 2 FIX: re-arm to the current closed candle time so RULE 1 fires
      // on every subsequent candle close (not just the first one).
      trackedOpenCandle[i] = closedCandle;
   }

   // NOTE: RULE 2 (close primary after recovery candle) has been removed.
   // The primary must survive until its SL fires or it recovers to profit.

   if(CopyBuffer(FastMAHandle,0,0,3,FastMA)<3) return;
   if(CopyBuffer(SlowMAHandle,0,0,3,SlowMA)<3) return;

   ENUM_TRADE_SIGNAL sig = GetSignal();
   if(sig != SIGNAL_NEUTRAL)
      ManageTrades(sig);
}
