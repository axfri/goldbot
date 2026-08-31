#property copyright "GoldBot"
#property version   "1.00"
#property strict
#property description "GoldBot Phase 1: hedged XAUUSD core with SL, break-even, trailing stop and timed entries"

#include <Trade/Trade.mqh>

enum ENUM_GOLDBOT_SESSION_MINUTES
  {
   SESSION_10_MINUTES = 10,
   SESSION_30_MINUTES = 30,
   SESSION_60_MINUTES = 60
  };

input group "Trading"
input string                       InpTradeSymbol          = "";
input double                       InpVolume               = 0.01;
input ulong                        InpMagicNumber          = 260901;
input int                          InpDeviationPoints       = 30;
input ENUM_GOLDBOT_SESSION_MINUTES InpSessionDuration      = SESSION_30_MINUTES;
input uint                         InpSessionId             = 1;

input group "Protection (points)"
input int                          InpInitialStopLossPoints = 300;
input int                          InpBreakEvenTriggerPoints= 300;
input int                          InpBreakEvenOffsetPoints = 20;
input int                          InpTrailingStartPoints   = 500;
input int                          InpTrailingDistancePoints= 250;
input int                          InpTrailingStepPoints    = 20;

CTrade   trade;
string   trade_symbol;
string   session_key;
datetime session_end = 0;
datetime last_entry_attempt = 0;

const int ENTRY_RETRY_SECONDS = 5;

datetime ServerTime()
  {
   datetime value=TimeTradeServer();
   return(value > 0 ? value : TimeCurrent());
  }

string BuildSessionKey()
  {
   return StringFormat("GoldBot.%I64d.%s.%I64u.%u.end",
                       AccountInfoInteger(ACCOUNT_LOGIN),trade_symbol,
                       InpMagicNumber,InpSessionId);
  }

double NormalizePrice(const double price)
  {
   const double tick_size=SymbolInfoDouble(trade_symbol,SYMBOL_TRADE_TICK_SIZE);
   const int digits=(int)SymbolInfoInteger(trade_symbol,SYMBOL_DIGITS);
   if(tick_size <= 0.0)
      return NormalizeDouble(price,digits);
   return NormalizeDouble(MathRound(price/tick_size)*tick_size,digits);
  }

double NormalizeVolume(const double volume)
  {
   const double minimum=SymbolInfoDouble(trade_symbol,SYMBOL_VOLUME_MIN);
   const double maximum=SymbolInfoDouble(trade_symbol,SYMBOL_VOLUME_MAX);
   const double step=SymbolInfoDouble(trade_symbol,SYMBOL_VOLUME_STEP);
   if(minimum <= 0.0 || maximum <= 0.0 || step <= 0.0)
      return 0.0;

   double normalized=MathFloor((volume+1e-12)/step)*step;
   normalized=MathMax(minimum,MathMin(maximum,normalized));
   return NormalizeDouble(normalized,8);
  }

int MinimumStopPoints()
  {
   const int stops=(int)SymbolInfoInteger(trade_symbol,SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze=(int)SymbolInfoInteger(trade_symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax(stops,freeze);
  }

bool IsManagedPosition(const ulong ticket)
  {
   if(!PositionSelectByTicket(ticket))
      return false;
   return PositionGetString(POSITION_SYMBOL)==trade_symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC)==InpMagicNumber;
  }

bool HasManagedPosition(const ENUM_POSITION_TYPE type)
  {
   for(int index=PositionsTotal()-1; index>=0; --index)
     {
      const ulong ticket=PositionGetTicket(index);
      if(ticket > 0 && IsManagedPosition(ticket) &&
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==type)
         return true;
     }
   return false;
  }

bool ValidateInputs()
  {
   if(InpVolume <= 0.0 || NormalizeVolume(InpVolume)<=0.0)
     {
      Print("GoldBot: invalid volume for ",trade_symbol);
      return false;
     }

   if(InpInitialStopLossPoints<=0 || InpBreakEvenTriggerPoints<=0 ||
      InpBreakEvenOffsetPoints<0 || InpTrailingStartPoints<=0 ||
      InpTrailingDistancePoints<=0 || InpTrailingStepPoints<0)
     {
      Print("GoldBot: protection parameters must be positive");
      return false;
     }

   if(InpBreakEvenOffsetPoints>=InpBreakEvenTriggerPoints)
     {
      Print("GoldBot: break-even offset must be smaller than its trigger");
      return false;
     }

   if(InpTrailingDistancePoints>=InpTrailingStartPoints)
     {
      Print("GoldBot: trailing distance must be smaller than its start level");
      return false;
     }
   return true;
  }

bool OpenManagedPosition(const ENUM_POSITION_TYPE type)
  {
   MqlTick tick;
   if(!SymbolInfoTick(trade_symbol,tick))
     {
      Print("GoldBot: cannot read tick for ",trade_symbol);
      return false;
     }

   const double point=SymbolInfoDouble(trade_symbol,SYMBOL_POINT);
   const int stop_points=MathMax(InpInitialStopLossPoints,MinimumStopPoints()+1);
   const double volume=NormalizeVolume(InpVolume);
   bool result=false;

   if(type==POSITION_TYPE_BUY)
     {
      const double sl=NormalizePrice(tick.bid-stop_points*point);
      result=trade.Buy(volume,trade_symbol,0.0,sl,0.0,"GoldBot BUY");
     }
   else
     {
      const double sl=NormalizePrice(tick.ask+stop_points*point);
      result=trade.Sell(volume,trade_symbol,0.0,sl,0.0,"GoldBot SELL");
     }

   const uint retcode=trade.ResultRetcode();
   const bool executed=result &&
                       (retcode==TRADE_RETCODE_DONE ||
                        retcode==TRADE_RETCODE_DONE_PARTIAL ||
                        retcode==TRADE_RETCODE_PLACED);
   if(!executed)
      PrintFormat("GoldBot: %s failed, retcode=%u (%s)",
                  type==POSITION_TYPE_BUY ? "BUY" : "SELL",
                  retcode,trade.ResultRetcodeDescription());
   return executed;
  }

void OpenMissingInitialPositions()
  {
   if(ServerTime()>=session_end)
      return;

   const datetime now=ServerTime();
   if(last_entry_attempt>0 && now-last_entry_attempt<ENTRY_RETRY_SECONDS)
      return;

   const bool needs_buy=!HasManagedPosition(POSITION_TYPE_BUY);
   const bool needs_sell=!HasManagedPosition(POSITION_TYPE_SELL);
   if(!needs_buy && !needs_sell)
      return;

   last_entry_attempt=now;
   if(needs_buy)
      OpenManagedPosition(POSITION_TYPE_BUY);
   if(needs_sell)
      OpenManagedPosition(POSITION_TYPE_SELL);
  }

bool IsBetterStop(const ENUM_POSITION_TYPE type,const double current_sl,
                  const double candidate,const double point)
  {
   if(current_sl==0.0)
      return true;
   const double step=InpTrailingStepPoints*point;
   if(type==POSITION_TYPE_BUY)
      return candidate>current_sl+step-0.1*point;
   return candidate<current_sl-step+0.1*point;
  }

bool IsStopAllowed(const ENUM_POSITION_TYPE type,const double stop,
                   const MqlTick &tick,const double point)
  {
   const double minimum_distance=(MinimumStopPoints()+1)*point;
   if(type==POSITION_TYPE_BUY)
      return stop<tick.bid-minimum_distance;
   return stop>tick.ask+minimum_distance;
  }

void ProtectManagedPositions()
  {
   MqlTick tick;
   if(!SymbolInfoTick(trade_symbol,tick))
      return;

   const double point=SymbolInfoDouble(trade_symbol,SYMBOL_POINT);
   for(int index=PositionsTotal()-1; index>=0; --index)
     {
      const ulong ticket=PositionGetTicket(index);
      if(ticket==0 || !IsManagedPosition(ticket))
         continue;

      const ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      const double open_price=PositionGetDouble(POSITION_PRICE_OPEN);
      const double current_sl=PositionGetDouble(POSITION_SL);
      const double current_tp=PositionGetDouble(POSITION_TP);
      const double market_price=(type==POSITION_TYPE_BUY ? tick.bid : tick.ask);
      const double profit_points=(type==POSITION_TYPE_BUY ? market_price-open_price : open_price-market_price)/point;

      double candidate=current_sl;
      bool should_modify=false;

      if(profit_points>=InpBreakEvenTriggerPoints)
        {
         const double break_even=NormalizePrice(type==POSITION_TYPE_BUY
                                                ? open_price+InpBreakEvenOffsetPoints*point
                                                : open_price-InpBreakEvenOffsetPoints*point);
         if(IsBetterStop(type,candidate,break_even,point))
           {
            candidate=break_even;
            should_modify=true;
           }
        }

      if(profit_points>=InpTrailingStartPoints)
        {
         const double trailing=NormalizePrice(type==POSITION_TYPE_BUY
                                              ? market_price-InpTrailingDistancePoints*point
                                              : market_price+InpTrailingDistancePoints*point);
         if(IsBetterStop(type,candidate,trailing,point))
           {
            candidate=trailing;
            should_modify=true;
           }
        }

      if(!should_modify || !IsStopAllowed(type,candidate,tick,point))
         continue;

      const bool request_ok=trade.PositionModify(ticket,candidate,current_tp);
      const uint retcode=trade.ResultRetcode();
      if(!request_ok || (retcode!=TRADE_RETCODE_DONE && retcode!=TRADE_RETCODE_NO_CHANGES))
         PrintFormat("GoldBot: SL update failed for #%I64u, retcode=%u (%s)",
                     ticket,retcode,trade.ResultRetcodeDescription());
     }
  }

void ProcessBot()
  {
   // Protection deliberately continues after the entry session has expired.
   ProtectManagedPositions();
   OpenMissingInitialPositions();
  }

int OnInit()
  {
   trade_symbol=(StringLen(InpTradeSymbol)>0 ? InpTradeSymbol : _Symbol);
   if(!SymbolSelect(trade_symbol,true))
     {
      Print("GoldBot: symbol is unavailable: ",trade_symbol);
      return INIT_FAILED;
     }

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("GoldBot: a hedging account is required to hold BUY and SELL simultaneously");
      return INIT_FAILED;
     }

   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(trade_symbol);
   trade.SetAsyncMode(false);

   session_key=BuildSessionKey();
   if(GlobalVariableCheck(session_key))
      session_end=(datetime)GlobalVariableGet(session_key);
   else
     {
      session_end=ServerTime()+(int)InpSessionDuration*60;
      if(!GlobalVariableSet(session_key,(double)session_end))
        {
         Print("GoldBot: cannot persist session timer");
         return INIT_FAILED;
        }
     }

   EventSetTimer(1);
   PrintFormat("GoldBot started on %s; entries end at %s; session id=%u",
               trade_symbol,TimeToString(session_end,TIME_DATE|TIME_SECONDS),InpSessionId);
   ProcessBot();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTick()
  {
   ProcessBot();
  }

void OnTimer()
  {
   ProcessBot();
  }
