# PiggyGuard — Set It and Forget It

**A personal stop-loss / take-profit + DCA vault keeper, built on Reactive Network (Lasna testnet).**

You fund your own vault, set a stop-loss line, a take-profit line, and a DCA rhythm — then walk away. A reactive contract watches the price 24/7: if the price falls through your stop-loss it sells to safety, if it runs through your take-profit it banks profit, and every Cron tick it buys a fixed slice. No bot, no server, no one watching a screen.

Built for the [Reactive Omni Buildathon](https://dorahacks.io/hackathon/reactive-omni-buildathon/detail) (DoraHacks, Reactive Network), track **Set It and Forget It**. All testnets, zero real money.

> Status: **stage 1 skeleton — contracts compile, local tests pass, not yet deployed.**
> Deployment + full-loop evidence (origin tx → Lasna react() → callback tx) lands in stage 3.

## How it works

```
Base Sepolia                          Lasna                          Base Sepolia
┌─────────────────┐   PriceUpdated   ┌──────────────────────┐   callback   ┌───────────────────┐
│ MockPriceFeed   │ ───────────────► │ PiggyGuardReactive   │ ───────────► │ PiggyGuardCallback│
│ (owner pushes   │   subscribe      │ - price <= stopLoss  │  request     │ - double-guarded  │
│  prices by hand │                  │   -> stop-loss sell  │  Callback    │   (proxy + sender)│
│  / script)      │                  │ - price >= takeProfit│  V_1_0       │ - forwards to     │
└─────────────────┘                  │   -> take-profit sell│              │   PiggyVault      │
                                     │ - Cron100 tick       │              └───────┬───────────┘
                                     │   -> DCA buy         │                      │
                                     └──────────────────────┘                      ▼
                                                                     ┌───────────────────┐
                                                                     │ PiggyVault        │
                                                                     │ - holds position  │
                                                                     │ - executes the 3  │
                                                                     │   actions         │
                                                                     └───────────────────┘
```

- **Trigger source is self-controlled.** The price feed is our own contract; the demo pushes prices by script, so every trigger is reproducible and never depends on a public testnet pool's liquidity. (Execution is the menu item the judges asked for: "is this something you'd actually leave running?")
- **Each crossing fires at most once.** The reactive contract latches a stop-loss / take-profit trigger until the price returns inside the band — a price that stays below the line does not spam callbacks (each one bills the reactive contract's reserves).
- **DCA runs on Cron100** (~every 100 Lasna blocks, ~2 minutes), no off-chain scheduler.
- **The loop is the proof.** The full loop (origin event → Lasna `react()` → destination callback) was already proven end-to-end on the official basic demo in Omni form — see `evidence/` (stage 3) for this project's own three-transaction groups.

### Strategy priority — stop-loss > take-profit > DCA

The three strategies share one position, so they are not independent:

1. **Stop-loss (highest).** `price <= stopLoss` sells the whole risk position and sets `stopLossLatched`. While that latch is set, every Cron100 tick is skipped — DCA must not buy back the position the stop-loss just exited.
2. **Take-profit.** `price >= takeProfit` sells 50% and sets `takeProfitLatched`; DCA is paused while that latch is set too, so the sold half is not slowly repurchased.
3. **DCA (lowest).** A Cron tick requests a DCA buy only when `dcaEnabled` is true **and** neither latch is set.

**Recovery:** a price strictly inside the band (`stopLoss < price < takeProfit`) clears both latches, and DCA resumes on the next Cron100 tick. Changing the band with `setThresholds` also clears both latches (and rejects `stopLoss >= takeProfit`), so a new valid crossing is not swallowed by a stale latch.

Every callback also carries a monotonically increasing `actionId` from the reactive contract's single shared counter. The vault keeps a **separate replay watermark per action type** (`lastStopLossId` / `lastTakeProfitId` / `lastDcaId`): a delivery at or below its own type's watermark is ignored as a replay, but an out-of-order delivery of one type can never swallow an action of another type (fix-03 — the previous single watermark could permanently drop an in-flight stop-loss). Only actions that actually execute advance a watermark; skipped actions (paused vault, condition no longer holds at the execution price, nothing to sell, insufficient balance) leave the id usable, and guard failures are reported as `*Skipped` events instead of reverting, so a callback is never silently lost to a revert. Stop-loss / take-profit callbacks carry the trigger price **and the band threshold**: the vault executes at the feed's current `latestPrice()` — never at the one-hop-old trigger price — and only if the condition still holds at that price, so a crash that continues in flight still stops out (at the worse current price) while a recovery in flight no longer triggers a stale exit (fix-04). DCA has a circuit breaker: after a >20% jump away from the last executed tick's price, ticks are skipped until three consecutive ticks cluster near the new level, which is then adopted as the reference.

## Contracts

| Contract | Chain | Role |
|---|---|---|
| `src/MockPriceFeed.sol` | Base Sepolia | Self-controlled price source. Owner pushes prices; emits `PriceUpdated(price, timestamp)` (price indexed, 8 decimals, Chainlink style: `100_00000000` = $100.00). |
| `src/PiggyVault.sol` | Base Sepolia | Holds the test position and executes the three actions: `executeStopLoss` (sell all), `executeTakeProfit` (sell 50%), `executeDCA` (buy a fixed safe-asset amount). Only the callback contract may call them; the owner funds / withdraws / pauses. |
| `src/PiggyGuardCallback.sol` | Base Sepolia | Callback receiver. Omni double guard: caller must be the destination-chain callback proxy **and** the injected sender must be our reactive contract. Forwards each action to the vault. |
| `src/PiggyGuardReactive.sol` | Lasna | The reactive contract. Subscribes to `PriceUpdated` (Base Sepolia) + `Cron100` (Lasna); judges crossings; requests callbacks via `SYSTEM.requestCallbackV_1_0`. |

All prices and ledger amounts use **8 decimals** (USD-pegged, Chainlink style).

### Honest mock boundary

The vault is a **mock ledger**, not a real DEX trade: balances are ledger units and execution is a virtual swap at the feed's current price. `fundRisk` / `fundSafe` / `withdrawRisk` / `withdrawSafe` are owner-only ledger operations — there is **no ERC20 deposit/withdraw path and no end-user funding flow**; the ledger exists to make the automation's decisions observable, not to custody assets. This is deliberate — the demo must never depend on testnet DEX liquidity, and the thing being judged is the automation loop (reactive contract doing real work: watching, judging, scheduling). A mock-ERC20 venue can replace the ledger later without touching the reactive or callback contracts. No real tokens ever move; this is a testnet demo.

**Trust assumptions.** The price feed is single-owner and trusted by design (it is the demo's controlled price source); because the vault executes at the feed's own current price and re-checks the band condition there, a stale trigger price can no longer cause a wrong trade — but nothing can make an untrusted feed trustworthy: whoever controls the feed controls the execution price. Operationally, two wirings must be kept in sync by hand: changing the callback (`setCallback`) requires the matching `vault.setExecutor`, and the Cron contract address / topic follow plan §2.1 and are re-verified live on Lasna in stage 3.

## Build & test

```bash
forge build
forge test
```

Expected: 4 contracts compile (Solidity 0.8.29), 78 local tests pass — feed auth and zero-price rejection (push and constructor), vault math with per-type replay watermarks and cross-type out-of-order delivery, skip-instead-of-revert guards (pause / condition re-check at the feed execution price), execution-at-feed-price regressions (crash continuation and in-flight recovery, both directions), the DCA circuit breaker with three-tick level confirmation, callback authentication and forwarding, and the reactive decision logic (subscription tuple, latches, DCA priority and Cron unsubscribe, threshold re-arm, callback envelope, monotonic action ids, log chain/contract validation, failed-request no-latch retry, forceCheck recovery). `react()` is driven in tests via `vm.prank` of the SYSTEM address `0x8888…8888`, with a mock system contract etched there so the constructor's `subscribe` calls land and can be asserted.

## Deploy (four steps, testnets only)

The reactive contract lives on Lasna; the other three contracts live on Base Sepolia. Each step must be broadcast against the RPC of the chain it touches — a Base Sepolia broadcast cannot call the Lasna contract (that address has no code on Base Sepolia, so the call reverts).

```bash
export PRIVATE_KEY=...
export BASE_SEPOLIA_RPC=https://sepolia.base.org
export LASNA_RPC=https://lasna-rpc.rnk.dev/
# Base Sepolia callback proxy address, from https://dev.reactive.network/
export BASE_SEPOLIA_CALLBACK_PROXY=0x...
```

### Step 1 — Base Sepolia: feed + vault

```bash
# Base Sepolia (chain 84532)
forge script script/Deploy.s.sol:DeployBase \
  --rpc-url $BASE_SEPOLIA_RPC --broadcast
```

Prints `MockPriceFeed` and `PiggyVault`; keep them as `PRICE_FEED` and `VAULT`.

### Step 2 — Lasna: reactive contract

```bash
# Lasna (chain 5318007)
PRICE_FEED=<from step 1> \
forge script script/Deploy.s.sol:DeployReactive \
  --rpc-url $LASNA_RPC --broadcast
```

Prints `PiggyGuardReactive`; keep it as `REACTIVE`.

### Step 3 — Base Sepolia: callback + vault executor

```bash
# Base Sepolia (chain 84532)
REACTIVE=<from step 2> VAULT=<from step 1> \
forge script script/Deploy.s.sol:WireUpBase \
  --rpc-url $BASE_SEPOLIA_RPC --broadcast
```

Deploys `PiggyGuardCallback` and calls `vault.setExecutor(callback)`. Prints the callback address; keep it as `CALLBACK`.

### Step 4 — Lasna: backfill the callback address

```bash
# Lasna (chain 5318007)
REACTIVE=<from step 2> CALLBACK=<from step 3> \
forge script script/Deploy.s.sol:WireUpReactive \
  --rpc-url $LASNA_RPC --broadcast
```

Calls `reactive.setCallback(callback)`. The loop is now wired end-to-end.

## Run the demo (seed + first price)

With the four steps above done, fund the vault and push one price. The defaults match the README parameters: 2 risk units, $100 safe, and a push to $85 — below the $90 stop-loss, so it triggers the first loop. **Fund the callback reserve first (see [Reserves](#reserves--read-this-before-demo-day-plan-r4)) — a callback that cannot pay is not delivered.**

```bash
# Base Sepolia (chain 84532)
VAULT=<from step 1> PRICE_FEED=<from step 1> \
forge script script/Demo.s.sol:Demo \
  --rpc-url $BASE_SEPOLIA_RPC --broadcast
```

The script logs the feed, vault, wired executor, the three calls (`fundRisk`, `fundSafe`, `pushPrice`) and the resulting balances; forge prints one tx hash per call in the broadcast table above the log. Optional overrides: `DEMO_RISK` (default 2 units), `DEMO_SAFE` (default $100), `DEMO_PRICE` (default $85).

Expected chain of events: Base Sepolia `PriceUpdated(85e8)` → Lasna `react()` sees `85 <= 90` → requests `executeStopLoss` → Base Sepolia callback → vault sells all 2 risk units at $85. The stop-loss latch is now set, so Cron100 DCA ticks are skipped until a price inside the band ($90 < price < $120) clears it.

### Reserves — read this before demo day (plan R4)

- **Reactive contract (Lasna):** reaction transactions are billed to the contract itself. Top up via the system contract's `depositTo` (lREACT) and check `debt` — a contract with `debt > 0` silently stops receiving reactions. The starting reserve is set at deploy time and is env-configurable (`REACTIVE_RESERVE`, default `0.1 ether`, in `script/Deploy.s.sol`); size it as expected reactions × per-reaction cost for the run you are planning, and re-check `debt` before demo day. Disabling DCA (`setDcaEnabled(false)`) also unsubscribes the Cron ticks, so a disabled strategy stops billing instead of just ignoring ticks.
- **Callback contract (Base Sepolia):** callbacks are billed to the recipient on the destination chain. Fund it through the callback proxy's `depositTo` before the demo.

#### Callback reserve: copy-paste steps (H3)

`depositTo(address)` credits the target contract: it settles outstanding debt first, then adds the remainder to reserves.

```bash
# Target: the PiggyGuardCallback printed by step 3.
export CALLBACK=<from step 3>

# Proxy: the Base Sepolia callback proxy address from
# https://dev.reactive.network/ — the same value used as
# BASE_SEPOLIA_CALLBACK_PROXY in step 3.
export BASE_SEPOLIA_CALLBACK_PROXY=0x...

# 1) Credit the callback contract with Base Sepolia ETH.
cast send $BASE_SEPOLIA_CALLBACK_PROXY "depositTo(address)" $CALLBACK \
  --value 0.01ether \
  --rpc-url $BASE_SEPOLIA_RPC --private-key $PRIVATE_KEY

# 2) Health check: must print 0. Non-zero debt blocks delivery.
cast call $BASE_SEPOLIA_CALLBACK_PROXY "debt(address)" $CALLBACK \
  --rpc-url $BASE_SEPOLIA_RPC | cast to-dec
```

**Why 0.01 ETH:** every callback is requested with `gasLimit = 1_000_000`. At a deliberately conservative 1 gwei, one callback costs at most `1e6 * 1e-9 = 0.001 ETH`, so 0.01 ETH covers ~10 callbacks even in that worst case; at Base Sepolia's usual ~0.01 gwei it covers ~1,000. A full demo needs only 3–5 callbacks, and testnet ETH is free — 0.01 ETH is cheap insurance against the loop going silent mid-demo. Re-check `debt` right before recording.

- The official basic demo loop was run end-to-end first to prove the plumbing (see stage-2 notes in the project folder); PiggyGuard reuses the exact Omni pattern: `SYSTEM` `0x8888…8888`, `react()` with `onlySystem`, `requestCallbackV_1_0`, payload first argument `address(0)`.

### Open verification items (stage 3)

- **Cron subscription target.** Per the official docs cited in the plan, Cron events come from the legacy system contract `0x0000…fffFfF`; the constructor subscribes there. If Cron ticks do not arrive on Lasna, the subscribed contract address is the first thing to re-check against the current docs.
- **Base Sepolia callback proxy address.** Not hardcoded — taken from the official docs at deploy time.
- **Three full-loop transaction groups** (stop-loss / take-profit / DCA) with origin → Lasna → callback hashes, to be recorded in `evidence/` in stage 3.

## What is ours vs. reused

- **Ours (written for this hackathon):** `MockPriceFeed`, `PiggyVault`, `PiggyGuardCallback`, `PiggyGuardReactive`, tests, deploy scripts, this README.
- **Reused as a dependency:** `lib/reactive-lib-omni-src/` — Reactive Network's official reactive library (Omni), vendored unchanged; `lib/forge-std/` — Foundry's standard test library.
- **Reference only:** the official Reactive demo contracts (basic / cron / stop-take-profit) were studied to get the Omni migration right (Legacy `vmOnly` + `emit Callback` → Omni `onlySystem` + `requestCallbackV_1_0`); no demo contract code is submitted as ours.

## License

MIT. Testnets only — never use with real funds.
