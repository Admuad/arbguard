import { getDefaultConfig } from "@rainbow-me/rainbowkit";
import { arbitrum, arbitrumSepolia, localhost } from "wagmi/chains";
import { http } from "wagmi";
import { RPC_URL } from "@/lib/contracts";

/**
 * WalletConnect project ID.
 *
 * Read from NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID. If it is not set, a dummy
 * placeholder ID is used so that `npm run build` passes without a real key.
 * Wallet connection will NOT work with the dummy ID — create a free project
 * at https://cloud.walletconnect.com and set the env var (see .env.example).
 * Never commit a real project ID's secret — the project ID itself is public,
 * but keep it in .env.local anyway.
 */
export const walletConnectProjectId =
  process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ||
  "00000000000000000000000000000000";

export const wagmiConfig = getDefaultConfig({
  appName: "ArbGuard",
  projectId: walletConnectProjectId,
  chains: [localhost, arbitrumSepolia, arbitrum],
  transports: {
    [localhost.id]: http(RPC_URL),
    // Sepolia reads go to the configured RPC (NEXT_PUBLIC_RPC_URL) when
    // set — the dashboard's live reads depend on this. Falls back to the
    // chain default when no RPC is configured.
    [arbitrumSepolia.id]: process.env.NEXT_PUBLIC_RPC_URL
      ? http(process.env.NEXT_PUBLIC_RPC_URL)
      : http(),
    [arbitrum.id]: http(),
  },
  ssr: true,
});
