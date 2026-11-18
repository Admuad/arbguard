import { EventFeed } from "@/components/EventFeed";

export default function FeedPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-3xl font-bold">Live event feed</h1>
        <p className="mt-2 max-w-2xl text-gray-400">
          Real, persistent ArbGuard events from the deployed contracts:{" "}
          <span className="font-mono">PolicyRegistered</span>,{" "}
          <span className="font-mono">CheckPassed</span>,{" "}
          <span className="font-mono">BreakerTripped</span>,{" "}
          <span className="font-mono">BreakerReset</span>. Blocked attacks do
          not appear here — a reverted transaction leaves no event on chain;
          see the simulator for those.
        </p>
      </div>
      <EventFeed />
    </div>
  );
}
