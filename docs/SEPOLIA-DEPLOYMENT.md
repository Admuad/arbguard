# ArbGuard — Arbitrum Sepolia deployment

Deployed 20 Nov 2026 ~16:02 WAT (Phase 1) and REDEPLOYED 20 Nov 2026 ~20:20 WAT (Phase 2) by Fred.
Chain: Arbitrum Sepolia (421614). RPC: https://sepolia-rollup.arbitrum.io/rpc
Explorer: https://sepolia.arbiscan.io

## Deployer
- Address: 0xE670974a278A47a0A311dA4Ab780d714acb0EfF0 (fresh testnet-only, created 20 Nov)
- Funded: 0.1 ETH sent by Muhammed (Mises wallet 0x597A...8644) on ETHEREUM Sepolia by mistake,
  then bridged by Fred via Inbox depositEth() (tx 0x0d8612ccaca2a0b66ca06145567531769f29cce949d67be930f3d85dff235927,
  0.099 ETH, L1 status success). Bridged funds landed ~16:02 WAT (~10 min).
- Remaining after Phase 2 redeploy: ~0.0986 ETH.
- Key: ~/workspace/guardrail/sepolia-deployer-key.env + contracts/.env (mode 600, NEVER print/share).

## LIVE deployment (Phase 2, redeployed 20 Nov ~20:20 WAT, deploy block 331140442)
- ArbGuard:        0xef9efc433d6069f6ab7776d8889b8dae6b66146f (23,705 bytes, Phase 2 source)
- mWETH:           0x694dab209bb231bfb2b86737198ee2e2f30bd9ae
- mUSDC:           0x604d40a5d31c821c489fa8a502d27454308835c1
- GuardedVault:    0xfc39b73dbadcaa2bbcfd0faa0043d4ef3ca468db  (policyId 0)
- UnguardedVault:  0xaa4e82a53b09b34e0e4b09d3cf7ffd89dca69695
- GuardedPool:     0x1496cbde3ee3b0cb302f23a7d6a7cace2b57366a  (policyId 1)
- UnguardedPool:   0xb173f9abb169f14d218d8e7d6b83b2ea959f776a
- Attacker:        0x12a0d6356f235361023c7b5a36a1ed73d47195ec
- Keeper:          0xE670974a278A47a0A311dA4Ab780d714acb0EfF0 (deployer)

## Superseded deployment (Phase 1, 20 Nov ~16:02 WAT, deploy block 331084418)
- ArbGuard:        0x9D733954c71920a51291d730fc48422d94d5C306 (22,275 bytes, Phase 1 build)
- mWETH:           0x67984d4a140b32f782A53A76Ba94C1E2aFED299d
- mUSDC:           0xF280b7003291045b114937Cd2CFF3FA502bBAe72
- GuardedVault:    0xEa182E47829D76569dc50CcADD2bFafe462A0E3D  (policyId 0)
- UnguardedVault:  0x68510BE7104F72a40e14ba72dCB2362c5a315148
- GuardedPool:     0x3b1714FE7583789C10528dD43Dbb18729269679E  (policyId 1)
- UnguardedPool:   0x374049DF4b73B381E530805182F94D2cDf0F6826
- Attacker:        0x590180b5Ab993A1Af5bBDa12Ad430a442091B4C1
- These contracts still exist on-chain but are no longer the live deployment; the dashboard and keeper now point at the Phase 2 addresses above.

## Verified live (20 Nov ~20:21 WAT, Phase 2)
- ArbGuard code is 23,705 bytes (Phase 2 source, not the 22,275-byte Phase 1 build).
- GuardedVault holds 1900 mWETH (1000 seed + 900 Attacker deposit).
- GuardedPool holds 1000 mWETH seed liquidity.
- Deploy cost: ~0.0005 ETH.
- Dashboard .env.local and keeper .env updated to the Phase 2 addresses + deploy block 331140442.

## Sepolia oracle state (his decision: REAL Sepolia, no mock)
- Pool uses the real STALE Sepolia ETH/USD Chainlink feed 0xbF13EE58Bf62500FE87e7389faB633ff95dec029.
- Swap checks: CORRECTION 20 Nov ~19:00 WAT (verified live by the coordinator and both Phase 3 implementation agents): the pool pair is UNCONFIGURED (mUSDC has no feed, no TWAP pool), so `getReferencePrice(1, mWETH, mUSDC)` returns `(0, address(0))` and the price rule is SKIPPED — swaps on the deployed Sepolia pool PASS, including a 40% price push. `ORACLE_UNAVAILABLE` only fires for a *configured* pair whose sources read unusable (proven in the SepoliaFork test with a mock USDC feed completing the pair, not on the live deploy). The earlier claim that swaps "fail closed" on this deployment was wrong.
- No USDC/USD feed and no sequencer feed exist on Sepolia.

## Notes
- Contracts NOT verified on Arbiscan yet (no ARBISCAN_API_KEY; --verify not run).
- Adapters NOT deployed to Sepolia (decision, evidence in PHASE3-SPEC.md §5): Arbitrum One addresses have no code there; Aave Sepolia market exists but Pool holds 0 USDC/0 WETH; no verified V3 pool.
- Broadcast log: contracts/broadcast/DeploySepolia.s.sol/421614/run-latest.json (Phase 2 run).
