"use client";

import { useEffect, useRef, useState } from "react";
import { useAccount, usePublicClient, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { decodeErrorResult, encodeFunctionData, formatEther, parseEther } from "viem";
import {
  ARB_GUARD_ABI,
  ATTACKER_ABI,
  BLOCKED_ATTEMPTS_KEY,
  BLOCKED_ATTEMPT_EVENT,
  CONTRACT_ADDRESSES,
  POOL_ABI,
  REASON_NAMES,
  TOKEN_ABI,
  isDeployed,
  type BlockedAttempt,
} from "@/lib/contracts";

type Target = "guarded" | "unguarded";
type Attack = "drain" | "price-push";

type SimResult = {
  status: "success" | "reverted";
  title: string;
  detail: string;
  revertReason?: string;
  balanceBefore: string;
  balanceAfter: string;
  txHash?: string;
  blockNumber?: number;
  txStatus?: string;
  live: boolean;
};

/** Walk an error (viem BaseError cause chain included) for revert data and decode the reason code. */
export function decodeViolationReason(error: unknown): number | null {
  const candidates: string[] = [];
  const seen = new Set<unknown>();
  const walk = (value: unknown, depth: number): void => {
    if (value == null || depth > 6 || seen.has(value)) return;
    seen.add(value);
    if (typeof value === "string") {
      // Revert data may be embedded in a message ("... data 0x75db3afb...").
      for (const m of value.matchAll(/0x[0-9a-fA-F]{8,}/g)) candidates.push(m[0]);
      return;
    }
    if (typeof value !== "object") return;
    const obj = value as Record<string, unknown>;
    if (typeof obj.data === "string" && obj.data.startsWith("0x")) candidates.push(obj.data);
    if (typeof obj.message === "string") walk(obj.message, depth + 1);
    if (obj.cause !== undefined) walk(obj.cause, depth + 1);
    // viem BaseError keeps the raw revert in `cause.data` or nested `cause.cause`.
    if (typeof obj.details === "string") walk(obj.details, depth + 1);
  };
  walk(error, 0);
  // Try every candidate: decodeErrorResult matches on the ABI, so no
  // hardcoded selector is needed (the live selector is 0xe63ab918).
  for (const data of candidates) {
    try {
      const decoded = decodeErrorResult({ abi: ARB_GUARD_ABI, data: data as `0x${string}` });
      if (decoded.errorName === "ArbGuardViolation" && typeof decoded.args?.[0] === "number") {
        return decoded.args[0];
      }
    } catch {
      // Not decodable as ArbGuardViolation — try the next candidate.
    }
  }
  return null;
}

function recordBlockedAttempt(attempt: BlockedAttempt) {
  try {
    const raw = localStorage.getItem(BLOCKED_ATTEMPTS_KEY);
    const list: BlockedAttempt[] = raw ? (JSON.parse(raw) as BlockedAttempt[]) : [];
    list.push(attempt);
    localStorage.setItem(BLOCKED_ATTEMPTS_KEY, JSON.stringify(list));
  } catch {
    // Session store is best-effort; the receipt on this page is the record.
  }
  window.dispatchEvent(new CustomEvent(BLOCKED_ATTEMPT_EVENT, { detail: attempt }));
}

/**
 * Attack simulator. Pick Guarded vs Unguarded, pick an attack, run it.
 *
 * LIVE PATH (isDeployed): the buttons call the Attacker contract —
 * drainOnly(vault, 10 ether, 200) for the drain, pushPriceAndSwap(pool,
 * mWETH, 1000 ether) for the price push — with an explicit gas limit so a
 * reverting tx is actually broadcast (a wallet's pre-flight simulation
 * would otherwise refuse it and no receipt would exist). The receipt,
 * before/after balances and the decoded ArbGuardViolation reason are shown.
 * A guarded revert is recorded in the session store (localStorage key
 * `arbguard:blocked-attempts` + `arbguard:blocked-attempt` window event)
 * so the feed page can show it — a reverted tx leaves no on-chain event.
 *
 * Until the contracts are deployed (isDeployed === false) the run is a
 * LOCAL SIMULATION of the exact outcomes the fork tests prove — clearly
 * labelled as simulated, with no fake tx hash and no fake receipt.
 */
export function AttackSimulator() {
  const { address, isConnected } = useAccount();
  const publicClient = usePublicClient();
  const { writeContractAsync, isPending, error: writeError } = useWriteContract();
  const [target, setTarget] = useState<Target>("guarded");
  const [attack, setAttack] = useState<Attack>("drain");
  const [result, setResult] = useState<SimResult | null>(null);
  const [liveError, setLiveError] = useState<string | null>(null);
  const [txHash, setTxHash] = useState<`0x${string}` | undefined>(undefined);
  const [pendingMeta, setPendingMeta] = useState<{
    attack: Attack;
    target: Target;
    vault: `0x${string}`;
    pool: `0x${string}`;
    before: string;
  } | null>(null);
  const processedHash = useRef<string | null>(null);

  const { data: receipt, isLoading: receiptLoading } = useWaitForTransactionReceipt({
    hash: txHash,
    query: { enabled: !!txHash },
  });

  // Resolve the receipt into a displayed result once it lands.
  useEffect(() => {
    if (!receipt || !pendingMeta || !publicClient) return;
    if (processedHash.current === receipt.transactionHash) return;
    processedHash.current = receipt.transactionHash;
    const { attack: atk, target: tgt, vault, pool } = pendingMeta;
    const guarded = tgt === "guarded";
    const attackName = atk === "drain" ? "drain" : "price-push";
    const targetName = guarded ? "guarded" : "unguarded";

    (async () => {
      let after: string;
      if (atk === "drain") {
        const bal = await publicClient.readContract({
          address: CONTRACT_ADDRESSES.mweth,
          abi: TOKEN_ABI,
          functionName: "balanceOf",
          args: [vault],
        });
        after = `${formatEther(bal)} mWETH in vault`;
      } else {
        const [r0, r1] = await Promise.all([
          publicClient.readContract({ address: pool, abi: POOL_ABI, functionName: "reserve0", args: [] }),
          publicClient.readContract({ address: pool, abi: POOL_ABI, functionName: "reserve1", args: [] }),
        ]);
        after = `reserves ${formatEther(r0)} mWETH / ${formatEther(r1)} mUSDC`;
      }

      if (receipt.status === "success") {
        setResult({
          status: "success",
          title:
            atk === "drain"
              ? "Transaction succeeded — vault drained"
              : "Transaction succeeded — price pushed",
          detail:
            atk === "drain"
              ? "drainOnly() looped withdraw() in one transaction. Each call was individually valid, so nothing stopped it."
              : "pushPriceAndSwap() executed a large swap that moved the pool price far from the reference. The pool is now mispriced for everyone else.",
          balanceBefore: pendingMeta.before,
          balanceAfter: after,
          txHash: receipt.transactionHash,
          blockNumber: Number(receipt.blockNumber),
          txStatus: receipt.status,
          live: true,
        });
        return;
      }

      // Reverted on-chain: re-run the same call statically to capture the revert data.
      let reasonCode: number | null = null;
      try {
        const data =
          atk === "drain"
            ? encodeFunctionData({ abi: ATTACKER_ABI, functionName: "drainOnly", args: [vault, parseEther("10"), 200n] })
            : encodeFunctionData({
                abi: ATTACKER_ABI,
                functionName: "pushPriceAndSwap",
                args: [pool, CONTRACT_ADDRESSES.mweth, parseEther("1000")],
              });
        await publicClient.call({ account: address, to: CONTRACT_ADDRESSES.attacker, data });
      } catch (err) {
        reasonCode = decodeViolationReason(err);
      }
      const reasonName = reasonCode !== null ? REASON_NAMES[reasonCode] : "UNKNOWN";
      setResult({
        status: "reverted",
        title:
          atk === "drain"
            ? "Transaction reverted — drain blocked"
            : "Transaction reverted — price push blocked",
        detail:
          atk === "drain"
            ? "The looped withdrawals pushed the block's cumulative outflow over maxOutflowPerBlock, so check() reverted the ENTIRE transaction — including the withdrawals earlier in the loop."
            : "The swap's execution price deviated from the TWAP reference by more than maxPriceDeviationBps, so check() reverted it. The pool price never moved.",
        revertReason:
          reasonCode !== null ? `ArbGuardViolation(${reasonName})` : "Reverted (reason could not be decoded)",
        balanceBefore: pendingMeta.before,
        balanceAfter: after,
        txHash: receipt.transactionHash,
        blockNumber: Number(receipt.blockNumber),
        txStatus: receipt.status,
        live: true,
      });
      if (guarded && reasonCode !== null) {
        recordBlockedAttempt({
          ts: Date.now(),
          attack: attackName,
          target: targetName,
          reason: reasonName,
          txHash: receipt.transactionHash,
        });
      }
    })();
  }, [receipt, pendingMeta, publicClient, address]);

  function simulate(): SimResult {
    if (attack === "drain") {
      if (target === "unguarded") {
        return {
          status: "success",
          title: "Transaction succeeded — vault drained",
          detail:
            "drainVault() looped withdraw() in one transaction. Each call was individually valid, so nothing stopped it.",
          balanceBefore: "1900 mWETH in vault (1000 seed + 900 attacker deposit)",
          balanceAfter: "1000 mWETH in vault",
          live: false,
        };
      }
      return {
        status: "reverted",
        title: "Transaction reverted — drain blocked",
        detail:
          "The looped withdrawals pushed the block's cumulative outflow over maxOutflowPerBlock, so check() reverted the ENTIRE transaction — including the withdrawals earlier in the loop.",
        revertReason: "ArbGuardViolation(OUTFLOW_PER_BLOCK)",
        balanceBefore: "1900 mWETH in vault (1000 seed + 900 attacker deposit)",
        balanceAfter: "1900 mWETH in vault",
        live: false,
      };
    }
    if (target === "unguarded") {
      return {
        status: "success",
        title: "Transaction succeeded — price moved",
        detail:
          "pushPriceAndSwap() swapped 1000 mWETH into the 1000/1000 pool and received 500 mUSDC. The pool is now mispriced for everyone else.",
        balanceBefore: "reserves 1000 mWETH / 1000 mUSDC",
        balanceAfter: "reserves 2000 mWETH / 500 mUSDC",
        live: false,
      };
    }
    return {
      status: "reverted",
      title: "Transaction reverted — price push blocked",
      detail:
        "The swap's execution price deviated from the TWAP reference by more than maxPriceDeviationBps, so check() reverted it. The pool price never moved.",
      revertReason: "ArbGuardViolation(PRICE_DEVIATION)",
      balanceBefore: "reserves 1000 mWETH / 1000 mUSDC",
      balanceAfter: "reserves 1000 mWETH / 1000 mUSDC",
      live: false,
    };
  }

  async function runAttack() {
    setLiveError(null);
    setResult(null);
    if (!isDeployed) {
      // No contracts yet: show the proven outcome as an explicit simulation.
      setResult(simulate());
      return;
    }
    if (!isConnected || !publicClient) {
      setLiveError("Connect your wallet first.");
      return;
    }
    const guarded = target === "guarded";
    const vault = (guarded ? CONTRACT_ADDRESSES.guardedVault : CONTRACT_ADDRESSES.unguardedVault) as `0x${string}`;
    const pool = (guarded ? CONTRACT_ADDRESSES.guardedPool : CONTRACT_ADDRESSES.unguardedPool) as `0x${string}`;

    // Balances BEFORE the attack, read live.
    let before: string;
    try {
      if (attack === "drain") {
        const bal = await publicClient.readContract({
          address: CONTRACT_ADDRESSES.mweth,
          abi: TOKEN_ABI,
          functionName: "balanceOf",
          args: [vault],
        });
        before = `${formatEther(bal)} mWETH in vault`;
      } else {
        const [r0, r1] = await Promise.all([
          publicClient.readContract({ address: pool, abi: POOL_ABI, functionName: "reserve0", args: [] }),
          publicClient.readContract({ address: pool, abi: POOL_ABI, functionName: "reserve1", args: [] }),
        ]);
        before = `reserves ${formatEther(r0)} mWETH / ${formatEther(r1)} mUSDC`;
      }
    } catch (err) {
      setLiveError(`Could not read balances before the attack: ${(err as Error).message.slice(0, 200)}`);
      return;
    }

    // Live path: call the Attacker contract. An explicit gas limit is
    // passed so a reverting tx is broadcast on-chain (a wallet's pre-flight
    // simulation would refuse it and no receipt would exist).
    try {
      const hash =
        attack === "drain"
          ? await writeContractAsync({
              address: CONTRACT_ADDRESSES.attacker,
              abi: ATTACKER_ABI,
              functionName: "drainOnly",
              args: [vault, parseEther("10"), 200n],
              gas: 3_000_000n,
            })
          : await writeContractAsync({
              address: CONTRACT_ADDRESSES.attacker,
              abi: ATTACKER_ABI,
              functionName: "pushPriceAndSwap",
              args: [pool, CONTRACT_ADDRESSES.mweth, parseEther("1000")],
              gas: 1_000_000n,
            });
      processedHash.current = null;
      setPendingMeta({ attack, target, vault, pool, before });
      setTxHash(hash);
    } catch (err) {
      // The wallet refused to broadcast (its simulation hit the revert).
      // Decode the reason from the simulation error and show the honest
      // outcome: no on-chain receipt exists, balances did not move.
      const reasonCode = decodeViolationReason(err);
      let after = before;
      try {
        if (attack === "drain") {
          const bal = await publicClient.readContract({
            address: CONTRACT_ADDRESSES.mweth,
            abi: TOKEN_ABI,
            functionName: "balanceOf",
            args: [vault],
          });
          after = `${formatEther(bal)} mWETH in vault`;
        } else {
          const [r0, r1] = await Promise.all([
            publicClient.readContract({ address: pool, abi: POOL_ABI, functionName: "reserve0", args: [] }),
            publicClient.readContract({ address: pool, abi: POOL_ABI, functionName: "reserve1", args: [] }),
          ]);
          after = `reserves ${formatEther(r0)} mWETH / ${formatEther(r1)} mUSDC`;
        }
      } catch {
        // Keep `before` as the after-state if the re-read fails.
      }
      if (guarded && reasonCode !== null) {
        const reasonName = REASON_NAMES[reasonCode];
        setResult({
          status: "reverted",
          title: attack === "drain" ? "Transaction reverted — drain blocked" : "Transaction reverted — price push blocked",
          detail:
            "Your wallet refused to broadcast this transaction because its pre-flight simulation hit the guard's revert — so there is no on-chain receipt. The revert reason below comes from that simulation, and the balances confirm nothing moved.",
          revertReason: `ArbGuardViolation(${reasonName})`,
          balanceBefore: before,
          balanceAfter: after,
          live: true,
        });
        recordBlockedAttempt({
          ts: Date.now(),
          attack: attack === "drain" ? "drain" : "price-push",
          target: "guarded",
          reason: reasonName,
        });
      } else {
        setLiveError(`Transaction failed before broadcast: ${(err as Error).message.slice(0, 300)}`);
      }
    }
  }

  return (
    <div className="space-y-6">
      {!isDeployed && (
        <div className="rounded border border-amber/40 bg-amber/10 p-3 text-sm text-amber">
          <strong>Simulated run.</strong> Contracts are not deployed yet
          (addresses TBD), so this shows the exact outcomes the Foundry fork
          tests prove — labelled as a simulation, with no fake transaction
          hash. Once ArbGuard is live on Arbitrum Sepolia, the same buttons
          send the real attack and display the real receipt.
        </div>
      )}
      {isDeployed && (
        <div className="rounded border border-edge bg-panel p-3 text-sm text-gray-300">
          <strong className="text-white">Live run.</strong> The attack goes
          through the deployed Attacker contract (
          <span className="font-mono text-xs">{CONTRACT_ADDRESSES.attacker}</span>).
          On the guarded target the transaction reverts on-chain with a named{" "}
          <span className="font-mono">ArbGuardViolation</span> reason. A
          blocked attempt is recorded in this browser session and shown on
          the <span className="font-mono">/feed</span> page — it never appears
          as an on-chain event, because a reverted tx leaves none.
        </div>
      )}
      {!isConnected && isDeployed && (
        <p className="text-sm text-gray-400">
          Connect your wallet (top right) to run the attack against the live
          deployment. On local Anvil, connect Anvil account #0.
        </p>
      )}

      <div className="grid gap-4 md:grid-cols-2">
        <div>
          <p className="mb-2 text-sm font-medium">Target vault / pool</p>
          <div className="flex gap-2">
            <ToggleButton
              active={target === "unguarded"}
              onClick={() => setTarget("unguarded")}
              label="Unguarded"
              sub="no check() call"
            />
            <ToggleButton
              active={target === "guarded"}
              onClick={() => setTarget("guarded")}
              label="Guarded"
              sub="check() before withdraw/swap"
            />
          </div>
        </div>
        <div>
          <p className="mb-2 text-sm font-medium">Attack</p>
          <div className="flex gap-2">
            <ToggleButton
              active={attack === "drain"}
              onClick={() => setAttack("drain")}
              label="Drain"
              sub="loop withdraw() in one tx"
            />
            <ToggleButton
              active={attack === "price-push"}
              onClick={() => setAttack("price-push")}
              label="Price push"
              sub="large swap, price moves 40%+"
            />
          </div>
        </div>
      </div>

      <button
        onClick={runAttack}
        disabled={isPending || receiptLoading}
        className="rounded bg-danger px-6 py-2 font-medium text-white disabled:opacity-40"
      >
        {isPending ? "Sending attack…" : receiptLoading ? "Waiting for receipt…" : "▶ Run attack"}
      </button>
      {(liveError || writeError) && (
        <p className="text-sm text-danger">
          Error: {(liveError ?? writeError?.message ?? "").slice(0, 300)}
        </p>
      )}
      {txHash && !result && (
        <p className="break-all font-mono text-sm text-gray-400">
          Tx sent: {txHash} — waiting for receipt…
        </p>
      )}

      {result && (
        <div
          className={`rounded-lg border p-5 ${
            result.status === "reverted"
              ? "border-accent/50 bg-accent/5"
              : "border-danger/50 bg-danger/5"
          }`}
        >
          <p className="mb-1 font-mono text-xs text-gray-500">
            {result.live ? "LIVE RECEIPT" : "SIMULATED RECEIPT — no tx was sent"}
          </p>
          <h3
            className={`text-lg font-bold ${
              result.status === "reverted" ? "text-accent" : "text-danger"
            }`}
          >
            {result.status === "reverted" ? "⛔ " : "✅ "}
            {result.title}
          </h3>
          {result.revertReason && (
            <p className="mt-2 font-mono text-sm text-accent">{result.revertReason}</p>
          )}
          <p className="mt-2 text-sm text-gray-300">{result.detail}</p>
          {result.txHash && (
            <dl className="mt-4 space-y-1 font-mono text-sm">
              <div className="flex gap-2">
                <dt className="text-gray-500">tx hash</dt>
                <dd className="break-all">{result.txHash}</dd>
              </div>
              {result.blockNumber !== undefined && (
                <div className="flex gap-2">
                  <dt className="text-gray-500">block</dt>
                  <dd>{result.blockNumber}</dd>
                </div>
              )}
              {result.txStatus && (
                <div className="flex gap-2">
                  <dt className="text-gray-500">status</dt>
                  <dd>{result.txStatus}</dd>
                </div>
              )}
            </dl>
          )}
          <div className="mt-4 grid grid-cols-2 gap-4 font-mono text-sm">
            <div>
              <p className="text-gray-500">Before</p>
              <p>{result.balanceBefore}</p>
            </div>
            <div>
              <p className="text-gray-500">After</p>
              <p>{result.balanceAfter}</p>
            </div>
          </div>
          <p className="mt-4 text-xs text-gray-500">
            Note: a reverted transaction leaves no persistent on-chain event —
            the EVM rolls everything back. The block is visible here in the
            revert reason and in the balance that did not move.
          </p>
        </div>
      )}
    </div>
  );
}

function ToggleButton({
  active,
  onClick,
  label,
  sub,
}: {
  active: boolean;
  onClick: () => void;
  label: string;
  sub: string;
}) {
  return (
    <button
      onClick={onClick}
      className={`flex-1 rounded border px-3 py-2 text-left ${
        active ? "border-accent bg-accent/10" : "border-edge bg-panel"
      }`}
    >
      <span className="block font-medium">{label}</span>
      <span className="block text-xs text-gray-500">{sub}</span>
    </button>
  );
}
