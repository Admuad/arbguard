/**
 * Contract addresses + ABIs for ArbGuard.
 *
 * GENERATED — do not hand-edit. Regenerate with:
 *   cd contracts && forge build && cd ../apps/web && node scripts/generate-abis.mjs
 * Source of truth for the ABIs: the compiled Foundry artifacts in contracts/out/.
 *
 * ADDRESSES ARE ENV-DRIVEN: every address below is read from its
 * NEXT_PUBLIC_* env var (see apps/web/.env.example) and falls back to the
 * zero address when unset. For a local demo, run
 *   node apps/web/scripts/write-local-env.mjs
 * after the AnvilDemo broadcast — it writes apps/web/.env.local with the
 * deployed addresses. For Sepolia, fill in the deployed addresses the
 * same way. `isDeployed` is true only when all seven live-path
 * addresses (arbGuard, guardedVault, unguardedVault, guardedPool,
 * attacker, mweth, musdc) are set and non-zero, and the UI gates all
 * live calls behind it.
 *
 * NOTE (design decision, see contracts/src/ArbGuard.sol): there is NO
 * ViolationBlocked event — a reverted tx leaves no persistent event.
 * Blocked attempts surface via the ArbGuardViolation revert reason and
 * via simulateCheck(). The events below are the real ones.
 */
import type { Abi } from "viem";

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;

/** Read an address env var; anything missing/malformed becomes the zero address. */
function envAddress(value: string | undefined): `0x${string}` {
  return value && /^0x[a-fA-F0-9]{40}$/.test(value)
    ? (value as `0x${string}`)
    : ZERO_ADDRESS;
}

export const CONTRACT_ADDRESSES = {
  arbGuard: envAddress(process.env.NEXT_PUBLIC_ARB_GUARD_ADDRESS),
  guardedVault: envAddress(process.env.NEXT_PUBLIC_GUARDED_VAULT_ADDRESS),
  unguardedVault: envAddress(process.env.NEXT_PUBLIC_UNGUARDED_VAULT_ADDRESS),
  guardedPool: envAddress(process.env.NEXT_PUBLIC_GUARDED_POOL_ADDRESS),
  unguardedPool: envAddress(process.env.NEXT_PUBLIC_UNGUARDED_POOL_ADDRESS),
  attacker: envAddress(process.env.NEXT_PUBLIC_ATTACKER_ADDRESS),
  mweth: envAddress(process.env.NEXT_PUBLIC_MWETH_ADDRESS),
  musdc: envAddress(process.env.NEXT_PUBLIC_MUSDC_ADDRESS),
  arbGuardChecker: ZERO_ADDRESS, // TBD — Stylus checker (no env var yet)
} as const;

/** Chain id from NEXT_PUBLIC_CHAIN_ID (31337 local Anvil | 421614 Sepolia | 42161 One). */
export const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID || 31337);

/** RPC URL for the localhost transport (default Anvil http://127.0.0.1:8545). */
export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL || "http://127.0.0.1:8545";

/**
 * First block to scan for ArbGuard events (NEXT_PUBLIC_DEPLOY_BLOCK).
 * A decimal block number, or "earliest" when unset/invalid.
 */
export const DEPLOY_FROM_BLOCK: bigint | "earliest" =
  process.env.NEXT_PUBLIC_DEPLOY_BLOCK && /^\d+$/.test(process.env.NEXT_PUBLIC_DEPLOY_BLOCK)
    ? BigInt(process.env.NEXT_PUBLIC_DEPLOY_BLOCK)
    : "earliest";

/** True only when every address the live paths need is set and non-zero. */
export const isDeployed =
  CONTRACT_ADDRESSES.arbGuard !== ZERO_ADDRESS &&
  CONTRACT_ADDRESSES.guardedVault !== ZERO_ADDRESS &&
  CONTRACT_ADDRESSES.unguardedVault !== ZERO_ADDRESS &&
  CONTRACT_ADDRESSES.guardedPool !== ZERO_ADDRESS &&
  CONTRACT_ADDRESSES.attacker !== ZERO_ADDRESS &&
  CONTRACT_ADDRESSES.mweth !== ZERO_ADDRESS &&
  CONTRACT_ADDRESSES.musdc !== ZERO_ADDRESS;

/** ArbGuard Reason enum (contracts/src/ArbGuard.sol): NONE=0 .. BREAKER_TRIPPED=4. */
export const REASON_NAMES = [
  "NONE",
  "OUTFLOW_PER_BLOCK",
  "SINGLE_SHARE",
  "PRICE_DEVIATION",
  "BREAKER_TRIPPED",
] as const;

/** ActionKind enum (contracts/src/ArbGuard.sol): WITHDRAW=0, MINT=1, SWAP=2, BORROW=3. */
export const ACTION_KIND_NAMES = ["WITHDRAW", "MINT", "SWAP", "BORROW"] as const;

/** localStorage key + window event for blocked attempts recorded this session. */
export const BLOCKED_ATTEMPTS_KEY = "arbguard:blocked-attempts";
export const BLOCKED_ATTEMPT_EVENT = "arbguard:blocked-attempt";

export type BlockedAttempt = {
  ts: number;
  attack: string;
  target: string;
  reason: string;
  txHash?: string;
};

export const ARB_GUARD_ABI = [
  {
    "type": "constructor",
    "inputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "acceptOwnership",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "check",
    "inputs": [
      {
        "name": "protocol",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "action",
        "type": "tuple",
        "internalType": "struct Action",
        "components": [
          {
            "name": "kind",
            "type": "uint8",
            "internalType": "enum ActionKind"
          },
          {
            "name": "token",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "amountOut",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "amountIn",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "price",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "twapPrice",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "tvl",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "getPolicy",
    "inputs": [
      {
        "name": "policyId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct Policy",
        "components": [
          {
            "name": "maxOutflowPerBlock",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "maxSingleShareBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "maxPriceDeviationBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "cooldownSeconds",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "keeper",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "enabled",
            "type": "bool",
            "internalType": "bool"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getPolicyId",
    "inputs": [
      {
        "name": "protocol",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getProtocol",
    "inputs": [
      {
        "name": "policyId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "outflowBlock",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "outflowInBlock",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "owner",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "pausedUntil",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "pendingOwner",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "registerPolicy",
    "inputs": [
      {
        "name": "protocol",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "policy",
        "type": "tuple",
        "internalType": "struct Policy",
        "components": [
          {
            "name": "maxOutflowPerBlock",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "maxSingleShareBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "maxPriceDeviationBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "cooldownSeconds",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "keeper",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "enabled",
            "type": "bool",
            "internalType": "bool"
          }
        ]
      }
    ],
    "outputs": [
      {
        "name": "policyId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "renounceOwnership",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "reset",
    "inputs": [
      {
        "name": "policyId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setEnabled",
    "inputs": [
      {
        "name": "policyId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "enabled",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "simulateCheck",
    "inputs": [
      {
        "name": "protocol",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "action",
        "type": "tuple",
        "internalType": "struct Action",
        "components": [
          {
            "name": "kind",
            "type": "uint8",
            "internalType": "enum ActionKind"
          },
          {
            "name": "token",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "amountOut",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "amountIn",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "price",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "twapPrice",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "tvl",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "outputs": [
      {
        "name": "ok",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "reason",
        "type": "uint8",
        "internalType": "enum Reason"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "transferOwnership",
    "inputs": [
      {
        "name": "newOwner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "trip",
    "inputs": [
      {
        "name": "policyId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "evidence",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "updatePolicy",
    "inputs": [
      {
        "name": "policyId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "policy",
        "type": "tuple",
        "internalType": "struct Policy",
        "components": [
          {
            "name": "maxOutflowPerBlock",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "maxSingleShareBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "maxPriceDeviationBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "cooldownSeconds",
            "type": "uint32",
            "internalType": "uint32"
          },
          {
            "name": "keeper",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "enabled",
            "type": "bool",
            "internalType": "bool"
          }
        ]
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "BreakerReset",
    "inputs": [
      {
        "name": "policyId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "BreakerTripped",
    "inputs": [
      {
        "name": "policyId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "tripper",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "pausedUntil",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "evidence",
        "type": "bytes",
        "indexed": false,
        "internalType": "bytes"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "CheckPassed",
    "inputs": [
      {
        "name": "policyId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "protocol",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "kind",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum ActionKind"
      },
      {
        "name": "token",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      },
      {
        "name": "amountOut",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "OwnershipTransferStarted",
    "inputs": [
      {
        "name": "previousOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "newOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "OwnershipTransferred",
    "inputs": [
      {
        "name": "previousOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "newOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PolicyEnabled",
    "inputs": [
      {
        "name": "policyId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "enabled",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PolicyRegistered",
    "inputs": [
      {
        "name": "policyId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "protocol",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "keeper",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PolicyUpdated",
    "inputs": [
      {
        "name": "policyId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "protocol",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "ArbGuardViolation",
    "inputs": [
      {
        "name": "reason",
        "type": "uint8",
        "internalType": "enum Reason"
      }
    ]
  },
  {
    "type": "error",
    "name": "BreakerStillActive",
    "inputs": [
      {
        "name": "pausedUntil",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "InvalidPolicy",
    "inputs": [
      {
        "name": "reason",
        "type": "string",
        "internalType": "string"
      }
    ]
  },
  {
    "type": "error",
    "name": "NotKeeperOrOwner",
    "inputs": [
      {
        "name": "caller",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "NotProtocol",
    "inputs": [
      {
        "name": "caller",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "protocol",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "OwnableInvalidOwner",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "OwnableUnauthorizedAccount",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "PolicyAlreadyRegistered",
    "inputs": [
      {
        "name": "protocol",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "UnknownPolicy",
    "inputs": [
      {
        "name": "protocol",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "UnknownPolicyId",
    "inputs": [
      {
        "name": "policyId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  }
] as const satisfies Abi;

export const VAULT_ABI = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "_asset",
        "type": "address",
        "internalType": "contract IERC20"
      },
      {
        "name": "_arbGuard",
        "type": "address",
        "internalType": "contract IArbGuard"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "arbGuard",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IArbGuard"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "asset",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IERC20"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "deposit",
    "inputs": [
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "shares",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "totalShares",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "withdraw",
    "inputs": [
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "Deposit",
    "inputs": [
      {
        "name": "depositor",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Withdraw",
    "inputs": [
      {
        "name": "withdrawer",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "InsufficientShares",
    "inputs": [
      {
        "name": "requested",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "held",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "ReentrancyGuardReentrantCall",
    "inputs": []
  },
  {
    "type": "error",
    "name": "SafeERC20FailedOperation",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ZeroAmount",
    "inputs": []
  }
] as const satisfies Abi;

export const POOL_ABI = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "_token0",
        "type": "address",
        "internalType": "contract IERC20"
      },
      {
        "name": "_token1",
        "type": "address",
        "internalType": "contract IERC20"
      },
      {
        "name": "_arbGuard",
        "type": "address",
        "internalType": "contract IArbGuard"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "addLiquidity",
    "inputs": [
      {
        "name": "amount0",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "amount1",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "arbGuard",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IArbGuard"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getAmountOut",
    "inputs": [
      {
        "name": "tokenIn",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amountIn",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "lastPrice01",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "lastPrice10",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "lastPriceBlock",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "reserve0",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "reserve1",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "swap",
    "inputs": [
      {
        "name": "tokenIn",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amountIn",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "minAmountOut",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "amountOut",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "token0",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IERC20"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "token1",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IERC20"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "event",
    "name": "LiquidityAdded",
    "inputs": [
      {
        "name": "provider",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amount0",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "amount1",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Swap",
    "inputs": [
      {
        "name": "swapper",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "tokenIn",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amountIn",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "tokenOut",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      },
      {
        "name": "amountOut",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "InsufficientReserves",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidToken",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ReentrancyGuardReentrantCall",
    "inputs": []
  },
  {
    "type": "error",
    "name": "SafeERC20FailedOperation",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "Slippage",
    "inputs": [
      {
        "name": "amountOut",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "minAmountOut",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "ZeroAmount",
    "inputs": []
  }
] as const satisfies Abi;

export const ATTACKER_ABI = [
  {
    "type": "function",
    "name": "approve",
    "inputs": [
      {
        "name": "token",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "spender",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "drainOnly",
    "inputs": [
      {
        "name": "vault",
        "type": "address",
        "internalType": "contract GuardedVault"
      },
      {
        "name": "withdrawAmount",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "maxIterations",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "drainVault",
    "inputs": [
      {
        "name": "vault",
        "type": "address",
        "internalType": "contract GuardedVault"
      },
      {
        "name": "depositAmount",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "withdrawAmount",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "maxIterations",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "pushPriceAndSwap",
    "inputs": [
      {
        "name": "pool",
        "type": "address",
        "internalType": "contract GuardedPool"
      },
      {
        "name": "tokenIn",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amountIn",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "amountOut",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  }
] as const satisfies Abi;

export const TOKEN_ABI = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "name_",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "symbol_",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "allowance",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "spender",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "approve",
    "inputs": [
      {
        "name": "spender",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "value",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "balanceOf",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "decimals",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint8",
        "internalType": "uint8"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "mint",
    "inputs": [
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "name",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "symbol",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "totalSupply",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "transfer",
    "inputs": [
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "value",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "transferFrom",
    "inputs": [
      {
        "name": "from",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "value",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "Approval",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "spender",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "value",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Transfer",
    "inputs": [
      {
        "name": "from",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "to",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "value",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "ERC20InsufficientAllowance",
    "inputs": [
      {
        "name": "spender",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "allowance",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "needed",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC20InsufficientBalance",
    "inputs": [
      {
        "name": "sender",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "balance",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "needed",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC20InvalidApprover",
    "inputs": [
      {
        "name": "approver",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC20InvalidReceiver",
    "inputs": [
      {
        "name": "receiver",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC20InvalidSender",
    "inputs": [
      {
        "name": "sender",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC20InvalidSpender",
    "inputs": [
      {
        "name": "spender",
        "type": "address",
        "internalType": "address"
      }
    ]
  }
] as const satisfies Abi;
