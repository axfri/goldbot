# Phase 1 — MT5 Bot Core

## Implemented behaviour

`mt5/Experts/GoldBot.mq5` is an Expert Advisor for a MetaTrader 5 hedging
account. It:

1. Uses the current chart symbol by default, so Exness symbol suffixes are
   supported. `InpTradeSymbol` can override it.
2. Opens one managed BUY and one managed SELL during the entry session.
3. Places an initial stop loss with every market order.
4. Moves stop loss to break-even after the configured profit threshold.
5. Starts trailing after a second configured profit threshold and only moves a
   stop in the direction that reduces risk.
6. Allows new entries for exactly 10, 30, or 60 minutes.
7. Stops opening positions when the session expires, while continuing to
   protect all existing positions belonging to its symbol and magic number.

All distance inputs are MT5 **points**, not pips or dollars. Confirm point size
and stop-distance rules in the symbol specification before live use.

## Session lifecycle

The session end time is stored in an MT5 terminal global variable keyed by
account, symbol, magic number, and `InpSessionId`. Restarting MT5 or reattaching
the EA therefore cannot accidentally restart an expired entry window.

To deliberately start a new session, change `InpSessionId` to a new value. Do
not reuse an old ID unless its stored terminal global variable has been removed
intentionally.

If either initial order fails transiently, the EA retries only the missing side
while the entry session remains active. It never opens more than one managed
position of each side.

## Installation and test

1. Copy `mt5/Experts/GoldBot.mq5` into the terminal's `MQL5/Experts/GoldBot/`
   directory and compile it in MetaEditor.
2. Use an Exness **demo hedging account** and open the broker's XAUUSD chart.
3. Enable algorithmic trading and attach the EA.
4. Verify in the Experts log that the session end time is shown.
5. Verify one BUY and one SELL are opened with an initial SL.
6. In Strategy Tester, use a 10-minute session and confirm that no replacement
   order opens after expiry.
7. Confirm that existing positions continue receiving break-even and trailing
   SL updates after expiry.
8. Restart the terminal and confirm the original session end time is retained.
9. Change `InpSessionId` and confirm a new timed session begins.

## Safety boundaries

- The EA refuses to initialize on netting accounts.
- It manages only positions matching both its magic number and symbol.
- It does not close positions automatically at session expiry.
- Phase 1 does not include license/API communication, PostgreSQL, dashboards,
  take profit, money-based risk sizing, spread filters, or news filters.
- Validate all parameters in Strategy Tester and on demo before live trading.
