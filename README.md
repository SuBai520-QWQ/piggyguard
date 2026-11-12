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

## Contracts

| Contract | Chain | Role |
|---|---|---|
| `src/MockPriceFeed.sol` | Base Sepolia | Self-controlled price source. Owner pushes prices; emits `PriceUpdated(price, timestamp)` (price indexed, 8 decimals, Chainlink style: `100_00000000` = $100.00). |
| `src/PiggyVault.sol` | Base Sepolia | Holds the test position and executes the three actions: `executeStopLoss` (sell all), `executeTakeProfit` (sell 50%), `executeDCA` (buy a fixed safe-asset amount). Only the callback contract may call them; the owner funds / withdraws / pauses. |
| `src/PiggyGuardCallback.sol` | Base Sepolia | Callback receiver. Omni double guard: caller must be the destination-chain callback proxy **and** the injected sender must be our reactive contract. Forwards each action to the vault. |
| `src/PiggyGuardReactive.sol` | Lasna | The reactive contract. Subscribes to `PriceUpdated` (Base Sepolia) + `Cron100` (Lasna); judges crossings; requests callbacks via `SYSTEM.requestCallbackV_1_0`. |

All prices and ledger amounts use **8 decimals** (USD-pegged, Chainlink style).

### Honest mock boundary

The vault is a **mock ledger**, not a real DEX trade: balances are ledger units and execution is a virtual swap at the trigger price. This is deliberate — the demo must never depend on testnet DEX liquidity, and the thing being judged is the automation loop (reactive contract doing real work: watching, judging, scheduling). A mock-ERC20 venue can replace the ledger later without touching the reactive or callback contracts. No real tokens ever move; this is a testnet demo.

## Build & test

```bash
forge build
forge test
```

Expected: 4 contracts compile (Solidity 0.8.29), 18 local tests pass — vault math, feed auth, and the reactive decision logic (latches, band re-arm, Cron DCA, silent ignore of foreign logs; `react()` is driven in tests via `vm.prank` of the SYSTEM address `0x8888…8888`, with a mock system contract etched there so the constructor's `subscribe` calls land).

## Deploy (stage 3, testnets only)

```bash
# 1. Base Sepolia: feed + vault
forge script script/Deploy.s.sol:DeployBase \
  --rpc-url https://sepolia.base.org --broadcast

# 2. Lasna: reactive contract (funded with 0.1 lREACT at construction)
forge script script/Deploy.s.sol:DeployReactive \
  --rpc-url https://lasna-rpc.rnk.dev/ --broadcast

# 3. Base Sepolia: callback + wiring (needs REACTIVE + VAULT addresses)
forge script script/Deploy.s.sol:WireUp \
  --rpc-url https://sepolia.base.org --broadcast
```

Env vars: `PRIVATE_KEY`, `BASE_SEPOLIA_CALLBACK_PROXY` (Base Sepolia callback proxy address, from [dev.reactive.network](https://dev.reactive.network/)), `PRICE_FEED`, `VAULT`, `REACTIVE`. Optional: `INITIAL_PRICE` (default $100), `STOP_LOSS` ($90), `TAKE_PROFIT` ($120), `DCA_AMOUNT` ($10).

### Reserves — read this before demo day (plan R4)

- **Reactive contract (Lasna):** reaction transactions are billed to the contract itself. Top up via the system contract's `depositTo` (lREACT) and check `debt` — a contract with `debt > 0` silently stops receiving reactions.
- **Callback contract (Base Sepolia):** callbacks are billed to the recipient on the destination chain. Top up via the callback proxy's `depositTo` (Base Sepolia ETH) before the demo.
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
