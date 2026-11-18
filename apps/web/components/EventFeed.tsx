"use client";

import { useCallback, useEffect, useState } from "react";
import { formatEther, parseEventLogs } from "viem";
import { usePublicClient } from "wagmi";
import {
  ACTION_KIND_NAMES,
  ARB_GUARD_ABI,
  BLOCKED_ATTEMPTS_KEY,
  BLOCKED_ATTEMPT_EVENT,
  CONTRACT_ADDRESSES,
  DEPLOY_FROM_BLOCK,
  POOL_ABI,
  REASON_NAMES,
  TOKEN_ABI,
  isDeployed,
  type BlockedAttempt,
} from "@/lib/contracts";

type FeedEvent = {
  name: string;
  txHash: string;
  blockNumber: number;
  summary: string;
};

function formatArgs(name: string, args: Record<string, unknown>): string {
  const short = (v: unknown) => (typeof v === "string" ? v : String(v));
  switch (name) {
    case "PolicyRegistered":
      return `policyId ${short(args.policyId)} — protocol ${short(args.protocol)}, keeper ${short(args.keeper)}`;
    case "PolicyUpdated":
      return `policyId ${short(args.policyId)} — protocol ${short(args.protocol)}`;
    case "PolicyEnabled":
      return `policyId ${short(args.policyId)} — enabled: ${short(args.enabled)}`;
    case "CheckPassed": {
      const kind = typeof args.kind === "number" ? ACTION_KIND_NAMES[args.kind] ?? String(args.kind) : short(args.kind);
      return `policyId ${short(args.policyId)} — protocol ${short(args.protocol)}, ${kind} ${formatEther(
        (args.amountOut as bigint) ?? 0n,
      )} of token ${short(args.token)} passed`;
    }
    case "BreakerTripped": {
      const evidence = typeof args.evidence === "string" ? args.evidence : "";
      return `policyId ${short(args.policyId)} — tripped by ${short(args.tripper)}, paused until ${short(
        args.pausedUntil,
      )}${evidence ? `, evidence ${evidence.slice(0, 66)}${evidence.length > 66 ? "…" : ""}` : ""}`;
    }
    case "BreakerReset":
      return `policyId ${short(args.policyId)} — breaker reset`;
    default:
      return Object.entries(args)
        .map(([k, v]) => `${k}: ${typeof v === "bigint" ? v.toString() : short(v)}`)
        .join(", ");
  }
}

function readBlockedAttempts(): BlockedAttempt[] {
  try {
    const raw = localStorage.getItem(BLOCKED_ATTEMPTS_KEY);
    return raw ? (JSON.parse(raw) as BlockedAttempt[]) : [];
  } catch {
    return [];
  }
}

/**
 * Live event feed. Reads PolicyRegistered / CheckPassed / BreakerTripped /
 * BreakerReset (and PolicyUpdated / PolicyEnabled) from the deployed
 * ArbGuard contract using the real ARB_GUARD_ABI from lib/contracts.ts.
 *
 * Honest limitation (see docs/ARCHITECTURE.md): a reverted transaction
 * leaves no persistent event, so blocked attacks do NOT appear in this
 * feed — they are visible in the simulator's failed receipt and revert
 * reason. This feed shows real, persistent events only, plus a
 * "Blocked attempts (this session)" section fed by the simulator's
 * session store (localStorage + `arbguard:blocked-attempt` event).
 *
 * Until contracts are deployed, the feed shows a graceful empty state.
 */
export function EventFeed() {
  const publicClient = usePublicClient();
  const [events, setEvents] = useState<FeedEvent[]>([]);
  const [loading, setLoading] = useState(false);
  const [fetchError, setFetchError] = useState<string | null>(null);
  const [blocked, setBlocked] = useState<BlockedAttempt[]>([]);
  const [preview, setPreview] = useState<string | null>(null);
  const [previewLoading, setPreviewLoading] = useState<string | null>(null);

  useEffect(() => {
    setBlocked(readBlockedAttempts());
    const onAttempt = (e: Event) => {
      const detail = (e as CustomEvent<BlockedAttempt>).detail;
      if (detail) setBlocked((prev) => [...prev, detail]);
    };
    const onStorage = () => setBlocked(readBlockedAttempts());
    window.addEventListener(BLOCKED_ATTEMPT_EVENT, onAttempt);
    window.addEventListener("storage", onStorage);
    return () => {
      window.removeEventListener(BLOCKED_ATTEMPT_EVENT, onAttempt);
      window.removeEventListener("storage", onStorage);
    };
  }, []);

  useEffect(() => {
    if (!isDeployed || !publicClient) return;
    let cancelled = false;
    setLoading(true);
    publicClient
      .getLogs({
        address: CONTRACT_ADDRESSES.arbGuard,
        fromBlock: DEPLOY_FROM_BLOCK,
      })
      .then((rawLogs) => {
        if (cancelled) return;
        // viem 2.30's getLogs only accepts `abi` together with `event`/
        // `events`, and with `abi` alone it returns raw, undecodable logs —
        // so fetch the address's logs raw and decode them against the real
        // ARB_GUARD_ABI (strict: false so an unmatched log can't break
        // the whole feed).
        const logs = parseEventLogs({ abi: ARB_GUARD_ABI, logs: rawLogs, strict: false }).filter(
          (log) => (log as { eventName?: string }).eventName !== undefined,
        );
        setEvents(
          logs
            .slice(-50)
            .reverse()
            .map((log) => {
              const name = (log as { eventName?: string }).eventName ?? "Unknown";
              const args = ((log as { args?: Record<string, unknown> }).args ?? {}) as Record<string, unknown>;
              return {
                name,
                txHash: log.transactionHash,
                blockNumber: Number(log.blockNumber),
                summary: formatArgs(name, args),
              };
            }),
        );
      })
      .catch((err: Error) => {
        if (!cancelled) setFetchError(err.message.slice(0, 200));
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [publicClient]);

  const runPreview = useCallback(
    async (which: "drain" | "swap") => {
      if (!publicClient) return;
      setPreviewLoading(which);
      setPreview(null);
      try {
        if (which === "drain") {
          // Drain 900 mWETH from the guarded vault: kind WITHDRAW, token
          // mWETH, amountOut 900, tvl = the vault's live mWETH balance.
          const tvl = await publicClient.readContract({
            address: CONTRACT_ADDRESSES.mweth,
            abi: TOKEN_ABI,
            functionName: "balanceOf",
            args: [CONTRACT_ADDRESSES.guardedVault],
          });
          const [ok, reason] = await publicClient.readContract({
            address: CONTRACT_ADDRESSES.arbGuard,
            abi: ARB_GUARD_ABI,
            functionName: "simulateCheck",
            args: [
              CONTRACT_ADDRESSES.guardedVault,
              {
                kind: 0,
                token: CONTRACT_ADDRESSES.mweth,
                amountOut: 900n * 10n ** 18n,
                amountIn: 0n,
                price: 0n,
                twapPrice: 0n,
                tvl,
              },
            ],
          });
          setPreview(
            `Drain 900 mWETH from guarded vault (TVL ${formatEther(tvl)} mWETH) → ok: ${ok}, reason: ${REASON_NAMES[reason]}`,
          );
        } else {
          // Swap 1000 mWETH on the guarded pool: kind SWAP, token = tokenOut
          // (mUSDC), amountOut from getAmountOut, price = execution price,
          // twapPrice = the pool's stored reference, tvl = reserveOut.
          const [amountOut, twapPrice, reserveOut] = await Promise.all([
            publicClient.readContract({
              address: CONTRACT_ADDRESSES.guardedPool,
              abi: POOL_ABI,
              functionName: "getAmountOut",
              args: [CONTRACT_ADDRESSES.mweth, 1000n * 10n ** 18n],
            }),
            publicClient.readContract({
              address: CONTRACT_ADDRESSES.guardedPool,
              abi: POOL_ABI,
              functionName: "lastPrice01",
              args: [],
            }),
            publicClient.readContract({
              address: CONTRACT_ADDRESSES.guardedPool,
              abi: POOL_ABI,
              functionName: "reserve1",
              args: [],
            }),
          ]);
          const price = (amountOut * 10n ** 18n) / (1000n * 10n ** 18n);
          const [ok, reason] = await publicClient.readContract({
            address: CONTRACT_ADDRESSES.arbGuard,
            abi: ARB_GUARD_ABI,
            functionName: "simulateCheck",
            args: [
              CONTRACT_ADDRESSES.guardedPool,
              {
                kind: 2,
                token: CONTRACT_ADDRESSES.musdc,
                amountOut,
                amountIn: 1000n * 10n ** 18n,
                price,
                twapPrice,
                tvl: reserveOut,
              },
            ],
          });
          setPreview(
            `Swap 1000 mWETH on guarded pool (→ ${formatEther(amountOut)} mUSDC, execution price ${formatEther(price)}, TWAP ${formatEther(twapPrice)}) → ok: ${ok}, reason: ${REASON_NAMES[reason]}`,
          );
        }
      } catch (err) {
        setPreview(`Preview failed: ${(err as Error).message.slice(0, 200)}`);
      } finally {
        setPreviewLoading(null);
      }
    },
    [publicClient],
  );

  if (!isDeployed) {
    return (
      <div className="space-y-6">
        <div className="rounded-lg border border-edge bg-panel p-8 text-center">
          <p className="text-2xl">📡</p>
          <h3 className="mt-2 text-lg font-bold">No events yet</h3>
          <p className="mx-auto mt-2 max-w-md text-sm text-gray-400">
            ArbGuard is not deployed yet — the contract addresses are TBD, so
            there is nothing to listen to. Once ArbGuard is live on Arbitrum
            Sepolia, this page streams <span className="font-mono">PolicyRegistered</span>,{" "}
            <span className="font-mono">CheckPassed</span>,{" "}
            <span className="font-mono">BreakerTripped</span> and{" "}
            <span className="font-mono">BreakerReset</span> events here.
          </p>
          <p className="mx-auto mt-3 max-w-md text-xs text-gray-500">
            Blocked attacks will not appear here even after deployment: a
            reverted transaction leaves no persistent event on chain. Blocked
            attempts are shown in the attack simulator&apos;s failed receipt
            instead.
          </p>
        </div>
        <BlockedAttemptsSection blocked={blocked} />
      </div>
    );
  }

  return (
    <div className="space-y-8">
      <section className="rounded-lg border border-edge bg-panel p-5">
        <h2 className="text-lg font-bold">Preview with simulateCheck</h2>
        <p className="mt-1 text-sm text-gray-400">
          A read-only preview — <span className="font-mono">simulateCheck</span> runs the
          exact invariant logic without sending a transaction or changing state.
        </p>
        <div className="mt-3 flex flex-wrap gap-2">
          <button
            onClick={() => runPreview("drain")}
            disabled={previewLoading !== null}
            className="rounded bg-accent px-4 py-2 text-sm font-medium text-black disabled:opacity-40"
          >
            {previewLoading === "drain" ? "Checking…" : "Preview: drain 900 mWETH (guarded vault)"}
          </button>
          <button
            onClick={() => runPreview("swap")}
            disabled={previewLoading !== null}
            className="rounded bg-accent px-4 py-2 text-sm font-medium text-black disabled:opacity-40"
          >
            {previewLoading === "swap" ? "Checking…" : "Preview: swap 1000 mWETH (guarded pool)"}
          </button>
        </div>
        {preview && <p className="mt-3 font-mono text-sm text-accent">{preview}</p>}
      </section>

      <BlockedAttemptsSection blocked={blocked} />

      <section>
        <h2 className="mb-3 text-lg font-bold">On-chain events</h2>
        {loading && <p className="text-gray-400">Loading events…</p>}
        {fetchError && <p className="text-danger">Failed to load events: {fetchError}</p>}
        {!loading && !fetchError && events.length === 0 && (
          <div className="rounded-lg border border-edge bg-panel p-8 text-center">
            <h3 className="text-lg font-bold">No events found</h3>
            <p className="mt-2 text-sm text-gray-400">
              The contract is deployed but has emitted no ArbGuard events yet.
              Register a policy or run a guarded action to see events here.
            </p>
          </div>
        )}
        <ul className="space-y-3">
          {events.map((e) => (
            <li key={e.txHash + e.blockNumber + e.name} className="rounded-lg border border-edge bg-panel p-4">
              <div className="flex items-baseline justify-between">
                <span className="font-mono font-bold text-accent">{e.name}</span>
                <span className="font-mono text-xs text-gray-500">block {e.blockNumber}</span>
              </div>
              <p className="mt-1 break-words text-sm text-gray-300">{e.summary}</p>
              <p className="mt-1 break-all font-mono text-xs text-gray-500">{e.txHash}</p>
            </li>
          ))}
        </ul>
      </section>
    </div>
  );
}

function BlockedAttemptsSection({ blocked }: { blocked: BlockedAttempt[] }) {
  return (
    <section className="rounded-lg border border-edge bg-panel p-5">
      <h2 className="text-lg font-bold">Blocked attempts (this session)</h2>
      <p className="mt-1 text-sm text-gray-400">
        Blocked attacks never appear as on-chain events — a reverted
        transaction leaves no event. These are the attempts the simulator
        recorded in this browser session (localStorage), with the revert
        reason from the failed receipt.
      </p>
      {blocked.length === 0 ? (
        <p className="mt-3 text-sm text-gray-500">
          None yet — run a guarded attack in the simulator and watch it get blocked.
        </p>
      ) : (
        <ul className="mt-3 space-y-2">
          {[...blocked].reverse().map((b, i) => (
            <li key={`${b.ts}-${i}`} className="rounded border border-edge bg-ink p-3 font-mono text-sm">
              <span className="text-accent">{b.reason}</span>
              <span className="text-gray-300">
                {" "}
                — {b.attack} on {b.target} · {new Date(b.ts).toLocaleTimeString()}
              </span>
              {b.txHash && <span className="block break-all text-xs text-gray-500">{b.txHash}</span>}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
