#!/usr/bin/env bash
# fork-test.sh — keeper bot end-to-end test on a local Anvil chain
# (PHASE3-SPEC.md §1.8, local-Anvil variant).
#
# What it proves:
#  1. Dry-run: the bot watches the live demo deployment, logs NO_ACTION
#     at rest, and logs WOULD_THROTTLE (T1) after outflow is driven to
#     86% of the hour cap — and sends nothing (mode stays NORMAL).
#  2. Negative: a reverted guarded drain (the guard working) causes NO
#     bot action — the never-rule, live.
#  3. Live: with a funded, registered keeper key and KEEPER_DRY_RUN=false,
#     the bot sends a real throttle, a ThrottleSet event lands, the
#     policy reads THROTTLED, and the next cycle logs
#     SKIP_ALREADY_THROTTLED and sends nothing (idempotency).
#  4. R3 one-shot: KEEPER_TRIP_ONCE in dry-run logs WOULD_TRIP and exits.
#  5. Config: KEEPER_POLL_SECONDS=5 exits non-zero.
#
# Local-Anvil variant note: a Sepolia fork cannot reach 85% hour-use
# with the demo's 900-share attacker (900 < 1600 ether), so this test
# deploys the identical demo (AnvilDemo.s.sol) on a fresh local Anvil
# and drives outflow as the deployer, who holds minted mWETH. The
# guard code is the same; the local deployment is Phase 2 (12-field
# Policy), which also exercises the bot's Phase 2 layout path, while
# live Sepolia is Phase 1 (see RUNBOOK.md).
#
# Everything here is local-only: Anvil's well-known account #0 key,
# fresh throwaway keeper keys, no public chain, no real funds.
#
# Run:  bash keeper/test/fork-test.sh        (from the repo root, or anywhere)
# Requires: anvil, cast, forge on PATH (or ~/.foundry/bin), node, jq.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEEPER_DIR="$ROOT/keeper"
CONTRACTS_DIR="$ROOT/contracts"
ANVIL_PORT="${ANVIL_PORT:-8546}"
RPC="http://127.0.0.1:$ANVIL_PORT"
# Anvil's well-known default account #0 — local only, never a real key.
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEPLOYER="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

TMPDIR_WORK="$(mktemp -d)"
ANVIL_LOG="$TMPDIR_WORK/anvil.log"
BOT_LOG="$TMPDIR_WORK/bot.log"
DECISIONS="$TMPDIR_WORK/decisions.log"
LIVE_DECISIONS="$TMPDIR_WORK/decisions-live.log"
PASS=0
FAIL=0

note() { echo "--- $*"; }
ok()   { PASS=$((PASS+1)); echo "PASS: $*"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

cleanup() {
  if [ -n "${BOT_PID:-}" ] && kill -0 "$BOT_PID" 2>/dev/null; then kill "$BOT_PID" 2>/dev/null || true; fi
  if [ -n "${ANVIL_PID:-}" ] && kill -0 "$ANVIL_PID" 2>/dev/null; then kill "$ANVIL_PID" 2>/dev/null || true; fi
  rm -rf "$TMPDIR_WORK"
}
trap cleanup EXIT

# --- 1. Anvil + demo deployment -------------------------------------------
# Refuse to run against a stale anvil: the test needs a fresh chain.
if cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "ABORT: something already answers on $RPC — stop that anvil first (pgrep -x anvil)"
  exit 1
fi
note "starting anvil on :$ANVIL_PORT"
anvil --port "$ANVIL_PORT" >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!
for _ in $(seq 1 30); do
  cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break
  sleep 1
done
cast block-number --rpc-url "$RPC" >/dev/null || { echo "anvil did not start"; exit 1; }

note "deploying the fork-test deployment (forge script, deploy-only)"
DEPLOY_OUT="$(cd "$CONTRACTS_DIR" && PRIVATE_KEY="$DEPLOYER_KEY" \
  forge script script/DeployFork.s.sol:DeployFork --rpc-url "$RPC" --broadcast --start-fresh 2>&1)"
echo "$DEPLOY_OUT" | grep -E "ArbGuard:|GuardedVault:|GuardedPool:|fork deploy complete" || true
addr_of() { echo "$DEPLOY_OUT" | grep "$1" | head -1 | grep -oE "0x[0-9a-fA-F]{40}"; }
GUARD="$(addr_of 'ArbGuard:')"
GVAULT="$(addr_of 'GuardedVault:')"
UVAULT="$(addr_of 'UnguardedVault:')"
GPOOL="$(addr_of 'GuardedPool:')"
UPOOL="$(addr_of 'UnguardedPool:')"
MWETH="$(addr_of 'mWETH:')"
MUSDC="$(addr_of 'mUSDC:')"
ATTACKER_ADDR="$(addr_of 'Attacker:')"
[ -n "$GUARD" ] && [ -n "$GVAULT" ] && [ -n "$GPOOL" ] && [ -n "$MWETH" ] && [ -n "$ATTACKER_ADDR" ] \
  || { echo "could not parse deployment addresses"; echo "$DEPLOY_OUT" | tail -5; exit 1; }
echo "guard=$GUARD vault=$GVAULT pool=$GPOOL mWETH=$MWETH mUSDC=$MUSDC attacker=$ATTACKER_ADDR"

# Fresh throwaway keeper key for this test (local Anvil only).
KEEPER_JSON="$(cast wallet new --json)"
KEEPER_KEY="$(echo "$KEEPER_JSON" | jq -r .data[0].private_key)"
KEEPER_ADDR="$(echo "$KEEPER_JSON" | jq -r .data[0].address)"
echo "test keeper: $KEEPER_ADDR"

bot_env() {
  # $1 = decisions log, $2 = dry-run true/false, $3 = extra assignments
  cat <<EOF
KEEPER_RPC_URL=$RPC
KEEPER_GUARD_ADDRESS=$GUARD
KEEPER_CHAIN_ID=31337
KEEPER_PRIVATE_KEY=$KEEPER_KEY
KEEPER_POLICY_IDS=0,1
KEEPER_DEPLOY_BLOCK=0
KEEPER_POLL_SECONDS=10
KEEPER_DRY_RUN=$2
KEEPER_ALLOW_TRIP=false
KEEPER_THROTTLE_SECONDS=86400
KEEPER_HOUR_USE_PCT=80
KEEPER_DAY_USE_PCT=80
KEEPER_LARGE_PASS_PCT=50
KEEPER_ORACLE_FAIL_POLLS=0
KEEPER_LOG_FILE=$1
KEEPER_MWETH_ADDRESS=$MWETH
KEEPER_MUSDC_ADDRESS=$MUSDC
KEEPER_GUARDED_VAULT_ADDRESS=$GVAULT
KEEPER_UNGUARDED_VAULT_ADDRESS=$UVAULT
KEEPER_GUARDED_POOL_ADDRESS=$GPOOL
KEEPER_UNGUARDED_POOL_ADDRESS=$UPOOL
$3
EOF
}

start_bot() {
  # $1 = env file, $2 = decisions log file. Runs the bot in the
  # background and waits until it has logged its first decision (or
  # died — node + viem startup takes ~2s, so a bare sleep is racy).
  env $(grep -v '^$' "$1" | xargs) node "$KEEPER_DIR/dist/src/index.js" >>"$BOT_LOG" 2>&1 &
  BOT_PID=$!
  for _ in $(seq 1 20); do
    if ! kill -0 "$BOT_PID" 2>/dev/null; then
      echo "bot exited early:"; cat "$BOT_LOG"; exit 1
    fi
    if [ -s "$2" ]; then break; fi
    sleep 1
  done
  if [ ! -s "$2" ]; then echo "bot logged nothing in 20s:"; cat "$BOT_LOG"; exit 1; fi
}
stop_bot() { kill "$BOT_PID" 2>/dev/null || true; wait "$BOT_PID" 2>/dev/null || true; BOT_PID=""; }

wait_for_cycle() { sleep 13; } # poll is 10s; one full cycle + margin

# --- 2. Dry-run baseline ---------------------------------------------------
note "dry-run baseline (expect NO_ACTION)"
bot_env "$DECISIONS" true "" > "$TMPDIR_WORK/env-dry.env"
(cd "$KEEPER_DIR" && npm run build >/dev/null 2>&1)
start_bot "$TMPDIR_WORK/env-dry.env" "$DECISIONS"
wait_for_cycle
if grep -q '"policyId":0,"mode":"NORMAL","decision":"NO_ACTION"' "$DECISIONS" \
   && grep -q '"policyId":1,"mode":"NORMAL","decision":"NO_ACTION"' "$DECISIONS"; then
  ok "dry-run baseline: both policies NORMAL, NO_ACTION"
else
  bad "dry-run baseline: expected NO_ACTION lines"; cat "$DECISIONS" 2>/dev/null || true
fi

# --- 3. Negative: reverted guarded drain -> no action -----------------------
note "negative test: guarded drain reverts (guard working) -> bot must do nothing"
echo "attacker: $ATTACKER_ADDR"
if cast send "$ATTACKER_ADDR" "drainOnly(address,uint256,uint256)" "$GVAULT" 10ether 200 \
     --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" >/dev/null 2>&1; then
  bad "negative test: guarded drainOnly unexpectedly SUCCEEDED (guard failed?)"
else
  ok "negative test: guarded drain reverted as expected"
fi
BEFORE=$(grep -c 'WOULD_THROTTLE' "$DECISIONS" 2>/dev/null || true); BEFORE=${BEFORE:-0}
wait_for_cycle
AFTER=$(grep -c 'WOULD_THROTTLE' "$DECISIONS" 2>/dev/null || true); AFTER=${AFTER:-0}
if [ "$BEFORE" = "$AFTER" ] && grep -q '"decision":"NO_ACTION"' "$DECISIONS"; then
  ok "negative test: bot took no action on the reverted drain"
else
  bad "negative test: bot acted after a revert (WOULD_THROTTLE $BEFORE -> $AFTER)"
fi

# --- 4. Drive outflow to 86% of the hour cap (T1) ---------------------------
note "driving outflow: deposit 2000 mWETH, then 43 x withdraw 40 mWETH (86% of hour cap)"
cast send "$MWETH" "approve(address,uint256)" "$GVAULT" 2000ether \
  --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" >/dev/null
cast send "$GVAULT" "deposit(uint256)" 2000ether \
  --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" >/dev/null
for _ in $(seq 1 43); do
  cast send "$GVAULT" "withdraw(uint256)" 40ether \
    --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" >/dev/null
done
HOUR_USE="$(cast call "$GUARD" "outflowInHour(uint256) returns (uint256)" 0 --rpc-url "$RPC")"
echo "outflowInHour policy 0: $HOUR_USE wei (1720 ether expected)"
wait_for_cycle
if grep -q '"policyId":0.*"decision":"WOULD_THROTTLE".*T1 hour-use 8[6-9]%' "$DECISIONS"; then
  ok "dry-run: WOULD_THROTTLE (T1, ~86% hour-use) logged for policy 0"
else
  bad "dry-run: no WOULD_THROTTLE/T1 line"; tail -5 "$DECISIONS"
fi
MODE="$(cast call "$GUARD" "getMode(uint256) returns (uint8)" 0 --rpc-url "$RPC")"
if [ "$MODE" = "0" ]; then ok "dry-run: sent nothing (mode still NORMAL)"; else bad "dry-run: mode changed to $MODE"; fi

# --- 5. R3 one-shot (dry-run) ------------------------------------------------
note "R3 one-shot dry-run (KEEPER_TRIP_ONCE=1)"
stop_bot
bot_env "$DECISIONS" true "KEEPER_TRIP_ONCE=1" > "$TMPDIR_WORK/env-r3.env"
# R3 needs a registered keeper; register the test key first (owner = deployer).
cast send "$GUARD" "addKeeper(uint256,address)" 0 "$KEEPER_ADDR" \
  --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" >/dev/null
cast send "$GUARD" "addKeeper(uint256,address)" 1 "$KEEPER_ADDR" \
  --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" >/dev/null
# Fund the keeper key (1 ETH is far more than a throttle costs).
cast send "$KEEPER_ADDR" --value 1ether --private-key "$DEPLOYER_KEY" --rpc-url "$RPC" >/dev/null
(cd "$KEEPER_DIR" && env $(grep -v '^$' "$TMPDIR_WORK/env-r3.env" | xargs) \
  timeout 30 node dist/src/index.js >>"$BOT_LOG" 2>&1)
if grep -q '"decision":"WOULD_TRIP".*R3 manual trip policy 1' "$DECISIONS"; then
  ok "R3: WOULD_TRIP logged for policy 1, bot exited"
else
  bad "R3: no WOULD_TRIP line"; tail -3 "$DECISIONS"
fi

# --- 6. Live: real throttle lands --------------------------------------------
note "live mode: real throttle must land, then SKIP_ALREADY_THROTTLED"
bot_env "$LIVE_DECISIONS" false "" > "$TMPDIR_WORK/env-live.env"
start_bot "$TMPDIR_WORK/env-live.env" "$LIVE_DECISIONS"
wait_for_cycle
if grep -q '"policyId":0.*"decision":"THROTTLE_SENT"' "$LIVE_DECISIONS"; then
  ok "live: THROTTLE_SENT logged for policy 0"
else
  bad "live: no THROTTLE_SENT line"; cat "$LIVE_DECISIONS" 2>/dev/null || true; cat "$BOT_LOG" | tail -5
fi
MODE="$(cast call "$GUARD" "getMode(uint256) returns (uint8)" 0 --rpc-url "$RPC")"
if [ "$MODE" = "1" ]; then ok "live: policy 0 reads THROTTLED on-chain"; else bad "live: mode is $MODE, expected 1 (THROTTLED)"; fi
THROTTLE_SETS="$(cast logs --from-block 0 --to-block latest --address "$GUARD" \
  --rpc-url "$RPC" --json 2>/dev/null | jq -r \
  --arg topic "$(cast sig-event 'ThrottleSet(uint256,address,uint256)')" \
  '[.[] | select(.topics[0] == $topic)] | length' 2>/dev/null || echo "?")"
echo "ThrottleSet events on-chain: $THROTTLE_SETS (expect 1)"
wait_for_cycle
if grep -q '"policyId":0.*"decision":"SKIP_ALREADY_THROTTLED"' "$LIVE_DECISIONS"; then
  ok "live: second cycle SKIP_ALREADY_THROTTLED (idempotent, no re-throttle)"
else
  bad "live: no SKIP_ALREADY_THROTTLED line"; tail -4 "$LIVE_DECISIONS"
fi
stop_bot

# --- 7. Config fail-fast ------------------------------------------------------
note "config test: KEEPER_POLL_SECONDS=5 must exit non-zero"
bot_env "$DECISIONS" true "KEEPER_POLL_SECONDS=5" > "$TMPDIR_WORK/env-bad.env"
if (cd "$KEEPER_DIR" && env $(grep -v '^$' "$TMPDIR_WORK/env-bad.env" | xargs) \
    timeout 20 node dist/src/index.js >>"$BOT_LOG" 2>&1); then
  bad "config test: bot started with KEEPER_POLL_SECONDS=5 (must reject)"
else
  ok "config test: KEEPER_POLL_SECONDS=5 rejected (non-zero exit)"
fi

echo "=== fork test: $PASS passed, $FAIL failed ==="
[ "$FAIL" = "0" ]
