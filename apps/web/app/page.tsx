import Link from "next/link";

export default function Home() {
  return (
    <div className="space-y-12">
      <section className="space-y-4 pt-6">
        <p className="font-mono text-sm text-accent">ARBITRUM OPEN HOUSE SÃO PAULO 2027 — ONLINE BUILDATHON</p>
        <h1 className="text-4xl font-bold leading-tight md:text-5xl">
          The on-chain circuit breaker for Arbitrum.
        </h1>
        <p className="max-w-2xl text-lg text-gray-300">
          ArbGuard reverts the exploit transaction{" "}
          <strong className="text-white">before the money moves</strong>.
          Protocols declare four invariants; ArbGuard enforces them on-chain,
          in real time, with one <code className="font-mono text-accent">check()</code> call
          before each sensitive action.
        </p>
        <div className="flex flex-wrap gap-3 pt-2">
          <Link
            href="/simulator"
            className="rounded bg-accent px-5 py-2 font-medium text-black"
          >
            ▶ Run the attack simulator
          </Link>
          <Link
            href="/policies"
            className="rounded border border-edge bg-panel px-5 py-2 font-medium hover:border-accent"
          >
            Create a policy
          </Link>
        </div>
      </section>

      <section className="grid gap-4 md:grid-cols-3">
        <div className="rounded-lg border border-edge bg-panel p-5">
          <h2 className="font-bold">Enforcement, not detection</h2>
          <p className="mt-2 text-sm text-gray-400">
            Monitors alert after the money is gone. Audits check code before
            deployment. ArbGuard is the missing middle: it stops the
            transaction on-chain, while the attack is happening.
          </p>
        </div>
        <div className="rounded-lg border border-edge bg-panel p-5">
          <h2 className="font-bold">Same attack, two vaults</h2>
          <p className="mt-2 text-sm text-gray-400">
            A looped drain empties the unguarded vault and reverts on the
            guarded one. A 40% price push goes through unguarded and reverts
            guarded. The simulator proves it — try it yourself.
          </p>
        </div>
        <div className="rounded-lg border border-edge bg-panel p-5">
          <h2 className="font-bold">10 lines to integrate</h2>
          <p className="mt-2 text-sm text-gray-400">
            Register a policy (four numbers + a keeper), add one{" "}
            <code className="font-mono text-accent">check()</code> call before
            withdraw or swap. The hot-path math runs in a Stylus (Rust)
            checker for gas efficiency — but the Solidity invariant math
            ships: the Stylus checker is built and tested, and its deployment
            is blocked by the chain-wide activation pause.
          </p>
        </div>
      </section>

      <section className="rounded-lg border border-edge bg-panel p-6">
        <h2 className="mb-4 text-xl font-bold">The four invariants</h2>
        <ol className="list-decimal space-y-2 pl-5 text-sm text-gray-300">
          <li>
            <strong className="text-white">Max outflow per block</strong> — cumulative
            net outflow in the current block must stay under the cap. This is
            what stops a looped drain.
          </li>
          <li>
            <strong className="text-white">Max single-withdrawal share of TVL</strong> — one
            withdrawal cannot exceed a set share of total value locked.
          </li>
          <li>
            <strong className="text-white">Price deviation vs TWAP</strong> — a swap whose
            execution price moves too far from the reference price reverts.
          </li>
          <li>
            <strong className="text-white">Reserve conservation</strong> — after the action,
            recorded reserves must reconcile with actual balances.
          </li>
        </ol>
      </section>

      <section className="rounded-lg border border-amber/40 bg-amber/10 p-6">
        <h2 className="font-bold text-amber">Deployment status: local demo ready, Sepolia pending</h2>
        <p className="mt-2 text-sm text-gray-300">
          The contracts run against a local Anvil demo deployment (see{" "}
          <code className="font-mono">apps/web/LOCAL-DEMO.md</code>); the
          Arbitrum Sepolia deployment is pending the owner&apos;s deployer key
          and faucet ETH. Until Sepolia addresses are set, the simulator runs
          in explicit simulation mode. No address shown here is real until a
          deployment lands.
        </p>
        <p className="mt-2 text-sm text-gray-400">
          Built for the Arbitrum Open House São Paulo 2027 Online Buildathon
          ($115,000 USD prize pool). Submission target: Fri Feb 26, 2027
          (deadline Feb 28, 2027, 11:59 PM BRT).
        </p>
      </section>
    </div>
  );
}
