//+------------------------------------------------------------------+
//| MA Crossover EA - Hedge + Double Lot + Session Filter (v2.19.1)  |
//| Original logic preserved, with safe candle-close fix + drawdown   |
//+------------------------------------------------------------------+
#property copyright "xAI Grok"
#property version   "2.19.1"
#property strict

#include <Trade/Trade.mqh>

//=== CONFIG =========================================================
input string  EA_Name               = "MA_Crossover_EA_Hedge_Double";
input double  LotSize               = 0.06;
input double  StopLossPips          = 100;
input double  TakeProfitPips        = 1000;

input int     MAFastPeriod          = 1;
input ENUM_MA_METHOD MAFastMethod   = MODE_SMA;
input ENUM_APPLIED_PRICE MAFastPrice= PRICE_CLOSE;

input int     MASlowPeriod          = 9;
input ENUM_MA_METHOD MASlowMethod   = MODE_SMA;
input ENUM_APPLIED_PRICE MASlowPrice= PRICE_CLOSE;

input int     MagicNumber           = 12685;
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

input double  HedgeLotMultiplier    = 2.0;

//=== SESSION CONTROL ===============================================
input bool    UseSessionFilter      = true;
input int     LondonOpenHour        = 8;
input int     NYCloseHour           = 22;
input bool    CloseNegativeAtEndOfDay = true;

//=== DRAWDOWN PROTECTION (NEW, disabled by default) ================
input bool    UseDrawdownProtection = false;
input double  MaxDrawdownPercent    = 20.0;   // closes all EA trades if equity DD reaches this percent
input bool    PauseTradingAfterDrawdown = true;

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
bool g_DrawdownLock = false;

// Tracking arrays
ulong    trackedTickets[];
datetime trackedOpenCandle[]; // recorded completed candle time at open (index 1)
double   trackedVolume[];
int      trackedType[];       // POSITION_TYPE_BUY or SELL
bool     trackedIsSecond[];   // true if doubled volume

//+------------------------------------------------------------------+
double PipPoint()
{
   if(_Digits==3||_Digits==5) return _Point*10.0;
   return _Point;
}

//+------------------------------------------------------------------+
void DebugPrint(const string msg)
{
   if(DebugMode)
      PrintFormat("[%s][%s][TF=%s] %s", EA_Name, _Symbol, EnumToString(_Period), msg);
}

//+------------------------------------------------------------------+
bool IsTradingSession()
{
   if(!UseSessionFilter) return true;
   MqlDateTime tm; TimeToStruct(TimeCurrent(), tm);
   return (tm.hour >= LondonOpenHour && tm.hour < NYCloseHour);
}

//+------------------------------------------------------------------+
bool IsOurPosition(const ulong ticket)
{
   if(ticket==0) return false;
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetString(POSITION_SYMBOL)!=_Symbol) return false;
   if((int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) return false;
   return true;
}

//+------------------------------------------------------------------+
int FindTrackedIndex(const ulong ticket)
{
   for(int i=0;i<ArraySize(trackedTickets);i++)
      if(trackedTickets[i]==ticket) return i;
   return -1;
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
      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit < 0.0)
      {
         if(trade.PositionClose(ticket))
            PrintFormat("[%s] Closed negative trade at EOD (ticket=%I64u profit=%.2f)", EA_Name, ticket, profit);
         else
            PrintFormat("[%s] Failed to close negative trade (ticket=%I64u ret=%d)", EA_Name, ticket, trade.ResultRetcode());
      }
   }
}

//+------------------------------------------------------------------+
void CloseAllOurTrades(const string reason)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!IsOurPosition(ticket)) continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(trade.PositionClose(ticket))
         PrintFormat("[%s] Closed ticket=%I64u reason=%s profit=%.2f", EA_Name, ticket, reason, profit);
      else
         PrintFormat("[%s] Failed close ticket=%I64u reason=%s ret=%d", EA_Name, ticket, reason, trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
bool CheckDrawdownProtection()
{
   if(!UseDrawdownProtection) return false;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance <= 0.0) return false;

   double ddPercent = ((balance - equity) / balance) * 100.0;
   if(ddPercent < MaxDrawdownPercent) return false;

   PrintFormat("[%s] Drawdown protection triggered. Balance=%.2f Equity=%.2f DD=%.2f%% Limit=%.2f%%",
               EA_Name, balance, equity, ddPercent, MaxDrawdownPercent);

   CloseAllOurTrades("Drawdown protection triggered");
   if(PauseTradingAfterDrawdown)
      g_DrawdownLock = true;

   return true;
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
// Tracking helpers
//+------------------------------------------------------------------+
void TrackPositionOpen(ulong ticket)
{
   if(ticket==0) return;
   if(!PositionSelectByTicket(ticket)) return;
   if(PositionGetString(POSITION_SYMBOL)!=_Symbol) return;
   if((int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) return;
   if(FindTrackedIndex(ticket) >= 0) return;

   datetime t_open = iTime(_Symbol,_Period,1); // last completed candle at open
   double vol = PositionGetDouble(POSITION_VOLUME);
   int type = (int)PositionGetInteger(POSITION_TYPE);
   bool isSecond = (NormalizeDouble(vol,2) > NormalizeDouble(LotSize,2)+0.0000001);

   int sz = ArraySize(trackedTickets);
   ArrayResize(trackedTickets, sz+1);
   ArrayResize(trackedOpenCandle, sz+1);
   ArrayResize(trackedVolume, sz+1);
   ArrayResize(trackedType, sz+1);
   ArrayResize(trackedIsSecond, sz+1);

   trackedTickets[sz] = ticket;
   trackedOpenCandle[sz] = t_open;
   trackedVolume[sz] = vol;
   trackedType[sz] = type;
   trackedIsSecond[sz] = isSecond;

   DebugPrint(StringFormat("Track open t=%I64u vol=%.2f type=%d second=%s openCandle=%s", ticket, vol, type, isSecond ? "Y":"N", TimeToString(t_open, TIME_DATE|TIME_MINUTES)));
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
         }
         ArrayResize(trackedTickets, sz-1);
         ArrayResize(trackedOpenCandle, sz-1);
         ArrayResize(trackedVolume, sz-1);
         ArrayResize(trackedType, sz-1);
         ArrayResize(trackedIsSecond, sz-1);
         DebugPrint(StringFormat("Untracked t=%I64u", ticket));
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
   Print(EA_Name,": Init v2.19.1");
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

   g_DrawdownLock = false;
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   PrintFormat("[%s] Deinit reason=%d", EA_Name, reason);
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
bool OpenTrade(const ENUM_ORDER_TYPE type, double lots)
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
         TrackPositionOpen(t);
         break;
      }
   }

   PrintFormat("[%s] %s opened (%.2f) SL/TP set", EA_Name, EnumToString(type), lots);
   return true;
}

//+------------------------------------------------------------------+
bool ModifyPositionSL(ulong ticket, double newSL)
{
   if(!PositionSelectByTicket(ticket)) return false;
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
void ManageTrades(const ENUM_TRADE_SIGNAL sig)
{
   if(g_DrawdownLock) return;
   if(UseSessionFilter && !IsTradingSession()) return;

   if(CountOpenPositions() == 0)
   {
      double entryLots = LotSize;
      if(sig==SIGNAL_BUY) { if(OpenTrade(ORDER_TYPE_BUY, entryLots)) SendSignal("BUY"); }
      else if(sig==SIGNAL_SELL) { if(OpenTrade(ORDER_TYPE_SELL, entryLots)) SendSignal("SELL"); }
      return;
   }

   if(CountOpenPositions() == 1)
   {
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong t = PositionGetTicket(i);
         if(t==0) continue;
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if((int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

         double profit = PositionGetDouble(POSITION_PROFIT);
         ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double existingLots = PositionGetDouble(POSITION_VOLUME);

         if(profit < 0.0)
         {
            double newLots = NormalizeDouble(existingLots * HedgeLotMultiplier, 2);
            ENUM_ORDER_TYPE openType = (ptype == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

            if(DebugMode) PrintFormat("[%s] Existing pos (ticket=%I64u) is negative (%.2f). Opening opposite doubled lot %.2f", EA_Name, t, profit, newLots);

            if(OpenTrade(openType, newLots))
            {
               Sleep(50);
               if(PositionSelectByTicket(t))
               {
                  if(trade.PositionClose(t))
                  {
                     PrintFormat("[%s] Closed original (ticket=%I64u) after opening doubled opposite", EA_Name, t);
                     UntrackPosition(t);
                  }
                  else
                  {
                     PrintFormat("[%s] Failed to close original (ticket=%I64u) after opening doubled opposite", EA_Name, t);
                  }
               }
            }
         }
         break;
      }
   }
}

//+------------------------------------------------------------------+
void ProcessCandleCloseRules()
{
   datetime closedCandle = iTime(_Symbol,_Period,1);
   int sz = ArraySize(trackedTickets);
   if(sz <= 0) return;

   ulong closeQueue[];
   ArrayResize(closeQueue, 0);

   // RULE 1: Close SECOND if FIRST is profitable at candle close
   for(int i=0;i<sz;i++)
   {
      if(i >= ArraySize(trackedTickets)) break;
      if(trackedIsSecond[i]) continue;

      ulong firstTicket = trackedTickets[i];
      if(!PositionSelectByTicket(firstTicket)) continue;
      if(closedCandle <= trackedOpenCandle[i]) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      int type = trackedType[i];
      double closePrice = iClose(_Symbol,_Period,1);
      double pip = PipPoint();

      double profitPips = (type==POSITION_TYPE_BUY) ?
         (closePrice - openPrice)/pip :
         (openPrice - closePrice)/pip;

      if(profitPips > 0)
      {
         for(int j=0;j<ArraySize(trackedTickets);j++)
         {
            if(!trackedIsSecond[j]) continue;
            if(trackedType[j] == trackedType[i]) continue;

            ulong secondTicket = trackedTickets[j];
            bool alreadyQueued=false;
            for(int q=0;q<ArraySize(closeQueue);q++)
               if(closeQueue[q]==secondTicket) { alreadyQueued=true; break; }

            if(!alreadyQueued)
            {
               int qsz = ArraySize(closeQueue);
               ArrayResize(closeQueue, qsz+1);
               closeQueue[qsz] = secondTicket;
            }
         }
      }

      if(i < ArraySize(trackedOpenCandle))
         trackedOpenCandle[i] = LONG_MAX;
   }

   // RULE 2: Close FIRST after next candle of SECOND trade
   for(int i=0;i<ArraySize(trackedTickets);i++)
   {
      if(!trackedIsSecond[i]) continue;
      if(closedCandle <= trackedOpenCandle[i]) continue;

      for(int j=0;j<ArraySize(trackedTickets);j++)
      {
         if(trackedIsSecond[j]) continue;
         if(trackedType[j] == trackedType[i]) continue;

         ulong firstTicket = trackedTickets[j];
         bool alreadyQueued=false;
         for(int q=0;q<ArraySize(closeQueue);q++)
            if(closeQueue[q]==firstTicket) { alreadyQueued=true; break; }

         if(!alreadyQueued)
         {
            int qsz = ArraySize(closeQueue);
            ArrayResize(closeQueue, qsz+1);
            closeQueue[qsz] = firstTicket;
         }
      }

      trackedOpenCandle[i] = LONG_MAX;
   }

   // Execute queued closes after loops to avoid array-out-of-range from resize/untrack during iteration
   for(int q=0;q<ArraySize(closeQueue);q++)
   {
      ulong ticket = closeQueue[q];
      if(!PositionSelectByTicket(ticket))
      {
         UntrackPosition(ticket);
         continue;
      }

      bool isSecond = false;
      int idx = FindTrackedIndex(ticket);
      if(idx >= 0) isSecond = trackedIsSecond[idx];

      if(trade.PositionClose(ticket))
      {
         if(isSecond) Print("Closed SECOND (first profitable)");
         else         Print("Closed FIRST (after second candle)");
         UntrackPosition(ticket);
      }
      else
      {
         PrintFormat("[%s] Failed candle-close logic close ticket=%I64u ret=%d", EA_Name, ticket, trade.ResultRetcode());
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(CheckDrawdownProtection()) return;

   TrailingAndBreakeven();

   if(CloseNegativeAtEndOfDay && UseSessionFilter)
   {
      MqlDateTime tm; TimeToStruct(TimeCurrent(), tm);
      if(tm.hour==NYCloseHour && g_LastClosedDay != tm.day)
      {
         CloseNegativeTrades();
         g_LastClosedDay = tm.day;
      }
   }

   for(int idx=ArraySize(trackedTickets)-1; idx>=0; idx--)
   {
      ulong t = trackedTickets[idx];
      bool exists=false;
      for(int p=PositionsTotal()-1;p>=0;p--)
      {
         if(PositionGetTicket(p)==t) { exists=true; break; }
      }
      if(!exists) UntrackPosition(t);
   }

   // IMMEDIATE HEDGE (ORIGINAL BEHAVIOR PRESERVED)
   const double MinLossAmount = 0.0;

   if(CountOpenPositions() < 2)
   {
      for(int p=PositionsTotal()-1; p>=0; p--)
      {
         ulong orig_ticket = PositionGetTicket(p);
         if(orig_ticket==0) continue;
         if(!PositionSelectByTicket(orig_ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit >= -MinLossAmount) continue;

         ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double existingLots = PositionGetDouble(POSITION_VOLUME);
         double newLots = NormalizeDouble(existingLots * HedgeLotMultiplier, 2);
         ENUM_ORDER_TYPE openType = (ptype == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

         if(OpenTrade(openType, newLots))
            PrintFormat("[%s] Hedge opened against ticket %I64u", EA_Name, orig_ticket);

         break;
      }
   }

   if(!IsNewCandle()) return;

   ProcessCandleCloseRules();

   if(CopyBuffer(FastMAHandle,0,0,3,FastMA)<3) return;
   if(CopyBuffer(SlowMAHandle,0,0,3,SlowMA)<3) return;

   ENUM_TRADE_SIGNAL sig = GetSignal();
   if(sig != SIGNAL_NEUTRAL)
      ManageTrades(sig);
}
