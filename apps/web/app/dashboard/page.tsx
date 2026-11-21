"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { createPublicClient, decodeErrorResult, formatUnits, http, parseEventLogs } from "viem";
import { arbitrumSepolia } from "viem/chains";
import {
  ACTION_KIND_NAMES,
  ARB_GUARD_ABI,
  BLOCKED_ATTEMPTS_KEY,
  BLOCKED_ATTEMPT_EVENT,
  CHAIN_ID,
  CONTRACT_ADDRESSES,
  DEPLOY_FROM_BLOCK,
  POOL_ABI,
  RPC_URL,
  TOKEN_ABI,
  VAULT_ABI,
  ZERO_ADDRESS,
  isDeployed,
  type BlockedAttempt,
} from "@/lib/contracts";

/**
 * Live dashboard — read-only view of the Sepolia deployment (/dashboard).
 *
 * Every number comes from a live viem read against NEXT_PUBLIC_RPC_URL on
 * chain 421614 (30-second poll). No hard-coded balances, caps, modes or
 * prices. See docs/PHASE3-SPEC.md §2.
 *
 * DEPLOYED-BUILD NOTE (verified live, 20 Nov 2026): the Sepolia ArbGuard
 * (deployed ~16:02 WAT) predates the current contracts/src/ArbGuard.sol.
 * Its Policy struct has 9 fields (no usdDenominated / minHealthFactorBps /
 * maxReserveDrainBps) and its Action has 7 fields (kind, token, tokenIn,
 * amountOut, amountIn, price, tvl — no twapPrice, no healthFactorAfter /
 * availableLiquidity). Proof: getPolicy(0) returns 288 bytes (9 words) with
 * exactly the spec §2.5 values, and the deployed selectors match the
 * 9-field Policy / 7-field Action shapes. lib/contracts.ts is regenerated
 * from the CURRENT source (12-field Policy), so getPolicy decoded with that
 * ABI fails on the live guard. The dashboard therefore reads policies with
 * the deployment-accurate fragment below. If the guard is redeployed from
 * current source, delete the fragment and read getPolicy with
 * ARB_GUARD_ABI. All other reads below (mode, keepers, price config,
 * oracle config, outflow windows, events) use the regenerated ABI and were
 * verified live against the deployment.
 */
const DEPLOYED_GUARD_POLICY_ABI = [
  {
    type: "function",
    name: "getPolicy",
    inputs: [{ name: "policyId", type: "uint256", internalType: "uint256" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        internalType: "struct Policy",
        components: [
          { name: "maxOutflowPerBlock", type: "uint256", internalType: "uint256" },
          { name: "maxOutflowPerHour", type: "uint256", internalType: "uint256" },
          { name: "maxOutflowPerDay", type: "uint256", internalType: "uint256" },
          { name: "maxSingleShareBps", type: "uint16", internalType: "uint16" },
          { name: "maxPriceDeviationBps", type: "uint16", internalType: "uint16" },
          { name: "throttleBps", type: "uint16", internalType: "uint16" },
          { name: "cooldownSeconds", type: "uint32", internalType: "uint32" },
          { name: "policyTimelockSeconds", type: "uint32", internalType: "uint32" },
          { name: "enabled", type: "bool", internalType: "bool" },
        ],
      },
    ],
    stateMutability: "view",
  },
] as const;

/** Minimal Chainlink AggregatorV3 read interface. */
const FEED_ABI = [
  {
    type: "function",
    name: "latestRoundData",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "decimals",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
    stateMutability: "view",
  },
] as const;

const MODE_NAMES = ["NORMAL", "THROTTLED", "PAUSED"] as const;
const ARBISCAN = "https://sepolia.arbiscan.io";
const REFRESH_MS = 30_000;
const LOG_CHUNK = 10_000n; // getLogs block-range chunk (public-RPC discipline)

const sepoliaClient = createPublicClient({
  chain: arbitrumSepolia,
  transport: http(RPC_URL),
});

type Policy9 = {
  maxOutflowPerBlock: bigint;
  maxOutflowPerHour: bigint;
  maxOutflowPerDay: bigint;
  maxSingleShareBps: number;
  maxPriceDeviationBps: number;
  throttleBps: number;
  cooldownSeconds: number;
  policyTimelockSeconds: number;
  enabled: boolean;
};

type PriceConfig = {
  twapSeconds: number;
  maxOracleDeviationBps: number;
  chainlinkStaleAfter: number;
  sequencerFeed: string;
};

type OracleConfig = {
  chainlinkFeed: string;
  uniswapPool: string;
  feedDecimals: number;
  tokenDecimals: number;
};

type Outflow = {
  block: bigint;
  blockId: bigint;
  hour: bigint;
  hourId: bigint;
  day: bigint;
  dayId: bigint;
};

type PolicyData = {
  policy: Policy9 | null;
  mode: number | null;
  keepers: string[];
  price: PriceConfig | null;
  pausedUntil: bigint;
  throttleUntil: bigint;
  outflow: Outflow;
  oracleWeth: OracleConfig | null;
  oracleUsdc: OracleConfig | null;
};

type DashEvent = {
  name: string;
  policyId: string;
  blockNumber: number;
  txHash: string;
  summary: string;
  time: string | null;
};

type OracleState = {
  feed: string;
  answer: bigint | null;
  feedDecimals: number;
  updatedAt: bigint | null;
  refPrice: bigint | null;
  refSource: string | null;
  refError: string | null;
};

type DashboardData = {
  owner: string | null;
  policies: [PolicyData, PolicyData];
  balances: Record<string, bigint>;
  decimals: { mweth: number; musdc: number };
  shares: { attackerGv: bigint; totalGv: bigint; attackerUv: bigint; totalUv: bigint };
  reserves: { gp0: bigint; gp1: bigint; up0: bigint; up1: bigint };
  oracle: OracleState;
  latestBlock: bigint;
};

const emptyPolicy = (): PolicyData => ({
  policy: null,
  mode: null,
  keepers: [],
  price: null,
  pausedUntil: 0n,
  throttleUntil: 0n,
  outflow: { block: 0n, blockId: 0n, hour: 0n, hourId: 0n, day: 0n, dayId: 0n },
  oracleWeth: null,
  oracleUsdc: null,
});

function shortAddr(a: string): string {
  return a.length > 13 ? `${a.slice(0, 6)}…${a.slice(-4)}` : a;
}

function formatTs(unixSeconds: bigint | number): string {
  const n = Number(unixSeconds);
  if (!n) return "—";
  return new Date(n * 1000).toLocaleString();
}

function formatUntil(unixSeconds: bigint): string {
  const n = Number(unixSeconds);
  if (!n) return "—";
  const now = Math.floor(Date.now() / 1000);
  const when = new Date(n * 1000).toLocaleString();
  return n > now ? `${when} (in ${Math.round((n - now) / 60)} min)` : `${when} (expired)`;
}

function fmtAmount(v: bigint | null | undefined, decimals: number): string {
  if (v === null || v === undefined) return "—";
  return formatUnits(v, decimals);
}

function effCap(cap: bigint, mode: number | null, throttleBps: number): bigint {
  if (mode !== 1) return cap;
  return (cap * BigInt(throttleBps)) / 10_000n;
}

function readBlockedAttempts(): BlockedAttempt[] {
  try {
    const raw = localStorage.getItem(BLOCKED_ATTEMPTS_KEY);
    return raw ? (JSON.parse(raw) as BlockedAttempt[]) : [];
  } catch {
    return [];
  }
}

function eventSummary(name: string, args: Record<string, unknown>): string {
  const s = (v: unknown) => (typeof v === "string" ? v : String(v));
  switch (name) {
    case "PolicyRegistered":
      return `protocol ${shortAddr(s(args.protocol))}`;
    case "KeeperAdded":
    case "KeeperRemoved":
      return `keeper ${shortAddr(s(args.keeper))}`;
    case "CheckPassed": {
      const kind =
        typeof args.kind === "number" ? ACTION_KIND_NAMES[args.kind] ?? String(args.kind) : s(args.kind);
      return `${kind} ${formatUnits((args.amountOut as bigint) ?? 0n, 18)} of ${shortAddr(s(args.token))}`;
    }
    case "BreakerTripped":
      return `by ${shortAddr(s(args.tripper))}, paused until ${formatTs((args.pausedUntil as bigint) ?? 0n)}`;
    case "ThrottleSet":
      return `by ${shortAddr(s(args.tripper))}, throttled until ${formatTs((args.throttleUntil as bigint) ?? 0n)}`;
    case "PolicyUpdateProposed":
    case "OracleConfigUpdateProposed":
      return `executable at ${formatTs((args.executableAt as bigint) ?? 0n)}`;
    default:
      return Object.entries(args)
        .map(([k, v]) => `${k}: ${typeof v === "bigint" ? v.toString() : s(v)}`)
        .join(", ");
  }
}

export default function DashboardPage() {
  const [data, setData] = useState<DashboardData | null>(null);
  const [events, setEvents] = useState<DashEvent[]>([]);
  const [eventsNote, setEventsNote] = useState<string | null>(null);
  const [blocked, setBlocked] = useState<BlockedAttempt[]>([]);
  const [loading, setLoading] = useState(true);
  const [fetchError, setFetchError] = useState<string | null>(null);
  const [lastRefresh, setLastRefresh] = useState<Date | null>(null);
  const fetchingRef = useRef(false);
  const blockTimeCache = useRef(new Map<number, string>());

  const fetchAll = useCallback(async () => {
    if (!isDeployed || fetchingRef.current) return;
    fetchingRef.current = true;
    try {
      const g = CONTRACT_ADDRESSES.arbGuard;
      const latestBlock = await sepoliaClient.getBlockNumber();

      const mc = (await sepoliaClient.multicall({
        contracts: [
          { address: g, abi: ARB_GUARD_ABI, functionName: "owner" },
          // Policy 0 (GuardedVault) — getPolicy via the deployed 9-field shape.
          { address: g, abi: DEPLOYED_GUARD_POLICY_ABI, functionName: "getPolicy", args: [0n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "getMode", args: [0n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "getKeepers", args: [0n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "getPriceConfig", args: [0n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "pausedUntil", args: [0n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "throttleUntil", args: [0n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "outflowInBlock", args: [0n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "outflowBlock", args: [0n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "outflowInHour", args: [0n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "outflowHour", args: [0n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "outflowInDay", args: [0n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "outflowDay", args: [0n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "getOracleConfig", args: [0n, CONTRACT_ADDRESSES.mweth] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "getOracleConfig", args: [0n, CONTRACT_ADDRESSES.musdc] },
          // Policy 1 (GuardedPool).
          { address: g, abi: DEPLOYED_GUARD_POLICY_ABI, functionName: "getPolicy", args: [1n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "getMode", args: [1n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "getKeepers", args: [1n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "getPriceConfig", args: [1n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "pausedUntil", args: [1n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "throttleUntil", args: [1n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "outflowInBlock", args: [1n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "outflowBlock", args: [1n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "outflowInHour", args: [1n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "outflowHour", args: [1n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "outflowInDay", args: [1n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "outflowDay", args: [1n] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "getOracleConfig", args: [1n, CONTRACT_ADDRESSES.mweth] },
          { address: g, abi: ARB_GUARD_ABI, functionName: "getOracleConfig", args: [1n, CONTRACT_ADDRESSES.musdc] },
          // Balances.
          { address: CONTRACT_ADDRESSES.mweth, abi: TOKEN_ABI, functionName: "decimals" },
          { address: CONTRACT_ADDRESSES.musdc, abi: TOKEN_ABI, functionName: "decimals" },
          { address: CONTRACT_ADDRESSES.mweth, abi: TOKEN_ABI, functionName: "balanceOf", args: [CONTRACT_ADDRESSES.guardedVault] },
          { address: CONTRACT_ADDRESSES.musdc, abi: TOKEN_ABI, functionName: "balanceOf", args: [CONTRACT_ADDRESSES.guardedVault] },
          { address: CONTRACT_ADDRESSES.mweth, abi: TOKEN_ABI, functionName: "balanceOf", args: [CONTRACT_ADDRESSES.unguardedVault] },
          { address: CONTRACT_ADDRESSES.musdc, abi: TOKEN_ABI, functionName: "balanceOf", args: [CONTRACT_ADDRESSES.unguardedVault] },
          { address: CONTRACT_ADDRESSES.mweth, abi: TOKEN_ABI, functionName: "balanceOf", args: [CONTRACT_ADDRESSES.guardedPool] },
          { address: CONTRACT_ADDRESSES.musdc, abi: TOKEN_ABI, functionName: "balanceOf", args: [CONTRACT_ADDRESSES.guardedPool] },
          { address: CONTRACT_ADDRESSES.mweth, abi: TOKEN_ABI, functionName: "balanceOf", args: [CONTRACT_ADDRESSES.unguardedPool] },
          { address: CONTRACT_ADDRESSES.musdc, abi: TOKEN_ABI, functionName: "balanceOf", args: [CONTRACT_ADDRESSES.unguardedPool] },
          { address: CONTRACT_ADDRESSES.mweth, abi: TOKEN_ABI, functionName: "balanceOf", args: [CONTRACT_ADDRESSES.attacker] },
          { address: CONTRACT_ADDRESSES.musdc, abi: TOKEN_ABI, functionName: "balanceOf", args: [CONTRACT_ADDRESSES.attacker] },
          // Vault shares + pool reserves.
          { address: CONTRACT_ADDRESSES.guardedVault, abi: VAULT_ABI, functionName: "shares", args: [CONTRACT_ADDRESSES.attacker] },
          { address: CONTRACT_ADDRESSES.guardedVault, abi: VAULT_ABI, functionName: "totalShares" },
          { address: CONTRACT_ADDRESSES.unguardedVault, abi: VAULT_ABI, functionName: "shares", args: [CONTRACT_ADDRESSES.attacker] },
          { address: CONTRACT_ADDRESSES.unguardedVault, abi: VAULT_ABI, functionName: "totalShares" },
          { address: CONTRACT_ADDRESSES.guardedPool, abi: POOL_ABI, functionName: "reserve0" },
          { address: CONTRACT_ADDRESSES.guardedPool, abi: POOL_ABI, functionName: "reserve1" },
          { address: CONTRACT_ADDRESSES.unguardedPool, abi: POOL_ABI, functionName: "reserve0" },
          { address: CONTRACT_ADDRESSES.unguardedPool, abi: POOL_ABI, functionName: "reserve1" },
        ],
      })) as { status: string; result?: unknown; error?: Error }[];
      const ok = <T,>(i: number): T | null =>
        mc[i].status === "success" ? (mc[i].result as T) : null;

      const buildPolicy = (base: number): PolicyData => {
        const p = emptyPolicy();
        p.policy = ok<Policy9>(base);
        p.mode = ok<number>(base + 1);
        p.keepers = ok<string[]>(base + 2) ?? [];
        p.price = ok<PriceConfig>(base + 3);
        p.pausedUntil = ok<bigint>(base + 4) ?? 0n;
        p.throttleUntil = ok<bigint>(base + 5) ?? 0n;
        p.outflow = {
          block: ok<bigint>(base + 6) ?? 0n,
          blockId: ok<bigint>(base + 7) ?? 0n,
          hour: ok<bigint>(base + 8) ?? 0n,
          hourId: ok<bigint>(base + 9) ?? 0n,
          day: ok<bigint>(base + 10) ?? 0n,
          dayId: ok<bigint>(base + 11) ?? 0n,
        };
        p.oracleWeth = ok<OracleConfig>(base + 12);
        p.oracleUsdc = ok<OracleConfig>(base + 13);
        return p;
      };

      const policies: [PolicyData, PolicyData] = [buildPolicy(1), buildPolicy(15)];
      const mwethDec = ok<number>(29) ?? 18;
      const musdcDec = ok<number>(30) ?? 18;
      const balances: Record<string, bigint> = {
        gvWeth: ok<bigint>(31) ?? 0n,
        gvUsdc: ok<bigint>(32) ?? 0n,
        uvWeth: ok<bigint>(33) ?? 0n,
        uvUsdc: ok<bigint>(34) ?? 0n,
        gpWeth: ok<bigint>(35) ?? 0n,
        gpUsdc: ok<bigint>(36) ?? 0n,
        upWeth: ok<bigint>(37) ?? 0n,
        upUsdc: ok<bigint>(38) ?? 0n,
        attWeth: ok<bigint>(39) ?? 0n,
        attUsdc: ok<bigint>(40) ?? 0n,
      };

      // Oracle panel: live feed state + live getReferencePrice result.
      const feedAddr = policies[1].oracleWeth?.chainlinkFeed ?? ZERO_ADDRESS;
      let oracle: OracleState = {
        feed: feedAddr,
        answer: null,
        feedDecimals: policies[1].oracleWeth?.feedDecimals ?? 8,
        updatedAt: null,
        refPrice: null,
        refSource: null,
        refError: null,
      };
      if (feedAddr !== ZERO_ADDRESS) {
        try {
          const [round] = await Promise.all([
            sepoliaClient.readContract({
              address: feedAddr as `0x${string}`,
              abi: FEED_ABI,
              functionName: "latestRoundData",
            }),
          ]);
          oracle = { ...oracle, answer: round[1] as bigint, updatedAt: round[3] as bigint };
          try {
            const dec = await sepoliaClient.readContract({
              address: feedAddr as `0x${string}`,
              abi: FEED_ABI,
              functionName: "decimals",
            });
            oracle = { ...oracle, feedDecimals: dec };
          } catch {
            /* keep the configured decimals */
          }
        } catch (e) {
          oracle = { ...oracle, refError: `feed read failed: ${(e as Error).message.slice(0, 120)}` };
        }
      }
      try {
        const [price, source] = await sepoliaClient.readContract({
          address: g,
          abi: ARB_GUARD_ABI,
          functionName: "getReferencePrice",
          args: [1n, CONTRACT_ADDRESSES.mweth, CONTRACT_ADDRESSES.musdc],
        });
        oracle = { ...oracle, refPrice: price, refSource: source };
      } catch (e) {
        let reason = (e as Error).message.slice(0, 200);
        const raw = (e as { cause?: { data?: `0x${string}` } }).cause?.data;
        if (raw) {
          try {
            const d = decodeErrorResult({ abi: ARB_GUARD_ABI, data: raw });
            reason = `${d.errorName}(${d.args?.join(", ")})`;
          } catch {
            /* keep the raw message */
          }
        }
        oracle = { ...oracle, refError: reason };
      }

      // Recent events, chunked from the deploy block.
      let newEvents: DashEvent[] = [];
      let note: string | null = null;
      if (typeof DEPLOY_FROM_BLOCK === "bigint") {
        try {
          const rawLogs: unknown[] = [];
          for (let from = DEPLOY_FROM_BLOCK; from <= latestBlock; from += LOG_CHUNK) {
            const to = from + LOG_CHUNK - 1n > latestBlock ? latestBlock : from + LOG_CHUNK - 1n;
            const chunk = await sepoliaClient.getLogs({ address: g, fromBlock: from, toBlock: to });
            rawLogs.push(...chunk);
          }
          const decoded = parseEventLogs({
            abi: ARB_GUARD_ABI,
            logs: rawLogs as never,
            strict: false,
          }).filter((l) => (l as { eventName?: string }).eventName !== undefined);
          const last20 = decoded.slice(-20).reverse();
          const missingBlocks = [...new Set(last20.map((l) => Number(l.blockNumber)))].filter(
            (b) => !blockTimeCache.current.has(b),
          );
          if (missingBlocks.length > 0) {
            const blocks = await Promise.all(
              missingBlocks.map((b) => sepoliaClient.getBlock({ blockNumber: BigInt(b) })),
            );
            for (const b of blocks) {
              blockTimeCache.current.set(Number(b.number), new Date(Number(b.timestamp) * 1000).toLocaleString());
            }
          }
          newEvents = last20.map((log) => {
            const name = (log as { eventName?: string }).eventName ?? "Unknown";
            const args = ((log as { args?: Record<string, unknown> }).args ?? {}) as Record<string, unknown>;
            return {
              name,
              policyId: args.policyId !== undefined ? String(args.policyId) : "—",
              blockNumber: Number(log.blockNumber),
              txHash: log.transactionHash,
              summary: eventSummary(name, args),
              time: blockTimeCache.current.get(Number(log.blockNumber)) ?? null,
            };
          });
        } catch (e) {
          note = `Event scan failed: ${(e as Error).message.slice(0, 160)}`;
        }
      } else {
        note = "NEXT_PUBLIC_DEPLOY_BLOCK is not set — the event list cannot scan. Set it to the deployment block.";
      }

      setData({
        owner: ok<string>(0),
        policies,
        balances,
        decimals: { mweth: mwethDec, musdc: musdcDec },
        shares: {
          attackerGv: ok<bigint>(41) ?? 0n,
          totalGv: ok<bigint>(42) ?? 0n,
          attackerUv: ok<bigint>(43) ?? 0n,
          totalUv: ok<bigint>(44) ?? 0n,
        },
        reserves: {
          gp0: ok<bigint>(45) ?? 0n,
          gp1: ok<bigint>(46) ?? 0n,
          up0: ok<bigint>(47) ?? 0n,
          up1: ok<bigint>(48) ?? 0n,
        },
        oracle,
        latestBlock,
      });
      setEvents(newEvents);
      setEventsNote(note);
      setFetchError(null);
      setLastRefresh(new Date());
    } catch (e) {
      setFetchError((e as Error).message.slice(0, 300));
    } finally {
      setLoading(false);
      fetchingRef.current = false;
    }
  }, []);

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
    if (!isDeployed) {
      setLoading(false);
      return;
    }
    fetchAll();
    const id = setInterval(fetchAll, REFRESH_MS);
    return () => clearInterval(id);
  }, [fetchAll]);

  if (!isDeployed) {
    const allVars: [string, string][] = [
      ["NEXT_PUBLIC_ARB_GUARD_ADDRESS", CONTRACT_ADDRESSES.arbGuard],
      ["NEXT_PUBLIC_GUARDED_VAULT_ADDRESS", CONTRACT_ADDRESSES.guardedVault],
      ["NEXT_PUBLIC_UNGUARDED_VAULT_ADDRESS", CONTRACT_ADDRESSES.unguardedVault],
      ["NEXT_PUBLIC_GUARDED_POOL_ADDRESS", CONTRACT_ADDRESSES.guardedPool],
      ["NEXT_PUBLIC_UNGUARDED_POOL_ADDRESS", CONTRACT_ADDRESSES.unguardedPool],
      ["NEXT_PUBLIC_ATTACKER_ADDRESS", CONTRACT_ADDRESSES.attacker],
      ["NEXT_PUBLIC_MWETH_ADDRESS", CONTRACT_ADDRESSES.mweth],
      ["NEXT_PUBLIC_MUSDC_ADDRESS", CONTRACT_ADDRESSES.musdc],
    ];
    const missing = allVars.filter(([, v]) => v === ZERO_ADDRESS);
    return (
      <div className="space-y-6">
        <h1 className="text-3xl font-bold">Live dashboard</h1>
        <div className="rounded-lg border border-amber/40 bg-amber/10 p-5">
          <p className="font-bold text-amber">Not deployed — the dashboard has no live deployment to read.</p>
          <p className="mt-2 text-sm text-gray-300">
            Set the missing env vars in <code className="font-mono">apps/web/.env.local</code> (see
            docs/PHASE3-SPEC.md §2.5). No placeholder numbers are shown.
          </p>
          <ul className="mt-3 list-disc pl-5 font-mono text-sm text-gray-300">
            {missing.map(([name]) => (
              <li key={name}>{name} — missing</li>
            ))}
            {typeof DEPLOY_FROM_BLOCK !== "bigint" && <li>NEXT_PUBLIC_DEPLOY_BLOCK — missing</li>}
          </ul>
        </div>
      </div>
    );
  }

  const [p0, p1] = data?.policies ?? [emptyPolicy(), emptyPolicy()];
  const oracle = data?.oracle;
  const feedAgeDays =
    oracle?.updatedAt !== null && oracle?.updatedAt !== undefined
      ? Math.max(0, (Date.now() / 1000 - Number(oracle.updatedAt)) / 86400)
      : null;
  const pairConfigured =
    (p1.oracleWeth?.chainlinkFeed !== ZERO_ADDRESS && p1.oracleUsdc?.chainlinkFeed !== ZERO_ADDRESS) ||
    (p1.oracleWeth?.uniswapPool !== ZERO_ADDRESS || p1.oracleUsdc?.uniswapPool !== ZERO_ADDRESS);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl font-bold">Live dashboard</h1>
        <p className="mt-2 max-w-2xl text-gray-400">
          The live Sepolia deployment, read on-chain every 30 seconds. Nothing on this page is
          hard-coded: every number below came from a chain read or an event log.
        </p>
      </div>

      {/* Header */}
      <section className="rounded-lg border border-edge bg-panel p-5">
        <div className="grid gap-2 text-sm md:grid-cols-2">
          <p>
            <span className="text-gray-500">Guard: </span>
            <a
              className="font-mono text-accent hover:underline"
              href={`${ARBISCAN}/address/${CONTRACT_ADDRESSES.arbGuard}`}
              target="_blank"
              rel="noreferrer"
            >
              {CONTRACT_ADDRESSES.arbGuard}
            </a>
          </p>
          <p>
            <span className="text-gray-500">Chain: </span>
            <span className="font-mono">{CHAIN_ID} (Arbitrum Sepolia)</span>
          </p>
          <p>
            <span className="text-gray-500">Owner: </span>
            {data?.owner ? (
              <a
                className="font-mono text-accent hover:underline"
                href={`${ARBISCAN}/address/${data.owner}`}
                target="_blank"
                rel="noreferrer"
              >
                {data.owner}
              </a>
            ) : (
              "—"
            )}
          </p>
          <p>
            <span className="text-gray-500">Latest block: </span>
            <span className="font-mono">{data?.latestBlock?.toString() ?? "—"}</span>
          </p>
          <p>
            <span className="text-gray-500">Last refresh: </span>
            {lastRefresh ? lastRefresh.toLocaleTimeString() : "—"}
            {loading && <span className="text-gray-500"> (refreshing…)</span>}
          </p>
          <p>
            <span className="text-gray-500">Event scan from block: </span>
            <span className="font-mono">
              {typeof DEPLOY_FROM_BLOCK === "bigint" ? DEPLOY_FROM_BLOCK.toString() : "not set"}
            </span>
          </p>
        </div>
        <p className="mt-3 text-xs text-gray-500">
          Deployed build note: this guard was deployed 20 Nov 2026 from an intermediate build — its
          Policy has 9 fields (no health-factor / reserve-drain / usdDenominated fields) and its
          Action has 7 fields. The dashboard reads it with that shape; see the note at the top of
          apps/web/app/dashboard/page.tsx.
        </p>
        {fetchError && <p className="mt-3 text-sm text-danger">Read error: {fetchError}</p>}
      </section>

      {/* Policies */}
      <div className="grid gap-4 md:grid-cols-2">
        <PolicyCard
          title="Policy 0 — GuardedVault"
          protocol={CONTRACT_ADDRESSES.guardedVault}
          data={p0}
          decimals={data?.decimals.mweth ?? 18}
        />
        <PolicyCard
          title="Policy 1 — GuardedPool"
          protocol={CONTRACT_ADDRESSES.guardedPool}
          data={p1}
          decimals={data?.decimals.mweth ?? 18}
        />
      </div>

      {/* Balances */}
      <section className="rounded-lg border border-edge bg-panel p-5">
        <h2 className="text-xl font-bold">Balances</h2>
        {data ? (
          <div className="mt-3 overflow-x-auto">
            <table className="w-full min-w-[560px] text-sm">
              <thead>
                <tr className="text-left text-gray-500">
                  <th className="py-1 pr-3">Holder</th>
                  <th className="py-1 pr-3">mWETH</th>
                  <th className="py-1 pr-3">mUSDC</th>
                  <th className="py-1">Shares / total</th>
                </tr>
              </thead>
              <tbody className="font-mono">
                <tr className="border-t border-edge">
                  <td className="py-2 pr-3">GuardedVault</td>
                  <td className="py-2 pr-3">{fmtAmount(data.balances.gvWeth, data.decimals.mweth)}</td>
                  <td className="py-2 pr-3">{fmtAmount(data.balances.gvUsdc, data.decimals.musdc)}</td>
                  <td className="py-2">
                    {fmtAmount(data.shares.totalGv, 18)} total
                  </td>
                </tr>
                <tr className="border-t border-edge">
                  <td className="py-2 pr-3">UnguardedVault</td>
                  <td className="py-2 pr-3">{fmtAmount(data.balances.uvWeth, data.decimals.mweth)}</td>
                  <td className="py-2 pr-3">{fmtAmount(data.balances.uvUsdc, data.decimals.musdc)}</td>
                  <td className="py-2">{fmtAmount(data.shares.totalUv, 18)} total</td>
                </tr>
                <tr className="border-t border-edge">
                  <td className="py-2 pr-3">GuardedPool (reserves)</td>
                  <td className="py-2 pr-3">{fmtAmount(data.balances.gpWeth, data.decimals.mweth)}</td>
                  <td className="py-2 pr-3">{fmtAmount(data.balances.gpUsdc, data.decimals.musdc)}</td>
                  <td className="py-2">
                    {fmtAmount(data.reserves.gp0, data.decimals.mweth)} /{" "}
                    {fmtAmount(data.reserves.gp1, data.decimals.musdc)}
                  </td>
                </tr>
                <tr className="border-t border-edge">
                  <td className="py-2 pr-3">UnguardedPool (reserves)</td>
                  <td className="py-2 pr-3">{fmtAmount(data.balances.upWeth, data.decimals.mweth)}</td>
                  <td className="py-2 pr-3">{fmtAmount(data.balances.upUsdc, data.decimals.musdc)}</td>
                  <td className="py-2">
                    {fmtAmount(data.reserves.up0, data.decimals.mweth)} /{" "}
                    {fmtAmount(data.reserves.up1, data.decimals.musdc)}
                  </td>
                </tr>
                <tr className="border-t border-edge">
                  <td className="py-2 pr-3">Attacker</td>
                  <td className="py-2 pr-3">{fmtAmount(data.balances.attWeth, data.decimals.mweth)}</td>
                  <td className="py-2 pr-3">{fmtAmount(data.balances.attUsdc, data.decimals.musdc)}</td>
                  <td className="py-2">
                    {fmtAmount(data.shares.attackerGv, 18)} gv /{" "}
                    {fmtAmount(data.shares.attackerUv, 18)} uv shares
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        ) : (
          <p className="mt-3 text-sm text-gray-400">{loading ? "Reading live balances…" : "No data yet."}</p>
        )}
      </section>

      {/* Outflow windows */}
      <section className="rounded-lg border border-edge bg-panel p-5">
        <h2 className="text-xl font-bold">Outflow windows</h2>
        <p className="mt-1 text-sm text-gray-400">
          Cumulative outflow in the current block / hour / day window per policy, against each cap.
        </p>
        <div className="mt-3 grid gap-4 md:grid-cols-2">
          <OutflowCard title="Policy 0 — GuardedVault" data={p0} decimals={data?.decimals.mweth ?? 18} />
          <OutflowCard title="Policy 1 — GuardedPool" data={p1} decimals={data?.decimals.mweth ?? 18} />
        </div>
      </section>

      {/* Oracle / stale feed */}
      <section className="rounded-lg border border-edge bg-panel p-5">
        <h2 className="text-xl font-bold">Oracle — Sepolia stale feed</h2>
        {oracle ? (
          <div className="mt-3 space-y-2 text-sm">
            <p>
              <span className="text-gray-500">ETH/USD feed: </span>
              {oracle.feed !== ZERO_ADDRESS ? (
                <a
                  className="font-mono text-accent hover:underline"
                  href={`${ARBISCAN}/address/${oracle.feed}`}
                  target="_blank"
                  rel="noreferrer"
                >
                  {oracle.feed}
                </a>
              ) : (
                "— (no feed configured for policy 1 / mWETH)"
              )}
            </p>
            <p>
              <span className="text-gray-500">Latest answer: </span>
              <span className="font-mono">
                {oracle.answer !== null ? `$${formatUnits(oracle.answer, oracle.feedDecimals)}` : "—"}
              </span>
            </p>
            <p>
              <span className="text-gray-500">Last update: </span>
              {oracle.updatedAt !== null ? (
                <>
                  {formatTs(oracle.updatedAt)} UTC
                  {feedAgeDays !== null && (
                    <span className="text-amber"> — stale, {feedAgeDays.toFixed(0)} days old</span>
                  )}
                </>
              ) : (
                "—"
              )}
            </p>
            <p>
              <span className="text-gray-500">getReferencePrice(1, mWETH, mUSDC): </span>
              {oracle.refError ? (
                <span className="font-mono text-amber">reverts: {oracle.refError}</span>
              ) : (
                <span className="font-mono">
                  {oracle.refPrice !== null ? formatUnits(oracle.refPrice, 18) : "—"}
                  {oracle.refSource && oracle.refSource !== ZERO_ADDRESS
                    ? ` (source ${shortAddr(oracle.refSource)})`
                    : " (price 0, no source)"}
                </span>
              )}
            </p>
            <div className="rounded border border-amber/40 bg-amber/10 p-3 text-sm text-gray-200">
              <p className="font-bold text-amber">Stale feed — by design, and what it actually means here</p>
              <p className="mt-1">
                Chainlink does not maintain testnet feeds. The Sepolia ETH/USD feed last updated{" "}
                {oracle.updatedAt !== null ? formatTs(oracle.updatedAt) : "in Oct 2024"} and is stale.
                The mWETH/mUSDC pair is <strong>not fully configured</strong> on this deployment
                {pairConfigured ? "" : " (mUSDC has no Chainlink feed and no Uniswap V3 pool configured)"} — so
                the guard has no reference price for the pair and the price rule is{" "}
                <strong>skipped for mWETH/mUSDC swaps</strong>, not failed closed. Verified live with{" "}
                <code className="font-mono">simulateCheck</code>: a 1,000 mWETH → 500 mUSDC swap passes,
                and even a 40% price push passes. Swaps are still bounded by the outflow caps above.
                The staleness guard itself works — a configured pair with a stale feed would fail
                closed with ORACLE_UNAVAILABLE — but this pair never reaches that check.
              </p>
              <p className="mt-2">
                No USDC/USD feed and no sequencer feed exist on Sepolia, so this deployment prices
                ETH/USD only and skips the sequencer check (
                <code className="font-mono">sequencerFeed == address(0)</code>).
              </p>
            </div>
          </div>
        ) : (
          <p className="mt-3 text-sm text-gray-400">{loading ? "Reading the feed…" : "No data yet."}</p>
        )}
      </section>

      {/* Recent events */}
      <section className="rounded-lg border border-edge bg-panel p-5">
        <h2 className="text-xl font-bold">Recent guard events</h2>
        <p className="mt-1 text-sm text-gray-400">
          Last 20 persistent ArbGuard events, newest first, from deploy block{" "}
          {typeof DEPLOY_FROM_BLOCK === "bigint" ? DEPLOY_FROM_BLOCK.toString() : "—"}.
        </p>
        {eventsNote && <p className="mt-2 text-sm text-amber">{eventsNote}</p>}
        {events.length === 0 ? (
          <p className="mt-3 text-sm text-gray-400">
            {loading ? "Scanning events…" : "0 events since deploy block."}
          </p>
        ) : (
          <div className="mt-3 overflow-x-auto">
            <table className="w-full min-w-[640px] text-sm">
              <thead>
                <tr className="text-left text-gray-500">
                  <th className="py-1 pr-3">Event</th>
                  <th className="py-1 pr-3">Policy</th>
                  <th className="py-1 pr-3">Block</th>
                  <th className="py-1 pr-3">Time</th>
                  <th className="py-1">Tx</th>
                </tr>
              </thead>
              <tbody>
                {events.map((e) => (
                  <tr key={`${e.txHash}-${e.name}`} className="border-t border-edge align-top">
                    <td className="py-2 pr-3">
                      <span className="font-mono font-bold">{e.name}</span>
                      <span className="block text-xs text-gray-400">{e.summary}</span>
                    </td>
                    <td className="py-2 pr-3 font-mono">{e.policyId}</td>
                    <td className="py-2 pr-3 font-mono">{e.blockNumber}</td>
                    <td className="py-2 pr-3 text-xs">{e.time ?? "—"}</td>
                    <td className="py-2">
                      <a
                        className="font-mono text-accent hover:underline"
                        href={`${ARBISCAN}/tx/${e.txHash}`}
                        target="_blank"
                        rel="noreferrer"
                      >
                        {shortAddr(e.txHash)}
                      </a>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        <p className="mt-3 text-xs text-gray-500">
          Blocked attacks do not appear here — a reverted <code className="font-mono">check()</code>{" "}
          leaves no on-chain event. Blocked attempts are visible in the simulator&apos;s receipt panel
          and in the session list below.
        </p>
      </section>

      {/* Blocked attempts (this browser) */}
      <section className="rounded-lg border border-edge bg-panel p-5">
        <h2 className="text-xl font-bold">Blocked attempts (this browser session)</h2>
        <p className="mt-1 text-sm text-gray-400">
          Recorded in this browser session — reverted transactions leave no on-chain event.
        </p>
        {blocked.length === 0 ? (
          <p className="mt-3 text-sm text-gray-400">
            No blocked attempts recorded in this session yet. Run an attack in the{" "}
            <a className="text-accent hover:underline" href="/simulator">
              simulator
            </a>{" "}
            to see one here.
          </p>
        ) : (
          <ul className="mt-3 space-y-2 text-sm">
            {blocked
              .slice()
              .reverse()
              .map((b, i) => (
                <li key={`${b.ts}-${i}`} className="rounded border border-edge bg-ink p-3">
                  <span className="font-mono font-bold">{b.reason}</span> — {b.attack} on {b.target}
                  <span className="block text-xs text-gray-500">
                    {new Date(b.ts).toLocaleString()}
                    {b.txHash ? (
                      <>
                        {" "}
                        ·{" "}
                        <a
                          className="font-mono text-accent hover:underline"
                          href={`${ARBISCAN}/tx/${b.txHash}`}
                          target="_blank"
                          rel="noreferrer"
                        >
                          {shortAddr(b.txHash)}
                        </a>
                      </>
                    ) : (
                      ""
                    )}
                  </span>
                </li>
              ))}
          </ul>
        )}
      </section>

      {/* Keeper status */}
      <section className="rounded-lg border border-edge bg-panel p-5">
        <h2 className="text-xl font-bold">Keeper status</h2>
        <p className="mt-1 text-sm text-gray-400">
          On-chain facts only. The dashboard cannot know whether the keeper bot process is alive —
          there is no bot status endpoint in this phase.
        </p>
        <div className="mt-3 grid gap-4 text-sm md:grid-cols-2">
          {[0, 1].map((pid) => {
            const pd = pid === 0 ? p0 : p1;
            const active =
              pd.mode === 2
                ? `PAUSED until ${formatUntil(pd.throttleUntil === 0n ? pd.pausedUntil : pd.throttleUntil)}`
                : pd.mode === 1
                  ? `THROTTLED until ${formatUntil(pd.throttleUntil)}`
                  : "no throttle / trip active";
            return (
              <div key={pid} className="rounded border border-edge bg-ink p-3">
                <p className="font-bold">Policy {pid}</p>
                <p className="mt-1">
                  <span className="text-gray-500">Keepers: </span>
                  {pd.keepers.length > 0 ? (
                    <span className="font-mono">{pd.keepers.join(", ")}</span>
                  ) : (
                    "—"
                  )}
                </p>
                <p>
                  <span className="text-gray-500">Breaker: </span>
                  {active}
                </p>
              </div>
            );
          })}
        </div>
        <p className="mt-3 text-sm text-amber">
          Bot status: unknown — see keeper/decisions.log
        </p>
      </section>
    </div>
  );
}

function ModeBadge({ mode }: { mode: number | null }) {
  const name = mode !== null ? MODE_NAMES[mode] ?? String(mode) : "—";
  const color =
    mode === 0
      ? "border-accent/40 bg-accent/10 text-accent"
      : mode === 1
        ? "border-amber/40 bg-amber/10 text-amber"
        : mode === 2
          ? "border-danger/40 bg-danger/10 text-danger"
          : "border-edge bg-ink text-gray-500";
  return <span className={`rounded border px-2 py-0.5 font-mono text-xs font-bold ${color}`}>{name}</span>;
}

function PolicyCard({
  title,
  protocol,
  data,
  decimals,
}: {
  title: string;
  protocol: string;
  data: PolicyData;
  decimals: number;
}) {
  const p = data.policy;
  const mode = data.mode;
  return (
    <section className="rounded-lg border border-edge bg-panel p-5">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-xl font-bold">{title}</h2>
        <ModeBadge mode={mode} />
      </div>
      <p className="mt-1 text-xs text-gray-500">
        <a
          className="font-mono text-accent hover:underline"
          href={`${ARBISCAN}/address/${protocol}`}
          target="_blank"
          rel="noreferrer"
        >
          {protocol}
        </a>
      </p>
      {!p ? (
        <p className="mt-3 text-sm text-gray-400">Reading policy…</p>
      ) : (
        <dl className="mt-3 space-y-1.5 text-sm">
          <Row label="Enabled" value={p.enabled ? "yes" : "no"} />
          <Row label="Block cap" value={`${fmtAmount(p.maxOutflowPerBlock, decimals)} (effective ${fmtAmount(effCap(p.maxOutflowPerBlock, mode, p.throttleBps), decimals)} when throttled)`} />
          <Row label="Hour cap" value={`${p.maxOutflowPerHour === 0n ? "0 (unenforced)" : fmtAmount(p.maxOutflowPerHour, decimals)} (effective ${fmtAmount(effCap(p.maxOutflowPerHour, mode, p.throttleBps), decimals)} when throttled)`} />
          <Row label="Day cap" value={`${p.maxOutflowPerDay === 0n ? "0 (unenforced)" : fmtAmount(p.maxOutflowPerDay, decimals)} (effective ${fmtAmount(effCap(p.maxOutflowPerDay, mode, p.throttleBps), decimals)} when throttled)`} />
          <Row label="Single-share" value={`${p.maxSingleShareBps} bps (${(p.maxSingleShareBps / 100).toFixed(2)}% of TVL)`} />
          <Row label="Price deviation" value={`${p.maxPriceDeviationBps} bps (${(p.maxPriceDeviationBps / 100).toFixed(2)}%)`} />
          <Row label="Throttle" value={`${p.throttleBps} bps (${(p.throttleBps / 100).toFixed(0)}% effective caps)`} />
          <Row label="Cooldown" value={`${p.cooldownSeconds}s (${(p.cooldownSeconds / 3600).toFixed(1)}h)`} />
          <Row label="Timelock delay" value={`${p.policyTimelockSeconds}s (${(p.policyTimelockSeconds / 3600).toFixed(0)}h)`} />
          <Row label="Keepers" value={data.keepers.length > 0 ? data.keepers.join(", ") : "—"} mono />
          <Row label="Paused until" value={formatUntil(data.pausedUntil)} />
          <Row label="Throttle until" value={formatUntil(data.throttleUntil)} />
          {data.price && (
            <>
              <Row label="TWAP window" value={`${data.price.twapSeconds}s`} />
              <Row label="Max oracle deviation" value={`${data.price.maxOracleDeviationBps} bps`} />
              <Row label="Chainlink stale-after" value={`${data.price.chainlinkStaleAfter}s`} />
              <Row
                label="Sequencer feed"
                value={data.price.sequencerFeed === ZERO_ADDRESS ? "address(0) — check skipped" : data.price.sequencerFeed}
                mono
              />
            </>
          )}
        </dl>
      )}
    </section>
  );
}

function Row({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="flex flex-wrap justify-between gap-2">
      <dt className="text-gray-500">{label}</dt>
      <dd className={mono ? "font-mono text-xs break-all" : "font-mono text-right"}>{value}</dd>
    </div>
  );
}

function OutflowCard({ title, data, decimals }: { title: string; data: PolicyData; decimals: number }) {
  const p = data.policy;
  const rows: { label: string; used: bigint; cap: bigint; id: string }[] = [
    { label: "Block", used: data.outflow.block, cap: p?.maxOutflowPerBlock ?? 0n, id: `block ${data.outflow.blockId.toString()}` },
    { label: "Hour", used: data.outflow.hour, cap: p?.maxOutflowPerHour ?? 0n, id: `hour ${data.outflow.hourId.toString()}` },
    { label: "Day", used: data.outflow.day, cap: p?.maxOutflowPerDay ?? 0n, id: `day ${data.outflow.dayId.toString()}` },
  ];
  return (
    <div className="rounded border border-edge bg-ink p-4">
      <p className="font-bold">{title}</p>
      <div className="mt-3 space-y-3">
        {rows.map((r) => {
          const eff = effCap(r.cap, data.mode, p?.throttleBps ?? 1000);
          const pct = eff > 0n ? Number((r.used * 10_000n) / eff) / 100 : null;
          return (
            <div key={r.label} className="text-sm">
              <div className="flex justify-between">
                <span>
                  {r.label} <span className="text-gray-500">({r.id})</span>
                </span>
                <span className="font-mono">
                  {fmtAmount(r.used, decimals)} / {eff > 0n ? fmtAmount(eff, decimals) : "unenforced"}
                  {pct !== null && ` — ${pct.toFixed(1)}%`}
                </span>
              </div>
              <div className="mt-1 h-2 overflow-hidden rounded bg-edge">
                <div
                  className={`h-full ${pct !== null && pct >= 80 ? "bg-danger" : pct !== null && pct >= 50 ? "bg-amber" : "bg-accent"}`}
                  style={{ width: `${pct === null ? 0 : Math.min(100, pct)}%` }}
                />
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
