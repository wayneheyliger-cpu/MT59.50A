// GoldPulse_BurstTrend_v3_10_TradeFlow.mq5

// EA Code with updated parameters
// ... (rest of the EA code goes here) ...

// Update locked default parameters for real-tick best profit factor
input bool InpUseM1CandleConfirm = true;
input double InpMinBodyATR = 0.05;
input bool InpRequireCloseBeyondPrev = false;
input double InpMaxCloseDistanceATR = 1.20;
input int InpProbeStyle = GBT_PROBE_TREND_AND_TICK;
input int InpTickLookback = 10;
input int InpMinDirectionalTicks = 6;
input double InpMaxImpulseSeconds = 12.0;
input double InpTickImpulsePoints = 25.0;
input int InpMinSecondsBetweenAdds = 10;
input double InpMinSameSideSpacingPoints = 45.0;
input double InpMinBasketProfitToAdd = 0.00;

// Logic for internal per-direction per-M1-bar throttle
datetime lastM1BarTimeUp = 0; // Last M1 bar time opened for Up direction
datetime lastM1BarTimeDown = 0; // Last M1 bar time opened for Down direction

void TryOpenProbe(int direction) {
    datetime currentBarTime = iTime(NULL, PERIOD_M1, 0);
    if (direction == 1 && currentBarTime == lastM1BarTimeUp) {
        return; // Prevent opening if already opened in current Up bar
    } else if (direction == -1 && currentBarTime == lastM1BarTimeDown) {
        return; // Prevent opening if already opened in current Down bar
    }
    // Logic to open the probe
    // ... (existing logic to open the probe) ...
    if (direction == 1) {
        lastM1BarTimeUp = currentBarTime; // Update last time opened for Up
    } else {
        lastM1BarTimeDown = currentBarTime; // Update last time opened for Down
    }
}