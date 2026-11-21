"use client";

import { useState } from "react";
import { useAccount, useWriteContract } from "wagmi";
import { isDeployed, CONTRACT_ADDRESSES, ARB_GUARD_ABI, ZERO_ADDRESS } from "@/lib/contracts";

/**
 * Create-policy form. Sliders for the four limits; submits registerPolicy.
 * Until contracts are deployed (isDeployed === false) the form shows a
 * preview of the transaction that would be sent instead of submitting.
 *
 * Phase 2 shape: registerPolicy(protocol, Policy, PriceConfig). The Policy
 * has 12 fields (hour/day windows, throttleBps, timelock, health-factor /
 * reserve-drain fields); hour/day default to 0 (window unenforced) and the
 * Phase 2 fields default to off. PriceConfig uses the contract defaults
 * (twap 1800s, 200 bps oracle deviation, 7200s staleness, no sequencer
 * feed). The keeper is NOT part of registration any more — the owner adds
 * keepers with addKeeper(policyId, keeper) after registering.
 */
export function PolicyForm() {
  const { isConnected } = useAccount();
  const { writeContract, isPending, data: txHash, error } = useWriteContract();

  const [protocol, setProtocol] = useState("");
  const [keeper, setKeeper] = useState("");
  const [maxOutflowPerBlock, setMaxOutflowPerBlock] = useState(10);
  const [maxSingleShareBps, setMaxSingleShareBps] = useState(500);
  const [maxPriceDeviationBps, setMaxPriceDeviationBps] = useState(500);
  const [cooldownSeconds, setCooldownSeconds] = useState(3600);

  const protocolValid = /^0x[a-fA-F0-9]{40}$/.test(protocol);
  const keeperValid = keeper === "" || /^0x[a-fA-F0-9]{40}$/.test(keeper);
  const canSubmit = isConnected && protocolValid && keeperValid && isDeployed;

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!isDeployed) return; // deployment pending — preview only
    writeContract({
      address: CONTRACT_ADDRESSES.arbGuard,
      abi: ARB_GUARD_ABI,
      functionName: "registerPolicy",
      args: [
        protocol as `0x${string}`,
        {
          maxOutflowPerBlock: BigInt(maxOutflowPerBlock) * 10n ** 18n,
          // Hour/day windows unenforced (0) unless set later via a
          // timelocked policy update; throttle 10%, timelock 24h; the
          // Phase 2 health-factor / reserve-drain rules are off (0).
          maxOutflowPerHour: 0n,
          maxOutflowPerDay: 0n,
          // uint16/uint16/uint32 in ArbGuard.sol — viem expects numbers, not bigint.
          maxSingleShareBps,
          maxPriceDeviationBps,
          throttleBps: 1000,
          cooldownSeconds,
          policyTimelockSeconds: 86400,
          enabled: true,
          usdDenominated: false,
          minHealthFactorBps: 0,
          maxReserveDrainBps: 0,
        },
        {
          twapSeconds: 1800,
          maxOracleDeviationBps: 200,
          chainlinkStaleAfter: 7200,
          sequencerFeed: ZERO_ADDRESS,
        },
      ],
    });
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-6 rounded-lg border border-edge bg-panel p-6">
      {!isDeployed && (
        <div className="rounded border border-amber/40 bg-amber/10 p-3 text-sm text-amber">
          Contracts are not deployed yet — addresses are TBD. This form shows a
          preview of the transaction that will be sent once ArbGuard is live
          on Arbitrum Sepolia. No transaction is submitted.
        </div>
      )}
      {!isConnected && (
        <p className="text-sm text-gray-400">
          Connect your wallet (top right) to register a policy on-chain.
        </p>
      )}
      {isDeployed && (
        <p className="rounded border border-edge bg-ink p-3 text-sm text-gray-300">
          <strong className="text-white">Owner-only:</strong> registerPolicy
          can only be called by the ArbGuard owner. On local Anvil, connect
          with the deployer/owner account (Anvil account #0) — any other
          account&apos;s transaction will revert.
        </p>
      )}

      <div>
        <label className="mb-1 block text-sm font-medium">Protocol address</label>
        <input
          value={protocol}
          onChange={(e) => setProtocol(e.target.value)}
          placeholder="0x… (the vault or pool ArbGuard will protect)"
          className="w-full rounded border border-edge bg-ink px-3 py-2 font-mono text-sm outline-none focus:border-accent"
        />
        {protocol !== "" && !protocolValid && (
          <p className="mt-1 text-xs text-danger">Enter a valid 0x address.</p>
        )}
      </div>

      <div>
        <label className="mb-1 block text-sm font-medium">
          Keeper address{" "}
          <span className="text-gray-500">
            (optional — added after registration with addKeeper, owner-only)
          </span>
        </label>
        <input
          value={keeper}
          onChange={(e) => setKeeper(e.target.value)}
          placeholder="0x… (allowed to trip the breaker)"
          className="w-full rounded border border-edge bg-ink px-3 py-2 font-mono text-sm outline-none focus:border-accent"
        />
        {keeper !== "" && !keeperValid && (
          <p className="mt-1 text-xs text-danger">Enter a valid 0x address.</p>
        )}
      </div>

      <Slider
        label="Max outflow per block"
        value={maxOutflowPerBlock}
        min={1}
        max={1000}
        step={1}
        unit="ETH"
        hint="Cumulative net outflow allowed in a single block. A looped drain hits this cap and the whole tx reverts."
        onChange={setMaxOutflowPerBlock}
      />
      <Slider
        label="Max single-withdrawal share of TVL"
        value={maxSingleShareBps}
        min={10}
        max={5000}
        step={10}
        unit={`bps (${(maxSingleShareBps / 100).toFixed(2)}% of TVL)`}
        hint="One withdrawal cannot exceed this share of total value locked."
        onChange={setMaxSingleShareBps}
      />
      <Slider
        label="Max price deviation vs TWAP"
        value={maxPriceDeviationBps}
        min={10}
        max={5000}
        step={10}
        unit={`bps (${(maxPriceDeviationBps / 100).toFixed(2)}%)`}
        hint="A swap whose execution price moves further than this from the reference price reverts."
        onChange={setMaxPriceDeviationBps}
      />
      <Slider
        label="Breaker cooldown"
        value={cooldownSeconds}
        min={60}
        max={86400}
        step={60}
        unit={`seconds (${(cooldownSeconds / 3600).toFixed(1)}h)`}
        hint="How long a tripped breaker pauses guarded functions. It auto-resumes when the cooldown ends."
        onChange={setCooldownSeconds}
      />

      <button
        type="submit"
        disabled={!canSubmit || isPending}
        className="w-full rounded bg-accent px-4 py-2 font-medium text-black disabled:cursor-not-allowed disabled:opacity-40"
      >
        {isPending
          ? "Submitting…"
          : isDeployed
            ? "Register policy on-chain"
            : "Register policy (preview — deployment pending)"}
      </button>

      {txHash && (
        <p className="break-all font-mono text-sm text-accent">Tx submitted: {txHash}</p>
      )}
      {error && (
        <p className="text-sm text-danger">Error: {error.message.slice(0, 300)}</p>
      )}

      {!isDeployed && protocolValid && (
        <div className="rounded border border-edge bg-ink p-4 font-mono text-xs leading-relaxed text-gray-300">
          <p className="mb-2 font-bold text-gray-100">Preview — registerPolicy call</p>
          <p>arbGuard: {CONTRACT_ADDRESSES.arbGuard} (TBD)</p>
          <p>protocol: {protocol}</p>
          <p>maxOutflowPerBlock: {maxOutflowPerBlock} ETH</p>
          <p>maxOutflowPerHour: 0 (window unenforced)</p>
          <p>maxOutflowPerDay: 0 (window unenforced)</p>
          <p>maxSingleShareBps: {maxSingleShareBps} bps</p>
          <p>maxPriceDeviationBps: {maxPriceDeviationBps} bps</p>
          <p>throttleBps: 1000 (10% effective caps when throttled)</p>
          <p>cooldownSeconds: {cooldownSeconds}s</p>
          <p>policyTimelockSeconds: 86400s (24h)</p>
          <p>
            keeper: {keeper === "" ? ZERO_ADDRESS : keeper} (added afterwards
            via addKeeper — not part of registerPolicy)
          </p>
        </div>
      )}
    </form>
  );
}

function Slider({
  label,
  value,
  min,
  max,
  step,
  unit,
  hint,
  onChange,
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  unit: string;
  hint: string;
  onChange: (v: number) => void;
}) {
  return (
    <div>
      <div className="mb-1 flex items-baseline justify-between">
        <label className="text-sm font-medium">{label}</label>
        <span className="font-mono text-sm text-accent">
          {value} {unit}
        </span>
      </div>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(e) => onChange(Number(e.target.value))}
        className="w-full"
      />
      <p className="text-xs text-gray-500">{hint}</p>
    </div>
  );
}
