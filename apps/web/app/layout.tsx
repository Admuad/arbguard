import type { Metadata } from "next";
import Link from "next/link";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { Providers } from "@/components/Providers";
import "./globals.css";

export const metadata: Metadata = {
  title: "ArbGuard — the on-chain circuit breaker for Arbitrum",
  description:
    "ArbGuard reverts the exploit transaction before the money moves. A plug-in invariant firewall for Arbitrum protocols.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <header className="border-b border-edge">
            <div className="mx-auto flex max-w-5xl items-center justify-between px-4 py-3">
              <Link href="/" className="font-mono text-lg font-bold">
                🛡️ Arb<span className="text-accent">Guard</span>
              </Link>
              <nav className="flex items-center gap-4 text-sm">
                <Link href="/policies" className="hover:text-accent">
                  Policies
                </Link>
                <Link href="/simulator" className="hover:text-accent">
                  Simulator
                </Link>
                <Link href="/feed" className="hover:text-accent">
                  Live feed
                </Link>
                <Link href="/integrate" className="hover:text-accent">
                  Integrate
                </Link>
                <ConnectButton />
              </nav>
            </div>
          </header>
          <main className="mx-auto max-w-5xl px-4 py-8">{children}</main>
          <footer className="border-t border-edge py-6 text-center text-xs text-gray-500">
            ArbGuard — MIT, © Muhammed Adediran 2026. Local Anvil demo
            ready; Arbitrum Sepolia deployment pending. No fake addresses, no
            fake stats.
          </footer>
        </Providers>
      </body>
    </html>
  );
}
