import { PolicyForm } from "@/components/PolicyForm";

export default function PoliciesPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl font-bold">Create a policy</h1>
        <p className="mt-2 max-w-2xl text-gray-400">
          Four numbers + a keeper address. ArbGuard enforces your policy
          on-chain: any transaction that breaks it reverts before funds move.
          Set the caps above your largest legitimate flow and below the amount
          that would hurt if it left in one attack.
        </p>
      </div>
      <PolicyForm />
    </div>
  );
}
