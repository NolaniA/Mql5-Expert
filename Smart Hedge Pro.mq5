//+------------------------------------------------------------------+
//|                                                SmartHedgePro.mq5 |
//|                                                Beer NPTraderr    |
//|                               https://www.facebook.com/nptraderr |
//+------------------------------------------------------------------+
#property copyright "Beer NPTraderr"
#property link "https://www.facebook.com/nptraderr"
#property version "1.14"

// v1.14 Changelog:
// - แก้ Compile Error: invalid date จาก D'9999.12.31 23:59:59'
// - ใช้ DATETIME_MAX ซึ่งเป็นค่าสูงสุดที่ MQL5 รองรับ (3000.12.31 23:59:59)

// v1.13 Changelog:
// - แก้ Warning: POSITION_COMMISSION is deprecated
// - Floating P/L ของ Position ใช้ POSITION_PROFIT + POSITION_SWAP
// - กำไรย้อนหลังจาก History ยังคงรวม DEAL_COMMISSION ตามเดิม

// v1.12 Changelog:
// - ปรับ Cut Loss ให้ใช้ CutLoss_Pct เพียงค่าเดียว
// - CutLoss_Pct = 0.0 หมายถึงปิดการทำงาน Cut Loss
// - CutLoss_Pct > 0 จะคำนวณวงเงินขาดทุนจาก Balance x CutLoss_Pct / 100
// - เมื่อ Floating P/L รวมของ Symbol + Magic นี้ <= -วงเงิน Cut Loss จะปิด Position ทั้งหมด
// - แยก Logic เป็นฟังก์ชัน CheckCutLoss() เพื่อให้อ่านและแก้ไขง่ายขึ้น

// v1.11 Changelog:
// - เพิ่มเงื่อนไข "เปิดออเดอร์ถัดไปเมื่อจบแท่งเทียนเท่านั้น" (Open Next Order
//   On New Candle Close Only) แยก true/false ได้อิสระระหว่างฝั่ง Main Lot
//   (Follow Trend) กับฝั่ง Hedge Lot (Against Trend) ผ่าน Input ใหม่
//   Main_NewCandleOnly และ Hedge_NewCandleOnly เพื่อความยืดหยุ่นในการแก้ไข
//   จังหวะเปิดออเดอร์แต่ละฝั่งแยกจากกัน เช่น Main = false (เปิดได้ทุก Tick
//   ตามเงื่อนไขระยะห่างเดิม), Hedge = true (ต้องรอแท่งเทียนใหม่ปิดก่อนถึง
//   จะเปิดออเดอร์ฝั่ง Hedge รอบถัดไปได้)
// - เมื่อเปิดใช้งาน ฝั่งนั้นๆ จะเปิดออเดอร์ได้เพียง 1 ครั้งต่อแท่งเทียน
//   (เทียบจากเวลาเปิดแท่ง/iTime ของ Timeframe ปัจจุบัน) หากยังอยู่ในแท่ง
//   เดียวกับที่เพิ่งเปิดออเดอร์ไปแล้ว จะข้ามการเปิดออเดอร์ฝั่งนั้นในรอบนี้
//   ไปก่อน (อีกฝั่งที่ไม่ได้เปิดใช้เงื่อนไขนี้ยังคงเปิดได้ตามปกติ)
// - รีเซ็ตสถานะการจำแท่งเทียนล่าสุดของทั้งสองฝั่งเมื่อไม่มีออเดอร์ค้าง
//   (เริ่มรอบ Grid ใหม่) เพื่อไม่ให้เงื่อนไขค้างข้ามรอบ

// v1.10 Changelog:
// - เพิ่ม "Break Time Trading" (News Filter): กำหนดช่วงเวลาพักเทรดได้หลาย
//   ช่วงพร้อมกัน โดยใส่เวลาเริ่มพักคั่นด้วย , ในรูปแบบ HH:MM เช่น
//   "15:00,18:00,19:00" และกำหนดระยะเวลาพัก (นาที) ผ่าน BreakTime_Delay
//   เช่น Delay = 30 -> พักเทรดช่วง 15:00-15:30, 18:00-18:30, 19:00-19:30
//   แล้วกลับมาเทรดต่อทันทีเมื่อพ้นช่วงพัก โดย "หยุดเปิดออเดอร์ใหม่" เท่านั้น
//   (ทั้งรอบแรกและรอบ Grid ถัดไป) ไม่ปิดออเดอร์เดิมที่ค้างอยู่แต่อย่างใด
// - เพิ่ม Input BreakTime_Reference ให้เลือกอ้างอิงเวลาได้ว่าจะใช้ Local
//   Time (เวลาเครื่องที่รัน EA) หรือ Server Time (เวลาของ Broker)
// - เพิ่มสถานะใหม่ STATUS_BREAK_TIME แสดงผลบน Panel เป็น "BREAK-TIME"
//   (สีส้ม) แยกจากสถานะ TRADING/OUT-TIME เดิม เพื่อให้เห็นชัดว่ากำลังพัก
//   เทรดเพราะช่วงข่าวอยู่

// v1.09 Changelog:
// - เพิ่ม "Bollinger Band Breakout Protection": เดิมเมื่อราคาหลุดกรอบ Band
//   (ask > Upper หรือ bid < Lower) EA จะหยุดเปิดออเดอร์ทั้งหมด (return ทันที)
//   ตอนนี้เปลี่ยนเป็นยัง Follow Trend เหมือนเดิม แต่ฝั่ง Follow Trend (Main)
//   จะ "หยุดคูณ Lot ทบต้น" ใช้ Lot ฐาน (Lot_Main) แทนเมื่อราคาหลุดกรอบไปใน
//   ทิศทางเดียวกับเทรน (บนกรอบ Upper สำหรับเทรน Buy, ใต้กรอบ Lower สำหรับ
//   เทรน Sell) เพื่อป้องกันความเสี่ยงตอนราคาย่อกลับ ส่วนฝั่ง Against Trend
//   (Hedge) ยังคำนวณ Lot ทบต้นตามปกติทุกกรณี ไม่ได้รับผลกระทบ
//   ตัวอย่าง: เทรน Sell (bid < Middle) แล้วราคาหลุดต่ำกว่า Lower Band
//   -> Sell (Main) ใช้ Lot ฐานคงที่ทุก Step, Buy (Hedge) ยังคูณทบต้นตามปกติ
//   ตัวอย่าง: เทรน Buy (bid > Middle) แล้วราคาทะลุสูงกว่า Upper Band
//   -> Buy (Main) ใช้ Lot ฐานคงที่ทุก Step, Sell (Hedge) ยังคูณทบต้นตามปกติ

// v1.08 Changelog:
// - เพิ่มพื้นหลังทึบ (OBJ_RECTANGLE_LABEL) ด้านหลัง Panel แก้ปัญหาแท่งเทียน
//   และเส้น Bollinger Band บังตัวหนังสือจนอ่านไม่ออก
// - ความกว้างกล่องคำนวณอัตโนมัติจากข้อความที่ยาวที่สุดด้วย TextGetSize()
//   จึงพอดีกับเนื้อหาเสมอแม้ตัวเลขจะยาวขึ้น/สั้นลง
// - เพิ่ม Input: Panel_BG_Enable, Panel_BG_Color, Panel_Border_Color, Panel_Padding

// v1.07 Changelog:
// - เพิ่ม "Profit Glow Summary" บน Dashboard: คำนวณผลตอบแทนรวมจริง
//   = กำไรจากการเทรด (Closed Profit) + รีเบทที่ได้รับ (Lot x Rebate_Per_Lot)
//   แสดงแยกเป็น Day / Week / Month / Total และมีบรรทัด "Glow + Floating"
//   ที่รวมกำไร-ขาดทุนลอยตัวของออเดอร์ที่ยังไม่ปิดเข้าไปด้วย
//   ตัวอย่าง: กำไรปิดแล้ว $1000 + เทรดสะสม 10 Lot x รีเบท $40 = $400
//             -> Glow Total = $1400
// - GetHistoricalStats() เพิ่มพารามิเตอร์ profitDay / profitWeek / profitMonth
//   เพื่อแยกกำไรตามช่วงเวลา (เดิมมีเฉพาะ profitAll)
// - UpdatePanel() ขยายจาก 16 เป็น 20 บรรทัด และเพิ่มการไล่สีตัวอักษร
//   (เขียว/แดง สำหรับกำไรลอยตัว, ทอง/ฟ้า สำหรับบล็อก Profit Glow Summary)

// v1.06 Changelog:
// - แยกโหมดการคำนวณ Lot ระหว่าง Follow Trend (Main) กับ Against Trend (Hedge)
//   ออกจากกันอย่างอิสระ เดิมทั้งสองฝั่งใช้สูตรเดียวกันคือ Multiply (Lot x
//   Multiplier^step) ตอนนี้เพิ่ม Enum ENUM_LOT_MODE ให้เลือกได้ต่อฝั่งว่าจะใช้
//   "Multiply" (คูณทบต้นแบบเดิม) หรือ "Plus" (บวกเพิ่มทีละขั้นคงที่: Lot +
//   PlusStep x step) จึงเลือกผสมกันได้ เช่น Main=Multiply, Hedge=Plus
//   คำนวณผ่านฟังก์ชันใหม่ CalcLotBySteps() แทนการคำนวณตรงๆ ใน OpenHedgePair()

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Enums
enum ENUM_TRADE_STATUS {
   STATUS_TRADING,
   STATUS_OUT_TIME,
   STATUS_BREAK_TIME,
   STATUS_OFF
};

// v1.06: โหมดการคำนวณ Lot แบบขั้นบันได (Step) ต่อรอบ Grid
enum ENUM_LOT_MODE {
   LOT_MODE_MULTIPLY, // Multiply: Lot x Multiplier^step (คูณทบต้น)
   LOT_MODE_PLUS      // Plus: Lot + (PlusStep x step) (บวกเพิ่มคงที่)
};

// v1.10: อ้างอิงเวลาที่ใช้ตรวจสอบ Break Time Trading
enum ENUM_TIME_REF {
   TIME_REF_LOCAL,  // Local Time (เวลาเครื่องที่รัน EA)
   TIME_REF_SERVER  // Server Time (เวลาของ Broker)
};

//+------------------------------------------------------------------+
//| EA EXPIRATION (BACKEND ONLY)                                     |
//| กำหนดวันหมดอายุ EA ไว้ในโค้ดโดยตรง ไม่เปิดเป็น Input ให้ลูกค้า    |
//| เห็นหรือแก้ไขได้จากหน้าต่าง Property ของ EA ถ้าต้องการเปลี่ยน    |
//| วันหมดอายุ ต้องแก้ค่านี้ในซอร์สโค้ดแล้ว Compile ใหม่เท่านั้น       |
//+------------------------------------------------------------------+
const datetime Expiration_Date = D'9999.12.31 23:59:59'; // Max MQL5 datetime = 3000.12.31 23:59:59

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
input group "=== Magic Number ==="
input int      Magic_Start       = 9999;     // Magic Number

input group "=== Trade Days ==="
input bool     Trade_Mon         = true;     // Trade Monday
input bool     Trade_Tue         = true;     // Trade Tuesday
input bool     Trade_Wed         = true;     // Trade Wednesday
input bool     Trade_Thu         = true;     // Trade Thursday
input bool     Trade_Fri         = true;     // Trade Friday
input bool     Trade_Sat         = false;    // Trade Saturday
input bool     Trade_Sun         = false;    // Trade Sunday

input group "=== Trade Time (Local Time) ==="
input string   Mon_Start         = "00:00";  // Mon Start Time
input string   Mon_End           = "23:59";  // Mon End Time
input string   Tue_Start         = "00:00";
input string   Tue_End           = "23:59";
input string   Wed_Start         = "00:00";
input string   Wed_End           = "23:59";
input string   Thu_Start         = "00:00";
input string   Thu_End           = "23:59";
input string   Fri_Start         = "00:00";
input string   Fri_End           = "23:59";
input string   Sat_Start         = "00:00";
input string   Sat_End           = "23:59";
input string   Sun_Start         = "00:00";
input string   Sun_End           = "23:59";

input group "=== Break Time Trading (News Filter) ==="
input bool     Use_BreakTime     = false;    // Enable Break Time Trading
input string   BreakTime_List    = "15:00,18:00,19:00"; // Break Start Times (HH:MM, คั่นด้วย , )
input int      BreakTime_Delay   = 30;       // Break Duration (Minutes)
input ENUM_TIME_REF BreakTime_Reference = TIME_REF_LOCAL; // Break Time Reference (Local/Server)

input group "=== Trading Parameters ==="
input double   Lot_Main          = 0.03;     // Main Lot (Follow Trend)
input double   Lot_Hedge         = 0.01;     // Hedge Lot (Against Trend)
input double   Max_Lot           = 5.0;      // Max Lot per Order
input int      Distance_Pip      = 100;      // Distance (Points/Pips)
input double   Profit_Trigger    = 30.0;     // Trailing Start Trigger (USD)
input double   Profit_Trail      = 10.0;     // Trailing Pullback (USD)

// v1.06: แยกโหมด/พารามิเตอร์การเพิ่ม Lot ต่อรอบ (Step) ของฝั่ง Follow Trend (Main)
// และฝั่ง Against Trend (Hedge) ออกจากกันอย่างอิสระ เลือกผสมกันได้ เช่น
// Main = Multiply (คูณทบต้น), Hedge = Plus (บวกเพิ่มคงที่) หรือสลับกันก็ได้
input group "=== Lot Sizing: Follow Trend (Main) ==="
input ENUM_LOT_MODE Lot_Main_Mode       = LOT_MODE_MULTIPLY; // Main Lot Mode (Multiply/Plus)
input double         Lot_Main_Multiplier = 1.1;              // Main Lot Multiplier (ใช้เมื่อ Mode = Multiply)
input double         Lot_Main_PlusStep   = 0.03;              // Main Lot Plus Step (ใช้เมื่อ Mode = Plus)

input group "=== Lot Sizing: Against Trend (Hedge) ==="
input ENUM_LOT_MODE Lot_Hedge_Mode       = LOT_MODE_MULTIPLY; // Hedge Lot Mode (Multiply/Plus)
input double         Lot_Hedge_Multiplier = 1.1;              // Hedge Lot Multiplier (ใช้เมื่อ Mode = Multiply)
input double         Lot_Hedge_PlusStep   = 0.01;              // Hedge Lot Plus Step (ใช้เมื่อ Mode = Plus)

input group "=== Open Next Order On New Candle Close Only ==="
input bool     Main_NewCandleOnly   = false; // Main Lot: Open Next Order Only On New Candle
input bool     Hedge_NewCandleOnly  = false; // Hedge Lot: Open Next Order Only On New Candle

input group "=== Bollinger Band Trend Filter ==="
input int      BB_Period         = 20;       // Bollinger Band Period
input double   BB_Deviation      = 2.0;      // Bollinger Band Deviation
input int      BB_Shift          = 0;        // Bollinger Band Shift
input ENUM_APPLIED_PRICE BB_AppliedPrice = PRICE_CLOSE; // Bollinger Band Applied Price

input group "=== Square Hedge Close ==="
input bool     Use_SquareHedge   = false;     // Enable Square Hedge Before Close

input group "=== Hedge Of Trend Change ==="
input bool     Use_HedgeTrendChange = false;  // Enable Hedge On Trend Change

input group "=== Against Trend Step Profit Lock ==="
input bool     Enable_StepLock   = false;     // Enable Step Profit Lock (Against Trend)
input double   Step_Lock_Trigger = 50.0;     // Profit Lock Trigger ($)
input double   Step_Lock_Percent = 50.0;     // Profit Lock Percent (%)

input group "=== Volume Filter ==="
input bool     Use_Volume_Filter = false;     // Use Tick Volume Filter

input group "=== Cut Loss ==="
input double   CutLoss_Pct       = 0.0;      // Cut Loss % of Balance (0 = Disabled)

input group "=== Rebate ==="
input double   Rebate_Per_Lot    = 40.0;     // Rebate ($) ต่อ 1.0 Lot ที่เทรด

input group "=== UI Panel ==="
input bool     Show_Panel        = true;     // Show Panel
input int      Panel_X           = 10;       // Panel X position
input int      Panel_Y           = 30;       // Panel Y position
input int      Font_Size         = 14;       // Panel Font Size
// v1.08: พื้นหลังทึบของ Panel กันกราฟบังตัวหนังสือ
input bool     Panel_BG_Enable    = true;         // Show Panel Background
input color    Panel_BG_Color     = C'10,10,15';  // Panel Background Color
input color    Panel_Border_Color = clrDimGray;   // Panel Border Color
input int      Panel_Padding      = 10;           // Panel Padding (px)

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  pos;
int            bbHandle;
double         bbMiddle[];
double         bbUpper[];
double         bbLower[];
double         peakProfit        = 0.0;
double         peakAgainstBuyProfit  = 0.0;
double         peakAgainstSellProfit = 0.0;
int            gridRound         = 1;
bool           isExpired         = false;
int            lastTrendSide     = 0;   // 0 = undefined, 1 = above middle (buy side), -1 = below middle (sell side)
int            hedgeTrendChangeCount = 0; // จำนวนครั้งที่เกิด Hedge Of Trend Change

// v1.11: เก็บเวลาเปิดแท่งเทียนล่าสุดที่แต่ละฝั่ง (Main/Hedge) เปิดออเดอร์ไปแล้ว
// ใช้เช็คเงื่อนไข "เปิดออเดอร์ถัดไปเมื่อจบแท่งเทียนเท่านั้น" แยกอิสระต่อฝั่ง
datetime       lastMainOpenBarTime  = 0;
datetime       lastHedgeOpenBarTime = 0;

// v1.07: จำนวนบรรทัดของ Panel (เดิม 16 -> เพิ่มเป็น 20 สำหรับ Profit Glow Summary)
#define PANEL_LINES 20

//+------------------------------------------------------------------+
//| INITIALIZATION                                                   |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(Magic_Start);
   
   // Initialize Bollinger Bands
   bbHandle = iBands(_Symbol, _Period, BB_Period, BB_Shift, BB_Deviation, BB_AppliedPrice);
   if(bbHandle == INVALID_HANDLE) {
      Print("Error creating Bollinger Bands indicator");
      return INIT_FAILED;
   }
   ArraySetAsSeries(bbMiddle, true);
   ArraySetAsSeries(bbUpper, true);
   ArraySetAsSeries(bbLower, true);
   
   // Check Expiration (อ้างอิงค่าคงที่ที่ฝังไว้ในโค้ด ไม่ใช่ Input)
   if(TimeCurrent() > Expiration_Date) {
      Alert("SmartHedge Pro: EA Has Expired!");
      isExpired = true;
   }

   // Chart Properties Customization
   ChartSetInteger(0, CHART_SHOW_GRID, false);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| DEINITIALIZATION                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   IndicatorRelease(bbHandle);
   ObjectsDeleteAll(0, "SHP_");
}

//+------------------------------------------------------------------+
//| MAIN TICK FUNCTION                                               |
//+------------------------------------------------------------------+
void OnTick() {
   if(isExpired) return;
   
   if(TimeCurrent() > Expiration_Date) {
      Alert("SmartHedge Pro: EA Has Expired!");
      isExpired = true;
      return;
   }

   double totalProfit = GetTotalProfit();
   int totalPositions = GetTotalPositions();
   
   // 1. Check Trailing Close
   if(totalPositions > 0 && totalProfit >= Profit_Trigger) {
      if(totalProfit > peakProfit) {
         peakProfit = totalProfit;
      }
      
      if((peakProfit - totalProfit) >= Profit_Trail) {
         bool closedNow = false;
         if(Use_SquareHedge) {
            // ปรับ Lot Buy/Sell ให้เท่ากันก่อน แล้วค่อยปิดทั้งหมดแบบ Async
            closedNow = SquareHedgeAndCloseAll(Profit_Trigger);
         } else {
            // ปิดออเดอร์ทั้งหมดแบบ Async ทันที โดยไม่ทำ Square Hedge
            closedNow = AsyncCloseAll(_Symbol, (ENUM_POSITION_TYPE)-1, (long)Magic_Start);
         }
         if(closedNow) {
            peakProfit = 0.0;
            gridRound++;
         }
         return; 
      }
   } else if (totalPositions == 0) {
      peakProfit = 0.0;
      peakAgainstBuyProfit = 0.0;
      peakAgainstSellProfit = 0.0;
      // v1.11: รีเซ็ตสถานะแท่งเทียนล่าสุดของทั้งสองฝั่ง เริ่มรอบ Grid ใหม่
      lastMainOpenBarTime = 0;
      lastHedgeOpenBarTime = 0;
   }

   // 2. Check Cut Loss
   // CutLoss_Pct = 0 หมายถึงปิดการทำงาน
   // CutLoss_Pct > 0 คิดวงเงินขาดทุนจาก % ของ Balance
   if(CheckCutLoss(totalProfit, totalPositions)) {
      return;
   }

   // 3. Check Hedge Of Trend Change (ราคาตัดเส้น Middle Band แบบฉับพลันสวนเทรนเดิม)
   CheckHedgeOfTrendChange(totalPositions);

   // 4. Check Against Trend Step Lock
   CheckAgainstTrendStepLock(totalPositions);

   // 5. Trade Logic & Time Check
   bool isTime = IsTradingTime();
   bool isBreak = Use_BreakTime && IsBreakTime();
   ENUM_TRADE_STATUS currentStatus;
   if(isBreak) {
      currentStatus = STATUS_BREAK_TIME;
   } else {
      currentStatus = isTime ? STATUS_TRADING : STATUS_OUT_TIME;
   }
   
   if(isTime || totalPositions > 0) {
      ManageGrid(totalPositions);
   }
   
   // 6. Update Panel
   if(Show_Panel) {
      UpdatePanel(currentStatus, totalProfit);
   }
}

//+------------------------------------------------------------------+
//| GRID MANAGEMENT                                                  |
//+------------------------------------------------------------------+
void ManageGrid(int totalPos) {
   // v1.10: Break Time Trading - หยุดเปิดออเดอร์ใหม่ทั้งหมด (ทั้งรอบแรกและ
   // รอบ Grid ถัดไป) ในช่วงเวลาพักที่กำหนดไว้ โดยไม่ปิดออเดอร์เดิมที่ค้างอยู่
   if(Use_BreakTime && IsBreakTime()) return;
   
   if(totalPos == 0) {
      if(IsTradingTime()) {
         OpenHedgePair(0); // Open initial cycle
      }
   } else {
      double minDistance = GetDistanceToClosestOrder();
      if(minDistance >= (Distance_Pip * _Point)) {
         int step = totalPos / 2; // Since we open in pairs
         OpenHedgePair(step);
      }
   }
}

//+------------------------------------------------------------------+
//| v1.06: คำนวณ Lot ตามขั้น (Step) ของรอบ Grid ตามโหมดที่เลือก        |
//| Multiply: Lot x Multiplier^step (คูณทบต้นแบบเดิม)                  |
//| Plus:     Lot + (PlusStep x step) (บวกเพิ่มทีละขั้นคงที่)           |
//| ใช้ฟังก์ชันเดียวกันสำหรับทั้งฝั่ง Main และ Hedge โดยส่งค่า Mode/    |
//| Multiplier/PlusStep ของแต่ละฝั่งเข้ามาแยกกัน ทำให้เลือกผสมโหมดกัน   |
//| ได้อิสระ เช่น Main=Multiply, Hedge=Plus                            |
//+------------------------------------------------------------------+
double CalcLotBySteps(double baseLot, int step, ENUM_LOT_MODE mode, double multiplier, double plusStep) {
   double lot;
   if(mode == LOT_MODE_MULTIPLY) {
      lot = baseLot * MathPow(multiplier, step);
   } else { // LOT_MODE_PLUS
      lot = baseLot + (plusStep * step);
   }
   return lot;
}

//+------------------------------------------------------------------+
//| OPEN HEDGE PAIR (BUY + SELL)                                     |
//+------------------------------------------------------------------+
void OpenHedgePair(int step) {
   // Get Bollinger Band values (0 = Base/Middle, 1 = Upper, 2 = Lower)
   if(CopyBuffer(bbHandle, 0, 0, 1, bbMiddle) <= 0) return;
   if(CopyBuffer(bbHandle, 1, 0, 1, bbUpper) <= 0) return;
   if(CopyBuffer(bbHandle, 2, 0, 1, bbLower) <= 0) return;
   
   double middleValue = bbMiddle[0];
   double upperValue  = bbUpper[0];
   double lowerValue  = bbLower[0];
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // v1.09: Bollinger Band Breakout Protection
   // ไม่ปิดกั้นการเทรดอีกต่อไปเมื่อราคาหลุดกรอบ Band แต่จะเก็บสถานะไว้ใช้
   // ปิดการคูณ Lot ทบต้นของฝั่ง Follow Trend (Main) แทน (ดูจุดคำนวณ Lot ด้านล่าง)
   bool priceAboveUpper = (ask > upperValue); // ราคาทะลุสูงกว่า Upper Band
   bool priceBelowLower = (bid < lowerValue);  // ราคาหลุดต่ำกว่า Lower Band
   
   bool volBuySignal = true;
   bool volSellSignal = true;
   
   if(Use_Volume_Filter) {
      long tickBuyVol_Curr = 0, tickSellVol_Curr = 0;
      long tickBuyVol_Prev = 0, tickSellVol_Prev = 0;
      
      MqlTick ticks[];
      datetime timeCurr = iTime(_Symbol, _Period, 0);
      datetime timePrev = iTime(_Symbol, _Period, 1);
      
      // คำนวณ Real Tick Volume สำหรับแท่งปัจจุบัน
      int copiedCurr = CopyTicksRange(_Symbol, ticks, COPY_TICKS_ALL, timeCurr * 1000, 0);
      if(copiedCurr > 0) {
         for(int i = 0; i < copiedCurr; i++) {
            if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) {
               tickBuyVol_Curr += (long)ticks[i].volume;
            } else if((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) {
               tickSellVol_Curr += (long)ticks[i].volume;
            }
         }
      }
      
      // คำนวณ Real Tick Volume สำหรับแท่งก่อนหน้า
      int copiedPrev = CopyTicksRange(_Symbol, ticks, COPY_TICKS_ALL, timePrev * 1000, timeCurr * 1000 - 1);
      if(copiedPrev > 0) {
         for(int i = 0; i < copiedPrev; i++) {
            if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) {
               tickBuyVol_Prev += (long)ticks[i].volume;
            } else if((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) {
               tickSellVol_Prev += (long)ticks[i].volume;
            }
         }
      }
      
      // ประเมินแรง Buy / Sell แยกกัน
      bool isBullishCurr = (tickBuyVol_Curr > tickSellVol_Curr);
      bool isBullishPrev = (tickBuyVol_Prev > tickSellVol_Prev);
      
      bool isBearishCurr = (tickSellVol_Curr > tickBuyVol_Curr);
      bool isBearishPrev = (tickSellVol_Prev > tickBuyVol_Prev);
      
      volBuySignal = (isBullishCurr && isBullishPrev);
      volSellSignal = (isBearishCurr && isBearishPrev);
   }
   
   // v1.06: คำนวณ Lot แยกโหมดอิสระต่อฝั่งผ่าน CalcLotBySteps() แทนสูตร Multiply ตัวเดียวแบบเดิม
   // v1.09: หากเทรนปัจจุบันหลุดกรอบ Band ไปในทิศทางเดียวกับตัวเอง (เทรน Buy แต่ราคา
   // ทะลุ Upper / เทรน Sell แต่ราคาหลุด Lower) ให้ฝั่ง Follow Trend (Main) หยุดคูณ Lot
   // ทบต้น ใช้ Lot ฐาน (Lot_Main) แทนทุก Step ส่วนฝั่ง Against Trend (Hedge) คำนวณทบต้น
   // ตามปกติเสมอ ไม่ถูกจำกัดโดยเงื่อนไขนี้
   bool capMainLot = (bid > middleValue && priceAboveUpper) || (bid < middleValue && priceBelowLower);
   
   double calcMainLot = capMainLot ? Lot_Main : CalcLotBySteps(Lot_Main, step, Lot_Main_Mode, Lot_Main_Multiplier, Lot_Main_PlusStep);
   double calcHedgeLot = CalcLotBySteps(Lot_Hedge, step, Lot_Hedge_Mode, Lot_Hedge_Multiplier, Lot_Hedge_PlusStep);
   
   calcMainLot = MathMin(calcMainLot, Max_Lot);
   calcHedgeLot = MathMin(calcHedgeLot, Max_Lot);
   
   calcMainLot = NormalizeDouble(calcMainLot, 2);
   calcHedgeLot = NormalizeDouble(calcHedgeLot, 2);
   
   double totalLotBefore = GetTotalLots();
   double totalLotAfter = totalLotBefore + calcMainLot + calcHedgeLot;
   int orderNum = GetTotalPositions() + 1; // ลำดับออเดอร์
   
   // รูปแบบ: (NP ชื่ออีเอ v1.0 #ลำดับออเดอร์ #lotรวม #กำไรเป้าหมาย)
   string comment = StringFormat("(NP SmartHedge Pro v1.7 #%d #%.2f #%.0f)", orderNum, totalLotAfter, Profit_Trigger);
   trade.SetExpertMagicNumber(Magic_Start);
   
   // v1.11: เงื่อนไข "เปิดออเดอร์ถัดไปเมื่อจบแท่งเทียนเท่านั้น" แยกอิสระต่อฝั่ง
   // Main/Hedge หากเปิดใช้งาน (true) ฝั่งนั้นจะเปิดออเดอร์ได้แค่ 1 ครั้งต่อ
   // แท่งเทียน (เทียบเวลาเปิดแท่งปัจจุบันกับแท่งล่าสุดที่เปิดออเดอร์ฝั่งนั้นไป)
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   bool mainAllowed  = (!Main_NewCandleOnly)  || (currentBarTime != lastMainOpenBarTime);
   bool hedgeAllowed = (!Hedge_NewCandleOnly) || (currentBarTime != lastHedgeOpenBarTime);
   
   // เทรน: ราคาเหนือ Middle Band = เทรน Buy, ราคาต่ำกว่า Middle Band = เทรน Sell
   if(bid > middleValue) {
      // เทรน Buy -> Main=Buy, Hedge=Sell
      if(volBuySignal && mainAllowed) {
         trade.Buy(calcMainLot, _Symbol, ask, 0, 0, comment);
         lastMainOpenBarTime = currentBarTime;
      }
      if(volSellSignal && hedgeAllowed) {
         trade.Sell(calcHedgeLot, _Symbol, bid, 0, 0, comment);
         lastHedgeOpenBarTime = currentBarTime;
      }
   } else if (bid < middleValue) {
      // เทรน Sell -> Main=Sell, Hedge=Buy
      if(volSellSignal && mainAllowed) {
         trade.Sell(calcMainLot, _Symbol, bid, 0, 0, comment);
         lastMainOpenBarTime = currentBarTime;
      }
      if(volBuySignal && hedgeAllowed) {
         trade.Buy(calcHedgeLot, _Symbol, ask, 0, 0, comment);
         lastHedgeOpenBarTime = currentBarTime;
      }
   }
}

//+------------------------------------------------------------------+
//| HEDGE OF TREND CHANGE                                            |
//| ตรวจจับการตัดเส้น Middle Band แบบฉับพลัน (เทรนกลับตัว) ขณะมี     |
//| ออเดอร์ค้างอยู่ แล้วเปิดออเดอร์ Hedge ด้วย Lot เท่าส่วนต่าง       |
//| ระหว่าง Buy/Sell เพื่อปรับ Lot ทั้งสองฝั่งให้เท่ากัน (เหมือน       |
//| Square Hedge แต่ไม่ปิดออเดอร์) — ทำงานได้ทุกครั้งที่มีการตัดสลับ   |
//| ไปมา เมื่อเปิดใช้งาน Use_HedgeTrendChange                        |
//+------------------------------------------------------------------+
void CheckHedgeOfTrendChange(int totalPos) {
   if(!Use_HedgeTrendChange) return;
   
   // ไม่มีออเดอร์ค้าง -> รีเซ็ตสถานะ รอเริ่มนับใหม่รอบถัดไป
   if(totalPos == 0) {
      lastTrendSide = 0;
      return;
   }
   
   if(CopyBuffer(bbHandle, 0, 0, 1, bbMiddle) <= 0) return;
   double middleValue = bbMiddle[0];
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   int currentSide = 0;
   if(bid > middleValue) currentSide = 1;       // ฝั่ง Buy
   else if(bid < middleValue) currentSide = -1; // ฝั่ง Sell
   else return; // ราคาเท่ากับ Middle พอดี ข้ามรอบนี้ไปก่อน
   
   // ยังไม่มีสถานะอ้างอิง (เพิ่งมีออเดอร์ หรือเพิ่งรีสตาร์ท) -> เก็บฝั่งปัจจุบันไว้ก่อน ไม่ถือเป็นการตัดเส้น
   if(lastTrendSide == 0) {
      lastTrendSide = currentSide;
      return;
   }
   
   // เกิดการตัดเส้น Middle Band สวนทางกับฝั่งเดิม -> เปิด Hedge Of Trend Change
   if(currentSide != lastTrendSide) {
      OpenHedgeOfTrendChange();
      lastTrendSide = currentSide;
   }
}

//+------------------------------------------------------------------+
//| เปิดออเดอร์ Hedge Of Trend Change ด้วย Lot เท่าส่วนต่าง Buy/Sell  |
//+------------------------------------------------------------------+
void OpenHedgeOfTrendChange() {
   double lotBuy = 0.0, lotSell = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic_Start) {
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)  lotBuy  += PositionGetDouble(POSITION_VOLUME);
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) lotSell += PositionGetDouble(POSITION_VOLUME);
      }
   }

   double lotMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double diff   = NormalizeDouble(MathAbs(lotBuy - lotSell), 2);

   // Lot สองฝั่งเท่ากันอยู่แล้ว ไม่ต้องเปิดเพิ่ม
   if(diff < lotMin) return;

   trade.SetAsyncMode(false);
   trade.SetExpertMagicNumber(Magic_Start);
   string comment = "(NP SmartHedge Pro HedgeTrendChange v1.7)";

   if(lotBuy < lotSell) {
      // Buy น้อยกว่า -> เปิด Buy เพิ่มเท่าส่วนต่าง
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      trade.Buy(diff, _Symbol, ask, 0, 0, comment);
   } else if(lotSell < lotBuy) {
      // Sell น้อยกว่า -> เปิด Sell เพิ่มเท่าส่วนต่าง
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      trade.Sell(diff, _Symbol, bid, 0, 0, comment);
   }

   hedgeTrendChangeCount++;
}

//+------------------------------------------------------------------+
//| AGAINST TREND STEP PROFIT LOCK                                   |
//| ล๊อคกำไรเป็นขั้น (% Lock) เฉพาะฝั่งที่เป็น Against Trend (สวนเทรน)  |
//| เมื่อกำไรย่อลงมาแตะระดับ Lock จะสั่งปิดเฉพาะฝั่งสวนเทรนทันที        |
//+------------------------------------------------------------------+
void CheckAgainstTrendStepLock(int totalPos) {
   if(!Enable_StepLock) return;
   
   int buyCount  = GetSidePositions(POSITION_TYPE_BUY);
   int sellCount = GetSidePositions(POSITION_TYPE_SELL);

   if(buyCount == 0)  peakAgainstBuyProfit  = 0.0;
   if(sellCount == 0) peakAgainstSellProfit = 0.0;

   if(totalPos == 0) return;

   if(CopyBuffer(bbHandle, 0, 0, 1, bbMiddle) <= 0) return;
   double middleValue = bbMiddle[0];
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ตรวจสอบทิศทางเทรนปัจจุบัน
   // Bid > Middle Band: Buy = Follow Trend, Sell = Against Trend
   // Bid < Middle Band: Sell = Follow Trend, Buy = Against Trend

   if(bid > middleValue && sellCount > 0) {
      // ฝั่ง Sell เป็น Against Trend
      double sellProfit = GetSideProfit(POSITION_TYPE_SELL);
      
      if(sellProfit >= Step_Lock_Trigger) {
         if(sellProfit > peakAgainstSellProfit) {
            peakAgainstSellProfit = sellProfit;
         }
      }
      
      if(peakAgainstSellProfit >= Step_Lock_Trigger) {
         double lockTarget = peakAgainstSellProfit * (Step_Lock_Percent / 100.0);
         if(sellProfit <= lockTarget) {
            bool closed = AsyncCloseAll(_Symbol, POSITION_TYPE_SELL, (long)Magic_Start);
            if(closed) {
               peakAgainstSellProfit = 0.0;
            }
         }
      }
   } else if(bid < middleValue && buyCount > 0) {
      // ฝั่ง Buy เป็น Against Trend
      double buyProfit = GetSideProfit(POSITION_TYPE_BUY);
      
      if(buyProfit >= Step_Lock_Trigger) {
         if(buyProfit > peakAgainstBuyProfit) {
            peakAgainstBuyProfit = buyProfit;
         }
      }
      
      if(peakAgainstBuyProfit >= Step_Lock_Trigger) {
         double lockTarget = peakAgainstBuyProfit * (Step_Lock_Percent / 100.0);
         if(buyProfit <= lockTarget) {
            bool closed = AsyncCloseAll(_Symbol, POSITION_TYPE_BUY, (long)Magic_Start);
            if(closed) {
               peakAgainstBuyProfit = 0.0;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CUT LOSS BY % OF BALANCE                                         |
//| CutLoss_Pct = 0.0  -> Disabled                                   |
//| CutLoss_Pct > 0.0  -> Loss Limit = Balance x CutLoss_Pct / 100   |
//+------------------------------------------------------------------+
bool CheckCutLoss(double totalProfit, int totalPositions) {
   // 0 หรือติดลบ = ไม่ใช้งาน Cut Loss
   if(CutLoss_Pct <= 0.0) return false;

   // ไม่มี Position ของ EA ค้างอยู่ ไม่ต้องตรวจ
   if(totalPositions <= 0) return false;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0) return false;

   double lossLimit = balance * (CutLoss_Pct / 100.0);

   // ตัวอย่าง:
   // Balance = $1,000, CutLoss_Pct = 5
   // lossLimit = $50
   // เมื่อ totalProfit <= -$50 ให้ปิด Position ทั้งหมดของ EA
   if(totalProfit <= -lossLimit) {
      PrintFormat("CUT LOSS TRIGGERED: Balance=%.2f | CutLoss=%.2f%% | Limit=-%.2f | Floating P/L=%.2f",
                  balance, CutLoss_Pct, lossLimit, totalProfit);

      CloseAllPositions();

      peakProfit = 0.0;
      peakAgainstBuyProfit = 0.0;
      peakAgainstSellProfit = 0.0;

      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| CLOSE ALL POSITIONS                                              |
//+------------------------------------------------------------------+
void CloseAllPositions() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      string symbol = PositionGetSymbol(i);
      if(symbol == _Symbol) {
         ulong magic = PositionGetInteger(POSITION_MAGIC);
         if(magic == Magic_Start) {
            ulong ticket = PositionGetInteger(POSITION_TICKET);
            trade.PositionClose(ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CLOSE ALL POSITIONS ASYNCHRONOUSLY (BY SYMBOL/TYPE/MAGIC)        |
//+------------------------------------------------------------------+
bool AsyncCloseAll(const string symbol, const ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)-1, const long magic = -1) {
   trade.SetAsyncMode(true); // เปิดโหมด Asynchronous

   ulong trades[];
   int total_positions = PositionsTotal();
   ArrayResize(trades, total_positions);

   int count = 0;

   // วนลูปหาโพซิชั่นทั้งหมดที่ตรงตามเงื่อนไข
   for(int i = total_positions - 1; i >= 0; --i) {
      if(pos.SelectByIndex(i)) {
         if((pos.PositionType() == pos_type || pos_type == (ENUM_POSITION_TYPE)-1) &&
            (pos.Symbol() == symbol) &&
            (pos.Magic() == magic || magic == -1)) {
            trades[count++] = pos.Ticket(); // เก็บ Ticket ที่ต้องปิด
         }
      }
   }

   // ปรับขนาด Array ให้พอดีกับจำนวนที่พบจริง
   ArrayResize(trades, count);

   // สั่งปิดแบบ Asynchronous ทีละออเดอร์
   for(int i = 0; i < count; i++) {
      if(pos.SelectByTicket(trades[i])) {
         trade.SetExpertMagicNumber(pos.Magic()); // ตั้ง Magic Number ก่อนปิด
         if(!trade.PositionClose(trades[i])) {
            PrintFormat("Failed to close position %I64u, Error: %d", trades[i], GetLastError());
         }
      }
   }

   trade.SetAsyncMode(false); // กลับสู่โหมด Synchronous

   return count > 0; // คืนค่า true หากมีการปิดออเดอร์อย่างน้อย 1 ออเดอร์
}

//+------------------------------------------------------------------+
//| SQUARE HEDGE LOT BUY/SELL ให้เท่ากันก่อน แล้วปิดทั้งหมดแบบ Async |
//+------------------------------------------------------------------+
bool SquareHedgeAndCloseAll(double targetProfit) {
   double lotBuy = 0.0, lotSell = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic_Start) {
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)  lotBuy  += PositionGetDouble(POSITION_VOLUME);
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) lotSell += PositionGetDouble(POSITION_VOLUME);
      }
   }

   double lotMin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double diff   = NormalizeDouble(MathAbs(lotBuy - lotSell), 2);

   // เปิดออเดอร์ Square Hedge 1 ออเดอร์ ที่ Lot เท่ากับส่วนต่าง เพื่อทำให้ Lot Buy/Sell เท่ากัน
   if(diff >= lotMin) {
      trade.SetAsyncMode(false); // ต้องเป็น Sync เพื่อให้ออเดอร์นี้เปิดสำเร็จก่อนเช็คกำไรรอบถัดไป
      trade.SetExpertMagicNumber(Magic_Start);
      string comment = "(NP SmartHedge Pro SquareHedge v1.7)";

      if(lotBuy < lotSell) {
         // Buy น้อยกว่า -> เปิด Buy เพิ่มเท่าส่วนต่าง
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         trade.Buy(diff, _Symbol, ask, 0, 0, comment);
      } else if(lotSell < lotBuy) {
         // Sell น้อยกว่า -> เปิด Sell เพิ่มเท่าส่วนต่าง
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         trade.Sell(diff, _Symbol, bid, 0, 0, comment);
      }
   }

   // เช็คกำไรอีกครั้งหลัง Square Hedge แล้ว หากถึงเป้า ให้ปิดออเดอร์ทั้งหมดแบบ Async ทันที
   double checkProfit = GetTotalProfit();
   if(checkProfit >= targetProfit) {
      AsyncCloseAll(_Symbol, (ENUM_POSITION_TYPE)-1, (long)Magic_Start);
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| UTILITY FUNCTIONS                                                |
//+------------------------------------------------------------------+
double GetTotalProfit() {
   double profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic_Start) {
         profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
   }
   return profit;
}

double GetSideProfit(ENUM_POSITION_TYPE posType) {
   double profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic_Start) {
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType) {
            profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         }
      }
   }
   return profit;
}

int GetTotalPositions() {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic_Start) {
         count++;
      }
   }
   return count;
}

int GetSidePositions(ENUM_POSITION_TYPE posType) {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic_Start) {
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType) {
            count++;
         }
      }
   }
   return count;
}

double GetTotalLots() {
   double total = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic_Start) {
         total += PositionGetDouble(POSITION_VOLUME);
      }
   }
   return total;
}

double GetDistanceToClosestOrder() {
   double minDistance = 999999.0;
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic_Start) {
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double dist = MathAbs(currentPrice - openPrice);
         if(dist < minDistance) {
            minDistance = dist;
         }
      }
   }
   return minDistance;
}

//+------------------------------------------------------------------+
//| ดึงสถิติ Lot และกำไรย้อนหลัง พร้อม Lot สะสมทั้งหมด (All-Time)    |
//| lotAll   : Lot สะสมทั้งหมด ใช้คำนวณรีเบทสะสม                     |
//| v1.07: เพิ่ม profitDay / profitWeek / profitMonth เพื่อใช้คำนวณ  |
//|        Profit Glow Summary (กำไร + รีเบท) แยกตามช่วงเวลา         |
//+------------------------------------------------------------------+
void GetHistoricalStats(double &lotDay, double &lotWeek, double &lotMonth, double &lotAll,
                        double &profitDay, double &profitWeek, double &profitMonth, double &profitAll) {
   lotDay = 0.0; 
   lotWeek = 0.0; 
   lotMonth = 0.0; 
   lotAll = 0.0;
   profitDay = 0.0;
   profitWeek = 0.0;
   profitMonth = 0.0;
   profitAll = 0.0;
   
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   
   // Day Start
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime startDay = StructToTime(dt);
   
   // Week Start (Monday as first day of week)
   int daysToMonday = dt.day_of_week - 1;
   if(daysToMonday < 0) daysToMonday = 6;
   datetime startWeek = startDay - (daysToMonday * 86400);
   
   // Month Start
   dt.day = 1;
   datetime startMonth = StructToTime(dt);
   
   if(HistorySelect(0, now + 86400)) {
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++) {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket > 0) {
            string sym = HistoryDealGetString(ticket, DEAL_SYMBOL);
            ulong magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
            long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
            
            if(sym == _Symbol && magic == Magic_Start) {
               double vol = HistoryDealGetDouble(ticket, DEAL_VOLUME);
               double prof = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_SWAP) + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
               datetime time = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
               
               // Profit จากดีลที่ปิดแล้ว แยกตามช่วงเวลา
               if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT) {
                  profitAll += prof;
                  if(time >= startDay)   profitDay   += prof;
                  if(time >= startWeek)  profitWeek  += prof;
                  if(time >= startMonth) profitMonth += prof;
               }
               
               // Traded lots (using DEAL_ENTRY_IN to avoid double counting open & close)
               if(entry == DEAL_ENTRY_IN) {
                  if(time >= startDay) lotDay += vol;
                  if(time >= startWeek) lotWeek += vol;
                  if(time >= startMonth) lotMonth += vol;
                  lotAll += vol; // สะสม Lot ทั้งหมดตั้งแต่เริ่มเทรด (ใช้คำนวณรีเบทรวม)
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| TIME MANAGEMENT (LOCAL TIME)                                     |
//+------------------------------------------------------------------+
bool IsTradingTime() {
   MqlDateTime tm;
   TimeLocal(tm);
   
   int currentMins = tm.hour * 60 + tm.min;
   bool allowedDay = false;
   int startMins = 0, endMins = 0;
   
   switch(tm.day_of_week) {
      case 1: allowedDay = Trade_Mon; ParseTime(Mon_Start, Mon_End, startMins, endMins); break;
      case 2: allowedDay = Trade_Tue; ParseTime(Tue_Start, Tue_End, startMins, endMins); break;
      case 3: allowedDay = Trade_Wed; ParseTime(Wed_Start, Wed_End, startMins, endMins); break;
      case 4: allowedDay = Trade_Thu; ParseTime(Thu_Start, Thu_End, startMins, endMins); break;
      case 5: allowedDay = Trade_Fri; ParseTime(Fri_Start, Fri_End, startMins, endMins); break;
      case 6: allowedDay = Trade_Sat; ParseTime(Sat_Start, Sat_End, startMins, endMins); break;
      case 0: allowedDay = Trade_Sun; ParseTime(Sun_Start, Sun_End, startMins, endMins); break;
   }
   
   if(!allowedDay) return false;
   if(currentMins >= startMins && currentMins <= endMins) return true;
   
   return false;
}

void ParseTime(string startStr, string endStr, int &startOut, int &endOut) {
   string sArr[], eArr[];
   StringSplit(startStr, ':', sArr);
   StringSplit(endStr, ':', eArr);
   
   if(ArraySize(sArr) >= 2) startOut = (int)StringToInteger(sArr[0]) * 60 + (int)StringToInteger(sArr[1]);
   if(ArraySize(eArr) >= 2) endOut = (int)StringToInteger(eArr[0]) * 60 + (int)StringToInteger(eArr[1]);
}

//+------------------------------------------------------------------+
//| v1.10: BREAK TIME TRADING (NEWS FILTER)                          |
//| ตรวจสอบว่าเวลาปัจจุบันอยู่ในช่วง "พักเทรด" หรือไม่ โดยอ้างอิงตาม   |
//| BreakTime_Reference (Local หรือ Server Time) เทียบกับรายการเวลา   |
//| เริ่มพักใน BreakTime_List (คั่นด้วย ,) แต่ละช่วงมีความยาว          |
//| BreakTime_Delay นาที เช่น List="15:00,18:00,19:00", Delay=30      |
//| -> พักเทรดช่วง 15:00-15:30, 18:00-18:30, 19:00-19:30 (นาทีที่ 30   |
//| ของแต่ละช่วงจะกลับมาเทรดต่อทันที) ฟังก์ชันนี้ใช้ "หยุดเปิดออเดอร์  |
//| ใหม่" เท่านั้น ไม่ปิดออเดอร์ที่มีอยู่แล้ว                          |
//+------------------------------------------------------------------+
bool IsBreakTime() {
   if(StringLen(BreakTime_List) == 0) return false;
   if(BreakTime_Delay <= 0) return false;
   
   // เลือกเวลาอ้างอิงตามที่ตั้งค่าไว้ (Local Time ของเครื่อง หรือ Server Time ของ Broker)
   MqlDateTime tm;
   if(BreakTime_Reference == TIME_REF_LOCAL) {
      TimeLocal(tm);
   } else {
      TimeToStruct(TimeCurrent(), tm);
   }
   int currentMins = tm.hour * 60 + tm.min;
   
   // แยกรายการเวลาเริ่มพักด้วย ,
   string items[];
   int count = StringSplit(BreakTime_List, ',', items);
   
   for(int i = 0; i < count; i++) {
      string item = items[i];
      StringTrimLeft(item);
      StringTrimRight(item);
      if(StringLen(item) == 0) continue;
      
      string hm[];
      if(StringSplit(item, ':', hm) < 2) continue;
      
      int h = (int)StringToInteger(hm[0]);
      int m = (int)StringToInteger(hm[1]);
      int breakStartMins = h * 60 + m;
      int breakEndMins = breakStartMins + BreakTime_Delay;
      
      // ช่วงเวลาปกติ ไม่ข้ามเที่ยงคืน: หยุดเทรดตั้งแต่นาทีที่เริ่ม จนถึงก่อนนาทีสิ้นสุด
      if(breakEndMins <= 1440) {
         if(currentMins >= breakStartMins && currentMins < breakEndMins) return true;
      } else {
         // กรณีช่วงพักข้ามเที่ยงคืน (เช่น เริ่ม 23:50 พัก 30 นาที ไปสิ้นสุด 00:20 ของวันถัดไป)
         if(currentMins >= breakStartMins || currentMins < (breakEndMins - 1440)) return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| v1.08: วาด/อัปเดตพื้นหลังทึบของ Panel                            |
//| คำนวณความกว้างจากข้อความที่ยาวที่สุดด้วย TextGetSize() เพื่อให้    |
//| กล่องพอดีกับเนื้อหาจริงทุกครั้งที่ตัวเลขเปลี่ยนความยาว            |
//+------------------------------------------------------------------+
void DrawPanelBackground(string &lines[], int lineCount) {
   string objName = "SHP_Panel_BG";
   if(!Panel_BG_Enable) {
      if(ObjectFind(0, objName) >= 0) ObjectDelete(0, objName);
      return;
   }

   // วัดความกว้างข้อความ (ขนาดติดลบ = หน่วย 1/10 point ให้ตรงกับ OBJPROP_FONTSIZE)
   TextSetFont("Arial", -Font_Size * 10);

   int maxW = 0;
      uint w = 0, h = 0;
   for(int i = 0; i < lineCount; i++) {
   if(TextGetSize(lines[i], w, h)) {
      if((int)w > maxW) maxW = (int)w;
   }
}
if(maxW <= 0) maxW = 400; // เผื่อกรณีวัดไม่ได้ไม่ได้

   int lineStep = Font_Size + 8;
   int bgW = maxW + (Panel_Padding * 2);
   int bgH = (lineCount * lineStep) + (Panel_Padding * 2);

   if(ObjectFind(0, objName) < 0) {
      ObjectCreate(0, objName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, objName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, objName, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, objName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, objName, OBJPROP_BACK, false);      // อยู่เหนือกราฟ
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, objName, OBJPROP_SELECTED, false);
      ObjectSetInteger(0, objName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, objName, OBJPROP_ZORDER, 0);
   }

   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, Panel_X - Panel_Padding);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, Panel_Y - Panel_Padding);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE, bgW);
   ObjectSetInteger(0, objName, OBJPROP_YSIZE, bgH);
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR, Panel_BG_Color);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, Panel_Border_Color);
}

//+------------------------------------------------------------------+
//| UI PANEL                                                         |
//| v1.07: เพิ่มบล็อก Profit Glow Summary = กำไรจากการเทรด + รีเบท   |
//| v1.08: วาดพื้นหลังทึบก่อนวาดตัวหนังสือ                            |
//+------------------------------------------------------------------+
void UpdatePanel(ENUM_TRADE_STATUS status, double currentProfit) {
   double lotBuy = 0, lotSell = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == Magic_Start) {
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) lotBuy += PositionGetDouble(POSITION_VOLUME);
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) lotSell += PositionGetDouble(POSITION_VOLUME);
      }
   }
   
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   
   double lotDay = 0, lotWeek = 0, lotMonth = 0, lotAll = 0;
   double profitDay = 0, profitWeek = 0, profitMonth = 0, profitAll = 0;
   GetHistoricalStats(lotDay, lotWeek, lotMonth, lotAll, profitDay, profitWeek, profitMonth, profitAll);
   
   // คำนวณรีเบทจาก Lot ที่เทรดจริง x อัตรารีเบทต่อ 1.0 Lot
   double rebateDay   = lotDay   * Rebate_Per_Lot;
   double rebateWeek  = lotWeek  * Rebate_Per_Lot;
   double rebateMonth = lotMonth * Rebate_Per_Lot;
   double rebateAll   = lotAll   * Rebate_Per_Lot;
   
   // v1.07: Profit Glow Summary = กำไรจากการเทรด + รีเบทที่ได้รับ
   double glowDay   = profitDay   + rebateDay;
   double glowWeek  = profitWeek  + rebateWeek;
   double glowMonth = profitMonth + rebateMonth;
   double glowAll   = profitAll   + rebateAll;     // เฉพาะออเดอร์ที่ปิดแล้ว
   double glowLive  = glowAll     + currentProfit; // รวมกำไร/ขาดทุนลอยตัวปัจจุบัน
   
   string statusStr = (status == STATUS_TRADING) ? "TRADING" : (status == STATUS_BREAK_TIME ? "BREAK-TIME" : (status == STATUS_OUT_TIME ? "OUT-TIME" : "OFF"));
   string limitStr = (CutLoss_Pct > 0.0) ? StringFormat("%.2f%% ($%.2f)", CutLoss_Pct, bal * (CutLoss_Pct / 100.0)) : "DISABLED";
   string hedgeTrendStr = Use_HedgeTrendChange ? StringFormat("ON (x%d)", hedgeTrendChangeCount) : "OFF";
   string stepLockStr = Enable_StepLock ? StringFormat("ON (Trig:$%.0f, Lock:%.0f%%)", Step_Lock_Trigger, Step_Lock_Percent) : "OFF";
   
   // แยกข้อความเป็นบรรทัด เพื่อให้ Object แต่ละตัวแสดงผลเรียงลงมา
   string lines[PANEL_LINES];
   color  cols[PANEL_LINES];
   
   lines[0]  = "--- SmartHedge Pro ---";
   lines[1]  = "Time (Local): " + TimeToString(TimeLocal(), TIME_DATE|TIME_MINUTES);
   lines[2]  = "Status: " + statusStr;
   lines[3]  = StringFormat("Balance: $%.2f", bal);
   lines[4]  = StringFormat("Profit All: $%.2f", profitAll);
   lines[5]  = StringFormat("Profit P/L: $%.2f", currentProfit);
   lines[6]  = StringFormat("Lot Day: %.2f | Week: %.2f | Month: %.2f", lotDay, lotWeek, lotMonth);
   lines[7]  = StringFormat("Lot All Time: %.2f", lotAll);
   lines[8]  = StringFormat("Active Lots: Buy %.2f | Sell %.2f | Total %.2f", lotBuy, lotSell, lotBuy + lotSell);
   lines[9]  = StringFormat("Rebate/Lot: $%.2f", Rebate_Per_Lot);
   lines[10] = StringFormat("Rebate Day: $%.2f | Week: $%.2f | Month: $%.2f", rebateDay, rebateWeek, rebateMonth);
   lines[11] = StringFormat("Rebate Total: $%.2f", rebateAll);
   lines[12] = "--- Profit Glow Summary (Profit + Rebate) ---";
   lines[13] = StringFormat("Glow Day: $%.2f | Week: $%.2f | Month: $%.2f", glowDay, glowWeek, glowMonth);
   lines[14] = StringFormat("Glow Total: $%.2f  ( $%.2f + $%.2f )", glowAll, profitAll, rebateAll);
   lines[15] = StringFormat("Glow + Floating: $%.2f", glowLive);
   lines[16] = StringFormat("Peak P/L: $%.2f", peakProfit);
   lines[17] = "Grid Round: " + IntegerToString(gridRound);
   lines[18] = "CutLoss Limit: " + limitStr + " | Hedge Trend: " + hedgeTrendStr;
   lines[19] = "Step Lock: " + stepLockStr + StringFormat(" | Peak Against Buy: $%.2f | Sell: $%.2f", peakAgainstBuyProfit, peakAgainstSellProfit);
   
   // กำหนดสีตัวอักษรแต่ละบรรทัด
   for(int i = 0; i < PANEL_LINES; i++) cols[i] = clrWhite;
   cols[2]  = (status == STATUS_TRADING) ? clrLime : (status == STATUS_BREAK_TIME ? clrOrange : clrSilver);
   cols[4]  = (profitAll >= 0) ? clrLime : clrTomato;
   cols[5]  = (currentProfit >= 0) ? clrLime : clrTomato;
   cols[12] = clrGold;
   cols[13] = clrGold;
   cols[14] = (glowAll  >= 0) ? clrAqua : clrTomato;
   cols[15] = (glowLive >= 0) ? clrAqua : clrTomato;
   
   // v1.08: วาดพื้นหลังก่อน เพื่อให้ตัวหนังสือถูกวาดทับอยู่ด้านบน
   DrawPanelBackground(lines, PANEL_LINES);
   
   for(int i = 0; i < PANEL_LINES; i++) {
      string objName = "SHP_Panel_Line_" + IntegerToString(i);
      if(ObjectFind(0, objName) < 0) {
         ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, Panel_X);
         ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, Font_Size);
         ObjectSetString(0, objName, OBJPROP_FONT, "Arial");
      }
      ObjectSetInteger(0, objName, OBJPROP_COLOR, cols[i]);
      // จัดระยะห่างบรรทัดโดยอิงจาก Font_Size
      ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, Panel_Y + (i * (Font_Size + 8)));
      ObjectSetString(0, objName, OBJPROP_TEXT, lines[i]);
   }
}
//+------------------------------------------------------------------+