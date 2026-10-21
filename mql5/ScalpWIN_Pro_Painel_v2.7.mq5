//+------------------------------------------------------------------+
//|                                     ScalpWIN_Pro_Painel v2.7.mq5 |
//|   v2.6: diagnóstico CSV de sinais, ordens e custos demo/real     |
//|   v2.5: meta fixa ativa o trailing — após bater a meta, o piso   |
//|         de X% acompanha o maior saldo do dia; antes vale só o stop|
//|   v2.4: gráfico do resultado acumulado após cada negociação     |
//|   v2.3: extremos do acumulado diário e painel modernizado        |
//|   v2.2: resultado MENSAL no painel (mesmo critério do testador)  |
//|   v2.1: reset diário, pausa por perdas, tick size, candle único  |
//|   por barra, P&L com comissão/swap (igual ao testador)           |
//+------------------------------------------------------------------+
#property copyright "Lovable"
#property link      "https://lovable.dev"
#property version   "2.70"
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//--- GESTÃO DE RISCO E PAYOFF
input group "=== Gestão de Ordens & Payoff ==="
input ulong   InpMagicNumber          = 991122;       // Magic Number
input double  InpLots                 = 1.0;          // Contratos
input int     InpTakeProfitPts        = 130;          // Take Profit (pts)
input int     InpStopLossPts          = 90;           // Stop Loss (pts)
input bool    InpUseBreakeven         = true;         // Ativar Breakeven?
input int     InpBreakevenTriggerPts  = 65;           // Gatilho do Breakeven (pts)
input int     InpBreakevenLockPts     = 15;           // Pontos garantidos

//--- CONTROLE DE OVERTRADING
input group "=== Proteção Anti-Overtrading ==="
input int     InpMaxDailyTrades       = 15;           // Máx. trades por dia
input int     InpMaxConsecutiveLoss   = 2;            // Stops seguidos antes da pausa
input int     InpPauseMinutesAfterLoss= 25;           // Minutos de pausa

//--- ESTRATÉGIA
input group "=== Indicadores & Tendência ==="
input ENUM_TIMEFRAMES InpTimeframe    = PERIOD_M1;    // Tempo gráfico
input int     InpEmaPeriod            = 21;           // Período da EMA
input int     InpMinCandleSize        = 35;           // Tamanho mín. do candle (pts)
input double  InpMinEmaSlopePts       = 5.0;          // Inclinação mínima (pts)
input group "=== Filtros Experimentais v2.7 ==="
input bool InpUseM5TrendFilter=true;
input int InpM5EmaPeriod=21;
input bool InpUseCandleMaxFilter=true;
input int InpMaxCandleSize=100;
input bool InpUseCandleBodyFilter=true;
input double InpMinCandleBodyPct=60.0;
input bool InpUseADXFilter=false;
input int InpADXPeriod=14;
input double InpMinADX=20.0;
input bool InpUseEmaDistanceFilter=false;
input double InpMaxEmaDistancePts=80.0;

//--- HORÁRIOS B3
input group "=== Horários de Operação ==="
input string  InpStartTime            = "09:30";      // Início
input string  InpEndTime              = "16:30";      // Limite para novas entradas
input string  InpCloseTime            = "17:30";      // Fechamento compulsório

//--- METAS FINANCEIRAS DIÁRIAS (R$)
input group "=== Metas Diárias Financeiras (R$) ==="
input double  InpMaxDailyProfit       = 500.0;        // Meta de ganho (ativa o trailing)
input double  InpMaxDailyLoss         = 1000.0;       // Limite de perda
input double  InpTrailingMetaPct      = 30.0;         // Devolução máx. após a meta (% do lucro máx.)

//--- DIAGNÓSTICO (não muda os sinais nem a gestão)
input group "=== Comparação Demo x Real ==="
input bool    InpEnableAudit = true;       // Salvar diagnóstico CSV?
input string  InpComparisonTag = "PAR_01"; // Mesmo identificador no demo e real

//--- PAINEL
input group "=== Painel Gráfico ==="
input bool    InpShowPanel            = true;         // Mostrar painel (desligue p/ otimização)
input int     InpPanelX               = 20;           // Posição X
input int     InpPanelY               = 30;           // Posição Y

//--- Globais
int      handleEMA;
int handleM5EMA=INVALID_HANDLE, handleADX=INVALID_HANDLE;
datetime lastBarTime   = 0;
bool     dailyBlocked  = false;
bool     targetHit     = false;     // meta do dia já foi batida (ativa o trailing)
datetime pauseUntilTime= 0;
int      pauseBaseLosses = 0;     // nº de perdas quando a pausa foi criada
datetime currentDay    = 0;       // controle de virada de dia
string   panelPrefix   = "ScalpPro_";
double   g_point, g_tickSize;
int      g_digits, g_stopLevel;
int      g_lastGraphTrades = -1;
double   g_lastGraphPL = DBL_MAX;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double NormPrice(double price)
{
   if(g_tickSize > 0)
      price = MathRound(price / g_tickSize) * g_tickSize;
   return NormalizeDouble(price, g_digits);
}

datetime DayStart(datetime t)
{
   MqlDateTime d; TimeToStruct(t, d);
   d.hour = 0; d.min = 0; d.sec = 0;
   return StructToTime(d);
}

datetime MonthStart(datetime t)
{
   MqlDateTime d; TimeToStruct(t, d);
   d.day = 1; d.hour = 0; d.min = 0; d.sec = 0;
   return StructToTime(d);
}

int MinutesOfString(string hhmm)
{
   string parts[];
   if(StringSplit(hhmm, ':', parts) < 2) return 0;
   return (int)StringToInteger(parts[0]) * 60 + (int)StringToInteger(parts[1]);
}

void SetupFillingMode()
{
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_IOC) != 0)       trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((filling & SYMBOL_FILLING_FOK) != 0)  trade.SetTypeFilling(ORDER_FILLING_FOK);
   else                                          trade.SetTypeFilling(ORDER_FILLING_RETURN);
}


// CSV observador: eventos no buffer; escrita e histórico fora de OnTradeTransaction.
// Não contém login/nome/saldo da conta; cada sessão tem arquivo separado.
string auditFile = "", auditSession = "", auditMode = "", auditBuffer[];
int auditHandle = INVALID_HANDLE;
ulong auditPending[], auditSeen[];
datetime auditLastBar = 0;
string auditLastState = "";
datetime auditLastRecovery = 0;
bool auditWarned = false;
struct AuditOrder { ulong order; string key; double bid; double ask; };
AuditOrder auditOrders[];

string AuditCell(string text)
{
   StringReplace(text, ";", ","); StringReplace(text, "\r", " ");
   StringReplace(text, "\n", " ");
   // Evita fórmulas ao abrir comentários/textos em planilhas.
   if(StringLen(text)>0 && (StringSubstr(text,0,1)=="=" || StringSubstr(text,0,1)=="@")) text="'"+text;
   return text;
}
string AuditNum(double value) { return DoubleToString(value,8); }
string AuditKey()
{
   return _Symbol+"_"+EnumToString(InpTimeframe)+"_"+(string)InpMagicNumber+"_"+
          (string)(long)iTime(_Symbol,InpTimeframe,0);
}
// Dados de uma linha, com zeros para campos que não se aplicam ao evento.
void AuditLog(string event,string detail,string key="",datetime candle=0,
              double o=0,double h=0,double l=0,double c=0,double ema=0,double slope=0,
              double bid=0,double ask=0,string side="",double requested=0,double executed=0,
              double volume=0,double sl=0,double tp=0,double elapsed=0,uint retcode=0,
              ulong order=0,ulong deal=0,ulong position=0,double profit=0,double commission=0,
              double swap=0,double fee=0,string entry="",string reason="",double adverse=0,
              string benchmark="",uint requestId=0)
{
   if(!InpEnableAudit) return;
   string row=AuditCell(auditSession)+";"+AuditCell(InpComparisonTag)+";"+auditMode+";"+
      AuditCell(AccountInfoString(ACCOUNT_SERVER))+";"+TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)+";"+
      (string)(long)TimeGMT()+";"+AuditCell(_Symbol)+";"+EnumToString(InpTimeframe)+";"+
      (string)InpMagicNumber+";"+event+";"+AuditCell(key)+";"+AuditCell(detail)+";"+(string)(long)candle+";"+
      AuditNum(o)+";"+AuditNum(h)+";"+AuditNum(l)+";"+AuditNum(c)+";"+AuditNum(ema)+";"+AuditNum(slope)+";"+
      AuditNum(bid)+";"+AuditNum(ask)+";"+AuditNum(g_point>0?(ask-bid)/g_point:0)+";"+side+";"+
      AuditNum(requested)+";"+AuditNum(executed)+";"+AuditNum(volume)+";"+AuditNum(sl)+";"+AuditNum(tp)+";"+
      AuditNum(elapsed)+";"+(string)retcode+";"+(string)order+";"+(string)deal+";"+(string)position+";"+
      AuditNum(profit)+";"+AuditNum(commission)+";"+AuditNum(swap)+";"+AuditNum(fee)+";"+
      AuditNum(profit+commission+swap+fee)+";"+entry+";"+reason+";"+AuditNum(adverse)+";"+benchmark+";"+(string)requestId;
   int n=ArraySize(auditBuffer);
   if(n>=8192) { if(!auditWarned) Print("AUDIT: buffer cheio, registros descartados. Diagnóstico incompleto."); auditWarned=true; return; }
   ArrayResize(auditBuffer,n+1); auditBuffer[n]=row;
}
void AuditFlush()
{
   if(auditHandle==INVALID_HANDLE) return;
   for(int i=0;i<ArraySize(auditBuffer);i++)
      if(FileWriteString(auditHandle,auditBuffer[i]+"\r\n")==0)
      { Print("AUDIT: erro ao gravar CSV ",GetLastError(),". Diagnóstico incompleto."); FileClose(auditHandle); auditHandle=INVALID_HANDLE; return; }
   ArrayResize(auditBuffer,0); FileFlush(auditHandle);
}
void AuditInit()
{
   if(!InpEnableAudit) return;
   auditMode=MQLInfoInteger(MQL_TESTER)?"TESTER":EnumToString((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE));
   auditSession=(string)(long)TimeLocal()+"_"+(string)GetMicrosecondCount();
   auditFile="ScalpWIN_Audit_"+auditMode+"_"+auditSession+".csv";
   auditHandle=FileOpen(auditFile,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON|FILE_SHARE_READ,';',CP_UTF8);
   if(auditHandle==INVALID_HANDLE) { Print("AUDIT: não foi possível criar CSV: ",GetLastError()); return; }
   string header="session;comparison;mode;server;server_time;utc_seconds;symbol;timeframe;magic;event;signal_key;detail;candle_time;open;high;low;close;ema;slope_points;bid;ask;spread_points;side;requested_price;executed_price;volume;sl;tp;elapsed_ms;retcode;order;deal;position_id;profit;commission;swap;fee;net_deal;entry;reason;adverse_slippage_points;benchmark;request_id";
   FileWriteString(auditHandle,header+"\r\n");
   string settings=StringFormat("v2.70 lots=%.4f TP=%d SL=%d BE=%d trigger=%d lock=%d EMA=%d candle=%d slope=%.4f trades=%d lossPause=%d pauseMin=%d start=%s end=%s close=%s target=%.2f dailyStop=%.2f trailing=%.2f point=%.8f tickSize=%.8f stops=%d freeze=%d volMin=%.4f volStep=%.4f filling=%d execution=%d marginMode=%d deviation=20 currency=%s terminalBuild=%d ping_us=%d",
      InpLots,InpTakeProfitPts,InpStopLossPts,(int)InpUseBreakeven,InpBreakevenTriggerPts,InpBreakevenLockPts,
      InpEmaPeriod,InpMinCandleSize,InpMinEmaSlopePts,InpMaxDailyTrades,InpMaxConsecutiveLoss,InpPauseMinutesAfterLoss,
      InpStartTime,InpEndTime,InpCloseTime,InpMaxDailyProfit,InpMaxDailyLoss,InpTrailingMetaPct,g_point,g_tickSize,g_stopLevel,
      (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_FREEZE_LEVEL),SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP),
      (int)SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE),(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_EXEMODE),
      (int)AccountInfoInteger(ACCOUNT_MARGIN_MODE),AccountInfoString(ACCOUNT_CURRENCY),(int)TerminalInfoInteger(TERMINAL_BUILD),(int)TerminalInfoInteger(TERMINAL_PING_LAST));
   AuditLog("SESSION",settings);
   if(!EventSetTimer(1)) Print("AUDIT: timer indisponível; verifique o Diário. Erro ",GetLastError());
   AuditFlush();
   Print("AUDIT CSV: ",TerminalInfoString(TERMINAL_COMMONDATA_PATH),"\\Files\\",auditFile);
}
void AuditState(string state)
{
   if(!InpEnableAudit) return;
   datetime bar=iTime(_Symbol,InpTimeframe,0);
   // Um estado por mudança/barra, sem registrar a contagem da pausa a cada tick.
   string normalized=StringFind(state,"Pausa Risco")==0?"Pausa Risco":state;
   if(bar==auditLastBar && normalized==auditLastState) return;
   auditLastBar=bar; auditLastState=normalized;
   AuditLog("STATE",normalized,AuditKey());
}
void AuditTradeResult(string action,bool methodOK,MqlTick &before,ulong started,string key)
{
   if(!InpEnableAudit) return;
   double elapsed=(double)(GetMicrosecondCount()-started)/1000.0;
   MqlTradeRequest req={}; MqlTradeResult res={}; trade.Request(req); trade.Result(res);
   AuditLog("ORDER",action+" method="+(methodOK?"true":"false")+" comment="+res.comment+
      " external="+(string)res.retcode_external+" filling="+EnumToString(req.type_filling),key,
      0,0,0,0,0,0,0,before.bid,before.ask,EnumToString(req.type),req.price,res.price,req.volume,req.sl,req.tp,
      elapsed,res.retcode,res.order,res.deal,req.position,0,0,0,0,"","",0,"",res.request_id);
   if(res.order>0 && (req.action==TRADE_ACTION_DEAL))
   {
      int n=ArraySize(auditOrders); ArrayResize(auditOrders,n+1);
      auditOrders[n].order=res.order; auditOrders[n].key=key;
      auditOrders[n].bid=before.bid; auditOrders[n].ask=before.ask;
   }
}
bool AuditHasSeen(ulong ticket)
{
   for(int i=0;i<ArraySize(auditSeen);i++) if(auditSeen[i]==ticket) return true;
   return false;
}
void AuditQueue(ulong ticket)
{
   if(ticket==0 || AuditHasSeen(ticket)) return;
   for(int i=0;i<ArraySize(auditPending);i++) if(auditPending[i]==ticket) return;
   int n=ArraySize(auditPending); ArrayResize(auditPending,n+1); auditPending[n]=ticket;
}
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
   if(InpEnableAudit && trans.type==TRADE_TRANSACTION_DEAL_ADD) AuditQueue(trans.deal);
}
void AuditDrain()
{
   // Rattrapage diário: recupera negócios mesmo se um evento não chegou ao callback.
   if(TimeCurrent()-auditLastRecovery>=5)
   {
      auditLastRecovery=TimeCurrent();
      if(HistorySelect(DayStart(TimeCurrent()),TimeCurrent()+1))
         for(int i=0;i<HistoryDealsTotal();i++) AuditQueue(HistoryDealGetTicket(i));
   }
   for(int i=ArraySize(auditPending)-1;i>=0;i--)
   {
      ulong ticket=auditPending[i];
      if(!HistoryDealSelect(ticket)) continue; // nova tentativa no próximo timer
      string symbol=HistoryDealGetString(ticket,DEAL_SYMBOL);
      long magic=HistoryDealGetInteger(ticket,DEAL_MAGIC);
      ENUM_DEAL_TYPE type=(ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket,DEAL_TYPE);
      bool own=(symbol==_Symbol && magic==(long)InpMagicNumber);
      bool accountCost=(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL &&
         (HistoryDealGetDouble(ticket,DEAL_COMMISSION)!=0 || HistoryDealGetDouble(ticket,DEAL_FEE)!=0 ||
          type==DEAL_TYPE_COMMISSION || type==DEAL_TYPE_COMMISSION_DAILY || type==DEAL_TYPE_COMMISSION_MONTHLY));
      if(own || accountCost)
      {
         ulong order=(ulong)HistoryDealGetInteger(ticket,DEAL_ORDER);
         double price=HistoryDealGetDouble(ticket,DEAL_PRICE), b=0,a=0,adverse=0;
         string key="",benchmark="UNAVAILABLE";
         for(int k=0;k<ArraySize(auditOrders);k++) if(auditOrders[k].order==order)
         { key=auditOrders[k].key; b=auditOrders[k].bid; a=auditOrders[k].ask;
           if(g_point>0 && a>0 && b>0 && (type==DEAL_TYPE_BUY || type==DEAL_TYPE_SELL))
           { adverse=(type==DEAL_TYPE_BUY)?(price-a)/g_point:(b-price)/g_point; benchmark="PRE_SEND_QUOTE"; }
           break; }
         AuditLog(own?"DEAL":"ACCOUNT_COST_UNALLOCATED",
            "deal_time_msc="+(string)HistoryDealGetInteger(ticket,DEAL_TIME_MSC)+" comment="+HistoryDealGetString(ticket,DEAL_COMMENT),
            key,0,0,0,0,0,0,0,b,a,EnumToString(type),0,price,HistoryDealGetDouble(ticket,DEAL_VOLUME),
            HistoryDealGetDouble(ticket,DEAL_SL),HistoryDealGetDouble(ticket,DEAL_TP),0,0,order,ticket,
            (ulong)HistoryDealGetInteger(ticket,DEAL_POSITION_ID),HistoryDealGetDouble(ticket,DEAL_PROFIT),
            HistoryDealGetDouble(ticket,DEAL_COMMISSION),HistoryDealGetDouble(ticket,DEAL_SWAP),HistoryDealGetDouble(ticket,DEAL_FEE),
            EnumToString((ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket,DEAL_ENTRY)),
            EnumToString((ENUM_DEAL_REASON)HistoryDealGetInteger(ticket,DEAL_REASON)),adverse,benchmark);
      }
      int n=ArraySize(auditSeen); ArrayResize(auditSeen,n+1); auditSeen[n]=ticket;
      int last=ArraySize(auditPending)-1; auditPending[i]=auditPending[last]; ArrayResize(auditPending,last);
   }
}
void OnTimer()
{
   if(!InpEnableAudit || auditHandle==INVALID_HANDLE) return;
   AuditDrain(); AuditFlush();
}

//+------------------------------------------------------------------+
//| Painel                                                           |
//+------------------------------------------------------------------+
void CreatePanelBox(string name, int x, int y, int width, int height, color bg, color border)
{
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, border);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void CreatePanelLabel(string name, string text, int x, int y, color clr, int fontSize = 9, bool bold = false)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Segoe UI Bold" : "Segoe UI");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void UpdatePanelLabel(string name, string text, color clr = clrNONE)
{
   if(!InpShowPanel) return;
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   if(clr != clrNONE) ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

void InitDashboard()
{
   if(!InpShowPanel) return;
   int x = InpPanelX, y = InpPanelY, w = 330, h = 495;

   CreatePanelBox(panelPrefix + "BG", x, y, w, h, C'17,21,29', C'55,65,82');
   CreatePanelBox(panelPrefix + "Header", x, y, w, 46, C'11,14,20', C'55,65,82');
   CreatePanelBox(panelPrefix + "Accent", x, y, 4, 46, C'0,188,212', C'0,188,212');
   CreatePanelBox(panelPrefix + "DailyCard", x + 12, y + 58, 149, 62, C'24,30,40', C'49,59,75');
   CreatePanelBox(panelPrefix + "MonthCard", x + 169, y + 58, 149, 62, C'24,30,40', C'49,59,75');
   CreatePanelBox(panelPrefix + "MaxCard", x + 12, y + 130, 149, 62, C'20,38,35', C'32,82,69');
   CreatePanelBox(panelPrefix + "MinCard", x + 169, y + 130, 149, 62, C'42,28,32', C'91,47,55');
   CreatePanelBox(panelPrefix + "InfoCard", x + 12, y + 202, 306, 93, C'22,27,36', C'49,59,75');

   CreatePanelLabel(panelPrefix + "Title", "SCALP WIN PRO", x + 16, y + 9, C'238,242,247', 11, true);
    CreatePanelLabel(panelPrefix + "Version", "v2.7", x + 16, y + 27, C'92,108,128', 8);
   CreatePanelLabel(panelPrefix + "StatusVal", "INICIALIZANDO", x + 190, y + 16, clrYellow, 9, true);

   CreatePanelLabel(panelPrefix + "PLLabel", "RESULTADO DO DIA", x + 22, y + 68, C'125,140,158', 8, true);
   CreatePanelLabel(panelPrefix + "PLVal", "R$ 0.00", x + 22, y + 88, C'232,237,243', 12, true);
   CreatePanelLabel(panelPrefix + "MonthLabel", "RESULTADO DO MÊS", x + 179, y + 68, C'125,140,158', 8, true);
   CreatePanelLabel(panelPrefix + "MonthVal", "R$ 0.00", x + 179, y + 88, C'232,237,243', 12, true);

   CreatePanelLabel(panelPrefix + "MaxLabel", "LUCRO MÁX. DO DIA", x + 22, y + 140, C'102,180,154', 8, true);
   CreatePanelLabel(panelPrefix + "MaxVal", "R$ 0.00", x + 22, y + 160, C'0,230,120', 11, true);
   CreatePanelLabel(panelPrefix + "MinLabel", "PERDA MÁX. DO DIA", x + 179, y + 140, C'205,125,135', 8, true);
   CreatePanelLabel(panelPrefix + "MinVal", "R$ 0.00", x + 179, y + 160, C'255,100,105', 11, true);

   CreatePanelLabel(panelPrefix + "PosLabel", "POSIÇÃO", x + 22, y + 213, C'116,130,148', 8);
   CreatePanelLabel(panelPrefix + "PosVal", "Sem Operação", x + 126, y + 213, C'200,205,212', 9, true);
   CreatePanelLabel(panelPrefix + "FlutLabel", "FLUTUANTE", x + 22, y + 237, C'116,130,148', 8);
   CreatePanelLabel(panelPrefix + "FlutVal", "0 pts (R$ 0.00)", x + 126, y + 237, C'200,205,212', 9);
   CreatePanelLabel(panelPrefix + "StatsLabel", "TRADES", x + 22, y + 261, C'116,130,148', 8);
   CreatePanelLabel(panelPrefix + "StatsVal", "0 / 0", x + 126, y + 261, C'220,225,232', 9);
   CreatePanelLabel(panelPrefix + "AssertLabel", "ASSERTIVIDADE", x + 190, y + 261, C'116,130,148', 8);
   CreatePanelLabel(panelPrefix + "AssertVal", "0.0%", x + 276, y + 261, C'220,225,232', 9, true);

   CreatePanelBox(panelPrefix + "GraphCard", x + 12, y + 303, 306, 137, C'22,27,36', C'49,59,75');
   CreatePanelLabel(panelPrefix + "GraphTitle", "EVOLUÇÃO DO DIA", x + 22, y + 313, C'125,140,158', 8, true);
   CreatePanelLabel(panelPrefix + "GraphCount", "0 negócios", x + 235, y + 313, C'103,117,136', 8);
   CreatePanelLabel(panelPrefix + "GraphHigh", "R$ +0.00", x + 22, y + 340, C'0,230,120', 7);
   CreatePanelLabel(panelPrefix + "GraphLow", "R$ +0.00", x + 22, y + 405, C'255,100,105', 7);

   CreatePanelLabel(panelPrefix + "Params", StringFormat("TP %d  |  SL %d  |  BE +%d", InpTakeProfitPts, InpStopLossPts, InpBreakevenLockPts), x + 14, y + 450, C'103,117,136', 8);
    CreatePanelLabel(panelPrefix + "Params2", StringFormat("META +R$%.0f  |  STOP -R$%.0f  |  DEVOL %.0f%%", InpMaxDailyProfit, InpMaxDailyLoss, InpTrailingMetaPct), x + 14, y + 470, C'103,117,136', 8);
}

void DestroyDashboard() { ObjectsDeleteAll(0, panelPrefix); }

//+------------------------------------------------------------------+
//| Estatísticas por PERÍODO (por POSIÇÃO, com comissão e swap)      |
//| -> mesmo critério do relatório do Testador de Estratégia         |
//+------------------------------------------------------------------+
void GetStats(datetime from, double &outPL, int &outTrades, int &outWins, int &outLosses, int &outConsecLoss,
              double &outMaxAccum, double &outMinAccum)
{
   outPL = 0.0; outTrades = 0; outWins = 0; outLosses = 0; outConsecLoss = 0;
   outMaxAccum = 0.0; outMinAccum = 0.0;

   if(!HistorySelect(from, TimeCurrent() + 1)) return;

   // agrupa os deals de saída pela posição (evita contar saídas parciais como trades)
   ulong  posIds[];
   double posPL[];
   int    n = 0;

   int dealsTotal = HistoryDealsTotal();
   for(int i = 0; i < dealsTotal; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != (long)InpMagicNumber) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY)
         continue;

      // resultado líquido = lucro + comissão + swap (é assim que o testador soma)
      double p = HistoryDealGetDouble(ticket, DEAL_PROFIT)
               + HistoryDealGetDouble(ticket, DEAL_COMMISSION)
               + HistoryDealGetDouble(ticket, DEAL_SWAP);

      ulong posId = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);

      int idx = -1;
      for(int k = 0; k < n; k++) if(posIds[k] == posId) { idx = k; break; }
      if(idx < 0)
      {
         ArrayResize(posIds, n + 1);
         ArrayResize(posPL,  n + 1);
         posIds[n] = posId; posPL[n] = 0.0; idx = n; n++;
      }
      posPL[idx] += p;
   }

   for(int k = 0; k < n; k++)
   {
      outPL += posPL[k];
      if(outPL > outMaxAccum) outMaxAccum = outPL;
      if(outPL < outMinAccum) outMinAccum = outPL;
      outTrades++;
      if(posPL[k] > 0)      { outWins++;   outConsecLoss = 0; }
      else if(posPL[k] < 0) { outLosses++; outConsecLoss++; }
   }
}

void GetDailyStats(double &outPL, int &outTrades, int &outWins, int &outLosses, int &outConsecLoss,
                   double &outMaxAccum, double &outMinAccum)
{
   GetStats(DayStart(TimeCurrent()), outPL, outTrades, outWins, outLosses, outConsecLoss, outMaxAccum, outMinAccum);
}

double GetMonthlyPL()
{
   double pl = 0.0, maxAccum = 0.0, minAccum = 0.0; int t = 0, w = 0, l = 0, c = 0;
   GetStats(MonthStart(TimeCurrent()), pl, t, w, l, c, maxAccum, minAccum);
   return pl;
}

void GetDailyCurve(double &outCurve[])
{
   ArrayResize(outCurve, 1); outCurve[0] = 0.0;
   if(!HistorySelect(DayStart(TimeCurrent()), TimeCurrent() + 1)) return;
   ulong posIds[]; double posPL[]; int n = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0 || HistoryDealGetInteger(ticket, DEAL_MAGIC) != (long)InpMagicNumber) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY) continue;
      ulong posId = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
      double result = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP);
      int idx = -1;
      for(int k = 0; k < n; k++) if(posIds[k] == posId) { idx = k; break; }
      if(idx < 0) { ArrayResize(posIds, n + 1); ArrayResize(posPL, n + 1); posIds[n] = posId; posPL[n] = 0.0; idx = n++; }
      posPL[idx] += result;
   }
   ArrayResize(outCurve, n + 1);
   double accumulated = 0.0;
   for(int i = 0; i < n; i++) { accumulated += posPL[i]; outCurve[i + 1] = accumulated; }
}

void DrawDailyGraph(int knownTrades, double knownPL)
{
   if(!InpShowPanel || (knownTrades == g_lastGraphTrades && MathAbs(knownPL - g_lastGraphPL) < 0.001)) return;
   g_lastGraphTrades = knownTrades; g_lastGraphPL = knownPL;
   ObjectsDeleteAll(0, panelPrefix + "GraphPlot_");
   double curve[]; GetDailyCurve(curve);
   int trades = ArraySize(curve) - 1;
   double highest = 0.0, lowest = 0.0;
   for(int i = 0; i < ArraySize(curve); i++) { highest = MathMax(highest, curve[i]); lowest = MathMin(lowest, curve[i]); }
   double range = highest - lowest;
   if(range < 1.0) { highest += 0.5; lowest -= 0.5; range = 1.0; }
   double margin = range * 0.12; highest += margin; lowest -= margin; range = highest - lowest;
   int left = InpPanelX + 72, top = InpPanelY + 338, width = 232, height = 76;
   int slots = MathMax(MathMax(InpMaxDailyTrades, trades), 1);
   int zeroY = top + (int)MathRound((highest / range) * height);
   CreatePanelBox(panelPrefix + "GraphPlot_Zero", left, zeroY, width, 1, C'68,78,94', C'68,78,94');
   UpdatePanelLabel(panelPrefix + "GraphCount", StringFormat("%d negócios", trades));
   UpdatePanelLabel(panelPrefix + "GraphHigh", StringFormat("R$ %+.2f", highest - margin), C'0,230,120');
   UpdatePanelLabel(panelPrefix + "GraphLow", StringFormat("R$ %+.2f", lowest + margin), C'255,100,105');
   int prevX = left, prevY = zeroY;
   CreatePanelBox(panelPrefix + "GraphPlot_Point_0", prevX - 2, prevY - 2, 5, 5, C'0,188,212', C'0,188,212');
   for(int i = 1; i <= trades; i++)
   {
      int px = left + (int)MathRound((double)i * width / slots);
      int py = top + (int)MathRound(((highest - curve[i]) / range) * height);
      CreatePanelBox(panelPrefix + "GraphPlot_H_" + IntegerToString(i), prevX, prevY, MathMax(px - prevX, 1), 2, C'0,188,212', C'0,188,212');
      CreatePanelBox(panelPrefix + "GraphPlot_V_" + IntegerToString(i), px, MathMin(prevY, py), 2, MathMax(MathAbs(py - prevY), 1), C'0,188,212', C'0,188,212');
      color pointColor = (curve[i] >= 0.0) ? C'0,230,120' : C'255,100,105';
      CreatePanelBox(panelPrefix + "GraphPlot_Point_" + IntegerToString(i), px - 2, py - 2, 5, 5, pointColor, pointColor);
      prevX = px; prevY = py;
   }
}

//+------------------------------------------------------------------+
//| Painel: atualização                                              |
//+------------------------------------------------------------------+
void UpdateDashboard(string statusText, color statusColor)
{
   AuditState(statusText);
   if(!InpShowPanel) return;

   double dailyPL = 0.0, maxDailyAccum = 0.0, minDailyAccum = 0.0;
   int totalTrades = 0, wins = 0, losses = 0, consecLoss = 0;
   GetDailyStats(dailyPL, totalTrades, wins, losses, consecLoss, maxDailyAccum, minDailyAccum);
   double monthlyPL = GetMonthlyPL();

   string posDesc = "Sem Operação", flutDesc = "0 pts (R$ 0.00)";
   color  flutColor = C'150,160,175';

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
      double profit    = PositionGetDouble(POSITION_PROFIT);
      double diffPts   = (type == POSITION_TYPE_BUY) ? (currPrice - openPrice) / g_point
                                                     : (openPrice - currPrice) / g_point;
      posDesc  = (type == POSITION_TYPE_BUY) ? "COMPRADO" : "VENDIDO";
      flutDesc = StringFormat("%+.0f pts (R$ %+.2f)", diffPts, profit);
      flutColor= (profit >= 0) ? C'0,230,120' : C'255,80,80';
      break;
   }

   double winRate = (totalTrades > 0) ? ((double)wins / totalTrades) * 100.0 : 0.0;
   color plColor    = (dailyPL > 0) ? C'0,230,120' : (dailyPL < 0) ? C'255,80,80' : clrWhite;
   color monthColor = (monthlyPL > 0) ? C'0,230,120' : (monthlyPL < 0) ? C'255,80,80' : clrWhite;

   UpdatePanelLabel(panelPrefix + "StatusVal", statusText, statusColor);
   UpdatePanelLabel(panelPrefix + "PLVal", StringFormat("R$ %+.2f", dailyPL), plColor);
   UpdatePanelLabel(panelPrefix + "MonthVal", StringFormat("R$ %+.2f", monthlyPL), monthColor);
   UpdatePanelLabel(panelPrefix + "MaxVal", StringFormat("R$ %+.2f", maxDailyAccum), C'0,230,120');
   UpdatePanelLabel(panelPrefix + "MinVal", StringFormat("R$ %+.2f", minDailyAccum), C'255,100,105');
   UpdatePanelLabel(panelPrefix + "PosVal", posDesc, (posDesc != "Sem Operação") ? clrCyan : C'180,180,180');
   UpdatePanelLabel(panelPrefix + "FlutVal", flutDesc, flutColor);
   UpdatePanelLabel(panelPrefix + "StatsVal", StringFormat("%d / %d", totalTrades, InpMaxDailyTrades));
   UpdatePanelLabel(panelPrefix + "AssertVal", StringFormat("%.1f%%", winRate),
                    (winRate >= 50.0) ? C'0,230,120' : C'255,140,0');
   DrawDailyGraph(totalTrades, dailyPL);
}

//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;
      MqlTick before={}; SymbolInfoTick(_Symbol,before); ulong started=GetMicrosecondCount();
      bool ok=trade.PositionClose(ticket);
      AuditTradeResult("CLOSE",ok,before,started,"");
   }
}

bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void CheckBreakeven()
{
   if(!InpUseBreakeven) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL  = PositionGetDouble(POSITION_SL);
      double tp         = PositionGetDouble(POSITION_TP);
      double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double minDist    = g_stopLevel * g_point;

      if(type == POSITION_TYPE_BUY)
      {
         if((bid - openPrice) >= InpBreakevenTriggerPts * g_point)
         {
            double newSL = NormPrice(openPrice + InpBreakevenLockPts * g_point);
            if(newSL > currentSL + g_point * 0.5 && (bid - newSL) > minDist)
            {
               MqlTick before={}; SymbolInfoTick(_Symbol,before); ulong started=GetMicrosecondCount();
               bool ok=trade.PositionModify(ticket,newSL,tp);
               AuditTradeResult("BREAKEVEN",ok,before,started,"");
            }
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         if((openPrice - ask) >= InpBreakevenTriggerPts * g_point)
         {
            double newSL = NormPrice(openPrice - InpBreakevenLockPts * g_point);
            if((currentSL == 0 || newSL < currentSL - g_point * 0.5) && (newSL - ask) > minDist)
            {
               MqlTick before={}; SymbolInfoTick(_Symbol,before); ulong started=GetMicrosecondCount();
               bool ok=trade.PositionModify(ticket,newSL,tp);
               AuditTradeResult("BREAKEVEN",ok,before,started,"");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetAsyncMode(false);
   SetupFillingMode();

   g_point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_stopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   if(InpStopLossPts <= g_stopLevel || InpTakeProfitPts <= g_stopLevel)
      PrintFormat("Atenção: SL/TP menores que o stop level mínimo da corretora (%d pts).", g_stopLevel);

   handleEMA = iMA(_Symbol, InpTimeframe, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(handleEMA == INVALID_HANDLE) { Print("Erro ao criar EMA."); return INIT_FAILED; }
    if(InpM5EmaPeriod<1 || InpADXPeriod<1 || InpMaxCandleSize<1 || InpMinCandleBodyPct<0 ||
       InpMinCandleBodyPct>100 || InpMaxEmaDistancePts<=0 || InpMinADX<0) return INIT_PARAMETERS_INCORRECT;
    if(InpUseM5TrendFilter)
    {
       handleM5EMA=iMA(_Symbol,PERIOD_M5,InpM5EmaPeriod,0,MODE_EMA,PRICE_CLOSE);
       if(handleM5EMA==INVALID_HANDLE) return INIT_FAILED;
    }
    if(InpUseADXFilter)
    {
       handleADX=iADX(_Symbol,InpTimeframe,InpADXPeriod);
       if(handleADX==INVALID_HANDLE) return INIT_FAILED;
    }

   currentDay = DayStart(TimeCurrent());
   AuditInit();
   InitDashboard();
   ChartRedraw();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(InpEnableAudit && auditHandle!=INVALID_HANDLE)
   { AuditDrain(); AuditLog("SESSION_END","reason="+(string)reason); AuditFlush(); FileClose(auditHandle); auditHandle=INVALID_HANDLE; }
   EventKillTimer();
   IndicatorRelease(handleEMA);
    if(handleM5EMA!=INVALID_HANDLE) IndicatorRelease(handleM5EMA);
    if(handleADX!=INVALID_HANDLE) IndicatorRelease(handleADX);
   DestroyDashboard();
   ChartRedraw();
}

//+------------------------------------------------------------------+
void OnTick()
{
   // --- Reset na virada do dia (essencial em backtests de vários dias)
   datetime today = DayStart(TimeCurrent());
   if(today != currentDay)
   {
       currentDay      = today;
       dailyBlocked    = false;
       targetHit       = false;
       pauseUntilTime  = 0;
      pauseBaseLosses = 0;
      lastBarTime     = 0;
      g_lastGraphTrades = -1;
      g_lastGraphPL = DBL_MAX;
   }

   CheckBreakeven();

   MqlDateTime dt; TimeCurrent(dt);
   int nowMin   = dt.hour * 60 + dt.min;
   int startMin = MinutesOfString(InpStartTime);
   int endMin   = MinutesOfString(InpEndTime);
   int closeMin = MinutesOfString(InpCloseTime);

   if(nowMin >= closeMin)
   {
      if(HasOpenPosition()) CloseAllPositions();
      UpdateDashboard("Encerrado (" + InpCloseTime + ")", C'255,140,0');
      return;
   }

   double dailyPL = 0.0, maxDailyAccum = 0.0, minDailyAccum = 0.0;
   int totalTrades = 0, wins = 0, losses = 0, consecLoss = 0;
   GetDailyStats(dailyPL, totalTrades, wins, losses, consecLoss, maxDailyAccum, minDailyAccum);

    // --- Meta fixa ativa o trailing: antes da meta vale só o stop diário;
    //     depois de bater a meta, o piso de 30% acompanha o maior saldo do dia
    if(dailyPL >= InpMaxDailyProfit) targetHit = true;
    double metaFloor = (targetHit && maxDailyAccum > 0.0)
                       ? maxDailyAccum * (1.0 - InpTrailingMetaPct / 100.0)
                       : 0.0;

    if(dailyBlocked || dailyPL <= -InpMaxDailyLoss || (targetHit && dailyPL <= metaFloor))
    {
       if(!dailyBlocked) { CloseAllPositions(); dailyBlocked = true; }
       bool stopLoss = (dailyPL <= -InpMaxDailyLoss);
       UpdateDashboard(stopLoss ? "Stop Diário Atingido" : StringFormat("Lucro Protegido (+R$%.2f)", dailyPL),
                       stopLoss ? C'255,80,80' : C'0,230,120');
       return;
    }

   if(totalTrades >= InpMaxDailyTrades)
   {
      UpdateDashboard("Limite Trades Atingido", C'255,140,0');
      return;
   }

   // --- Pausa protetora: só reinicia quando HOUVER novas perdas consecutivas
   if(consecLoss >= InpMaxConsecutiveLoss && losses > pauseBaseLosses)
   {
      if(pauseUntilTime == 0)
         pauseUntilTime = TimeCurrent() + InpPauseMinutesAfterLoss * 60;

      if(TimeCurrent() < pauseUntilTime)
      {
         int rem = (int)(pauseUntilTime - TimeCurrent());
         UpdateDashboard(StringFormat("Pausa Risco (%dm%02ds)", rem / 60, rem % 60), C'255,140,0');
         return;
      }
      pauseUntilTime  = 0;
      pauseBaseLosses = losses;   // pausa cumprida: só pausa de novo após novas perdas
   }

   if(nowMin < startMin || nowMin >= endMin)
   {
      UpdateDashboard("Fora de Horário", C'150,150,150');
      return;
   }

   if(HasOpenPosition())
   {
      UpdateDashboard("Em Operação", clrAqua);
      return;
   }

   UpdateDashboard(targetHit ? "Meta Batida - Trailing Ativo" : "Aguardando Sinal",
                   targetHit ? C'0,230,120' : C'0,200,255');

   // --- Avalia UMA vez por barra (marca a barra sempre, não só quando entra)
   datetime currentBarTime = iTime(_Symbol, InpTimeframe, 0);
   if(currentBarTime == 0 || currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   MqlRates rates[]; ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, InpTimeframe, 0, 4, rates) < 4) { AuditLog("DATA_WAIT","CopyRates",AuditKey()); return; }

   double emaValues[]; ArraySetAsSeries(emaValues, true);
   if(CopyBuffer(handleEMA, 0, 0, 4, emaValues) < 4) { AuditLog("DATA_WAIT","CopyBuffer",AuditKey()); return; }

   double open1 = rates[1].open, close1 = rates[1].close;
   double high1 = rates[1].high, low1   = rates[1].low;
   double ema1  = emaValues[1],  ema2   = emaValues[2];

   double emaDiffPts = (ema1 - ema2) / g_point;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double rangePts=(high1-low1)/g_point;
    double bodyPct=(high1>low1)?100.0*MathAbs(close1-open1)/(high1-low1):0.0;
    bool buyBase=(close1>open1 && close1>ema1 && open1>=ema1 && emaDiffPts>=InpMinEmaSlopePts);
    bool sellBase=(close1<open1 && close1<ema1 && open1<=ema1 && -emaDiffPts>=InpMinEmaSlopePts);
    string signal="NONE";
    if(rangePts<InpMinCandleSize) signal="SMALL_CANDLE";
    else if(buyBase || sellBase)
    {
       signal=buyBase?"BUY":"SELL";
       if(InpUseCandleMaxFilter && rangePts>InpMaxCandleSize) signal="REJECT_MAX_CANDLE";
       else if(InpUseCandleBodyFilter && bodyPct<InpMinCandleBodyPct) signal="REJECT_WEAK_BODY";
       else if(InpUseEmaDistanceFilter && MathAbs(close1-ema1)/g_point>InpMaxEmaDistancePts) signal="REJECT_EMA_DISTANCE";
       else if(InpUseM5TrendFilter)
       {
          double m5ema[]; ArraySetAsSeries(m5ema,true);
          MqlRates m5rates[]; ArraySetAsSeries(m5rates,true);
          if(CopyBuffer(handleM5EMA,0,1,2,m5ema)<2 || CopyRates(_Symbol,PERIOD_M5,1,2,m5rates)<2)
             signal="DATA_WAIT_M5";
          else if((buyBase && !(m5rates[0].close>m5ema[0] && m5ema[0]>m5ema[1])) ||
                  (sellBase && !(m5rates[0].close<m5ema[0] && m5ema[0]<m5ema[1])))
             signal="REJECT_M5_TREND";
       }
       if((signal=="BUY" || signal=="SELL") && InpUseADXFilter)
       {
          double adx[]; ArraySetAsSeries(adx,true);
          if(CopyBuffer(handleADX,0,1,1,adx)<1) signal="DATA_WAIT_ADX";
          else if(adx[0]<InpMinADX) signal="REJECT_ADX";
       }
    }
    AuditLog("SIGNAL",signal+" body_pct="+DoubleToString(bodyPct,1)+" range_pts="+DoubleToString(rangePts,1),
             AuditKey(),rates[1].time,open1,high1,low1,close1,ema1,emaDiffPts,bid,ask);
    if(signal!="BUY" && signal!="SELL") return;

    // COMPRA
   if(signal=="BUY")
   {
      double sl = NormPrice(ask - InpStopLossPts   * g_point);
      double tp = NormPrice(ask + InpTakeProfitPts * g_point);
      MqlTick before={}; SymbolInfoTick(_Symbol,before); ulong started=GetMicrosecondCount();
      bool ok=trade.Buy(InpLots, _Symbol, 0.0, sl, tp, "Scalp WIN Pro - Buy");
      AuditTradeResult("ENTRY",ok,before,started,AuditKey());
      if(ok)
         UpdateDashboard("Comprando...", clrLime);
      else
         PrintFormat("Falha na compra: ret=%d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
   // VENDA
   else if(signal=="SELL")
   {
      double sl = NormPrice(bid + InpStopLossPts   * g_point);
      double tp = NormPrice(bid - InpTakeProfitPts * g_point);
      MqlTick before={}; SymbolInfoTick(_Symbol,before); ulong started=GetMicrosecondCount();
      bool ok=trade.Sell(InpLots, _Symbol, 0.0, sl, tp, "Scalp WIN Pro - Sell");
      AuditTradeResult("ENTRY",ok,before,started,AuditKey());
      if(ok)
         UpdateDashboard("Vendendo...", clrRed);
      else
         PrintFormat("Falha na venda: ret=%d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}
//+------------------------------------------------------------------+