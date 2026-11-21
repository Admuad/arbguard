#!/usr/bin/env python3
"""Run forge fork tests against Alchemy's Arbitrum One archive RPC.

The public RPC (arb1.arbitrum.io) is load-balanced across archive and
pruned backends and intermittently refuses historical state for the
pinned fork block, which makes fresh fork tests fail at createSelectFork.
Alchemy's arb-mainnet endpoint serves the same chain/block reliably.

The API key never appears here: the surrogate (hsurr:...) is swapped for
the real key by the runtime on approved egress to the registered host
arb-mainnet.g.alchemy.com. The URL is never printed or logged.

Usage:
  python3 run-fork-tests-alchemy.py [--match-contract <name>] [--match-test <name>]
"""
import os
import subprocess
import sys

sys.path.insert(0, "/opt/muse/skills/custom-connector-setup/bin")
from dynamic_credentials import dynamic_credential_entry

HOST = "arb-mainnet.g.alchemy.com"


def main() -> int:
    entry = dynamic_credential_entry("custom.alchemy")
    surrogate = entry["surrogate"]
    if not surrogate.startswith("hsurr:"):
        print("unexpected surrogate format", file=sys.stderr)
        return 2
    # Raw surrogate in the path segment; do NOT percent-encode.
    rpc_url = f"https://{HOST}/v2/{surrogate}"

    env = dict(os.environ)
    env["ARBITRUM_ONE_RPC_URL"] = rpc_url

    cmd = [os.path.expanduser("~/.foundry/bin/forge"), "test"]
    # Pass through any forge args (e.g. --match-contract, --match-test, -vv).
    cmd.extend(sys.argv[1:])

    result = subprocess.run(cmd, cwd=os.path.expanduser("~/workspace/guardrail/contracts"), env=env)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
