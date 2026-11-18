import { AttackSimulator } from "@/components/AttackSimulator";

export default function SimulatorPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl font-bold">Attack simulator</h1>
        <p className="mt-2 max-w-2xl text-gray-400">
          Same attack, two targets. Pick a guarded or unguarded vault/pool,
          pick the attack, and run it. On the guarded target the transaction
          reverts with a named <span className="font-mono">ArbGuardViolation</span> reason
          and the balances never move.
        </p>
      </div>
      <AttackSimulator />
    </div>
  );
}
