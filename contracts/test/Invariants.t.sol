// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {GuardedVault} from "../src/GuardedVault.sol";
import {Fixture} from "./Fixture.t.sol";

/// @notice Handler: the invariant fuzzer's actor. It holds its own funds,
/// deposits and withdraws from the guarded vault in bounded amounts, and
/// occasionally advances the block (which resets the outflow window).
/// Deliberately a plain Test contract (NOT the Fixture) so the fuzzer only
/// sees deposit / withdraw / nextBlock as callable targets.
contract GuardedVaultHandler is Test {
    GuardedVault internal targetVault;
    MockERC20 internal asset;

    constructor(GuardedVault _vault, MockERC20 _asset) {
        targetVault = _vault;
        asset = _asset;
        _asset.mint(address(this), 100_000 ether);
        _asset.approve(address(_vault), type(uint256).max);
    }

    function deposit(uint256 seed) public {
        uint256 amount = bound(seed, 0, 100 ether);
        if (amount == 0) return;
        targetVault.deposit(amount);
    }

    function withdraw(uint256 seed) public {
        uint256 held = targetVault.shares(address(this));
        if (held == 0) return;
        uint256 amount = bound(seed, 0, held);
        if (amount == 0) return;
        // May revert when the guard blocks it — that is the system working,
        // not an invariant failure (fail_on_revert = false in foundry.toml).
        targetVault.withdraw(amount);
    }

    function nextBlock() public {
        vm.roll(block.number + 1);
    }
}

contract InvariantsTest is StdInvariant, Fixture {
    GuardedVaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new GuardedVaultHandler(guardedVault, asset);
        targetContract(address(handler));
    }

    /// @notice The guard's recorded per-block outflow never exceeds the
    /// policy cap, no matter what sequence of deposits/withdrawals runs.
    function invariant_outflowNeverExceedsCap() public view {
        assertLe(guard.outflowInBlock(vaultPolicyId), 100 ether);
    }

    /// @notice The vault stays fully backed 1:1 at all times.
    function invariant_vaultFullyBacked() public view {
        assertEq(asset.balanceOf(address(guardedVault)), guardedVault.totalShares());
    }
}
