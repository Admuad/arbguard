import Link from "next/link";

const IMPORT_BLOCK = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ArbGuard} from "arbguard/src/ArbGuard.sol";

contract MyVault {
    ArbGuard public immutable arbGuard;
    uint256 public immutable policyId;

    constructor(address _arbGuard, uint256 _policyId) {
        arbGuard = ArbGuard(_arbGuard);
        policyId = _policyId;
    }
}`;

const REGISTER_BLOCK = `uint256 policyId = arbGuard.registerPolicy(address(myVault), Policy({
    maxOutflowPerBlock:   10 ether,  // max net outflow per block
    maxSingleShareBps:    500,       // max single withdrawal: 5% of TVL
    maxPriceDeviationBps: 500,       // max price move vs TWAP: 5%
    cooldownSeconds:      3600,      // breaker pause: 1 hour
    keeper:               0xYourKeeperAddress,
    enabled:              true
}));`;

const WITHDRAW_CHECK_BLOCK = `function withdraw(uint256 shares) external nonReentrant {
    uint256 assets = previewRedeem(shares);

    arbGuard.check(address(this), Action({
        kind: ActionKind.WITHDRAW,
        token: address(asset),
        amountOut: assets,
        amountIn: 0,
        price: 0,
        twapPrice: 0
    }));

    _burn(msg.sender, shares);
    asset.transfer(msg.sender, assets);
}`;

const SWAP_CHECK_BLOCK = `arbGuard.check(address(this), Action({
    kind: ActionKind.SWAP,
    token: address(tokenOut),
    amountOut: amountOut,
    amountIn: amountIn,
    price: executionPrice,
    twapPrice: twapPrice
}));`;

const TRIP_BLOCK = `// From the keeper or owner account, any time:
arbGuard.trip(policyId, "suspicious outflow spike, investigating");`;

const REVERT_BLOCK = `ArbGuardViolation(OUTFLOW_PER_BLOCK)`;

const TEST_BLOCK = `// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ArbGuard, Policy, Action, ActionKind} from "arbguard/src/ArbGuard.sol";

contract MyVaultGuardedTest is Test {
    ArbGuard arbGuard;
    MyVault vault;
    uint256 policyId;

    function setUp() public {
        arbGuard = new ArbGuard();
        vault = new MyVault(address(arbGuard), 0);
        policyId = arbGuard.registerPolicy(address(vault), Policy({
            maxOutflowPerBlock: 10 ether,
            maxSingleShareBps: 500,
            maxPriceDeviationBps: 500,
            cooldownSeconds: 3600,
            keeper: address(this),
            enabled: true
        }));
        vault.setPolicyId(policyId);
        // ... fund the vault ...
    }

    function test_normalWithdrawPasses() public {
        vault.withdraw(1 ether); // under every cap: must succeed
    }

    function test_drainReverts() public {
        // Loop withdrawals past the per-block cap in one tx:
        // the whole tx must revert and the vault balance must be unchanged.
        uint256 beforeBalance = vault.totalAssets();
        vm.expectRevert();
        vault.drainInOneTx();
        assertEq(vault.totalAssets(), beforeBalance);
    }

    function test_breakerTripPausesAndAutoResumes() public {
        arbGuard.trip(policyId, "test");
        vm.expectRevert();
        vault.withdraw(1 ether);
        vm.warp(block.timestamp + 3601);
        vault.withdraw(1 ether); // cooldown over: works again
    }
}`;

export default function IntegratePage() {
  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-3xl font-bold">Integrate ArbGuard in 10 lines</h1>
        <p className="mt-2 max-w-2xl text-gray-400">
          For a protocol dev. Ten lines, two minutes, one revert that saves
          your TVL. Register a policy (four numbers + a keeper), add one{" "}
          <code className="font-mono text-accent">check()</code> call before
          withdraw or swap. Full guide:{" "}
          <a
            href="https://github.com/Admuad/arbguard/blob/main/docs/INTEGRATION.md"
            target="_blank"
            rel="noreferrer"
            className="font-mono text-accent underline"
          >
            docs/INTEGRATION.md
          </a>{" "}
          (in the repo; the repo is created by the project owner).
        </p>
      </div>

      <Section
        n="1"
        title="Import and wire it up"
        body="Install with forge install Admuad/arbguard (until the repo exists, copy src/ArbGuard.sol into your project). Then import and store the guard + policy id:"
        code={IMPORT_BLOCK}
        lang="solidity"
      />

      <Section
        n="2"
        title="Register a policy"
        body="Register once per protocol (or once per guarded contract). Four numbers + a keeper address. Do this from your owner account, or from the frontend policy form at /policies."
        code={REGISTER_BLOCK}
        lang="solidity"
      />

      <Section
        n="3"
        title="Add the one check() call — before the sensitive action"
        body="This is the whole integration. One call, before any state change or token transfer (check-then-effect, never effect-then-check):"
        code={WITHDRAW_CHECK_BLOCK}
        lang="solidity"
      />

      <Section
        n="4"
        title="For a swap, pass the execution price and the TWAP reference"
        body="So the price-deviation rule can fire:"
        code={SWAP_CHECK_BLOCK}
        lang="solidity"
      />

      <Section
        n="5"
        title="Keeper setup"
        body="The keeper is the address allowed to trip the breaker when something looks wrong. It can be a human (your on-call dev), a multisig, or a monitoring bot — in v1 it is a manual call. While tripped, every guarded action for that policy reverts. The breaker auto-resumes after cooldownSeconds — nobody needs to unpause it at 3 a.m. The owner can end the pause early with reset(policyId) once the threat is confirmed over. Only the owner can reset; the keeper cannot."
        code={TRIP_BLOCK}
        lang="solidity"
      />

      <Section
        n="6"
        title="What the revert looks like"
        body="A blocked transaction reverts with (or PRICE_DEVIATION, SINGLE_SHARE, RESERVE_CONSERVATION, BREAKER_TRIPPED). The revert reason names the rule that fired, and it is visible in the transaction receipt and on Arbiscan. Important: a reverted transaction leaves no persistent event on chain — the EVM rolls back everything, including events. There is no on-chain ViolationBlocked event to subscribe to for a blocked attack."
        code={REVERT_BLOCK}
        lang="text"
      />

      <Section
        n="7"
        title="Test it (Foundry template)"
        body="The ArbGuard repo's own test suite (contracts/test/) is the reference: ArbGuard.t.sol (policy CRUD, access control, cooldown), AttackBlocked.t.sol (drain + price-push blocked on guarded, succeed on unguarded), Breaker.t.sol (trip / auto-resume / reset), Invariants.t.sol (outflow window never exceeded while guarded)."
        code={TEST_BLOCK}
        lang="solidity"
      />

      <p className="text-sm text-gray-400">
        Try it live first:{" "}
        <Link href="/simulator" className="text-accent underline">
          run the attack simulator
        </Link>{" "}
        to watch the same drain revert on the guarded vault and succeed on the
        unguarded one.
      </p>
    </div>
  );
}

function Section({
  n,
  title,
  body,
  code,
  lang,
}: {
  n: string;
  title: string;
  body: string;
  code: string;
  lang: string;
}) {
  return (
    <section className="rounded-lg border border-edge bg-panel p-6">
      <h2 className="text-xl font-bold">
        <span className="font-mono text-accent">{n}.</span> {title}
      </h2>
      <p className="mt-2 text-sm text-gray-300">{body}</p>
      <pre className="mt-4 overflow-x-auto rounded bg-ink p-4 font-mono text-xs leading-relaxed text-gray-200">
        <code data-lang={lang}>{code}</code>
      </pre>
    </section>
  );
}
