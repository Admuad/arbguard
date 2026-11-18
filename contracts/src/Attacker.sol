// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GuardedVault} from "./GuardedVault.sol";
import {GuardedPool} from "./GuardedPool.sol";

/// @notice Demo / test helper that performs the two ArbGuard demo attacks.
///
/// HONESTY NOTE — what these attacks are and are NOT:
/// - `drainVault` is a LOOP DRAIN, not ERC777-style reentrancy. The vault
///   holds plain ERC20s (no recipient callback exists), its accounting is
///   correct, and the attacker can only withdraw its own shares. The attack
///   is a burst withdrawal by a large holder: many small withdrawals in a
///   SINGLE transaction, each individually under the single-share limit, but
///   cumulatively over the per-block outflow cap. On the unguarded vault the
///   whole burst succeeds and the vault's balance drops in one block; on
///   the guarded vault the withdrawal that crosses the cap reverts, which
///   rolls back the ENTIRE transaction (deposit included) — the attacker
///   gets nothing and the vault balance is unchanged. That atomicity is
///   the demo: the guard caps the RATE at which value can leave per block,
///   so no single block (compromised key, whale exit, or bug) can empty it.
/// - `pushPriceAndSwap` is a single large swap that moves the pool price
///   far from the stored reference price (e.g. ~50%), i.e. the shape of a
///   flash-loan / oracle-manipulation price push. Unguarded it succeeds;
///   guarded it reverts with PRICE_DEVIATION.
contract Attacker {
    /// @notice Approve `spender` to pull `amount` of `token` from this contract.
    function approve(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }

    /// @notice Deposit `depositAmount` of the vault asset, then loop
    /// `withdraw()` in `withdrawAmount` chunks (up to `maxIterations`,
    /// stopping when shares or vault balance run out). Reverts propagate:
    /// on a guarded vault the guard's revert aborts the whole call.
    function drainVault(GuardedVault vault, uint256 depositAmount, uint256 withdrawAmount, uint256 maxIterations)
        external
    {
        vault.deposit(depositAmount);
        uint256 iterations = 0;
        while (iterations < maxIterations) {
            uint256 myShares = vault.shares(address(this));
            if (myShares == 0) break;
            uint256 vaultBal = vault.asset().balanceOf(address(vault));
            if (vaultBal == 0) break;
            uint256 amount = withdrawAmount > myShares ? myShares : withdrawAmount;
            if (amount > vaultBal) amount = vaultBal;
            vault.withdraw(amount);
            unchecked {
                ++iterations;
            }
        }
    }

    /// @notice Drain-only variant of `drainVault`: loop `withdraw()` in
    /// `withdrawAmount` chunks (up to `maxIterations`) using shares the
    /// caller already holds — no deposit in this call. Used by the Anvil
    /// demo so the deposit (a separate tx) is not rolled back when the
    /// guarded drain reverts.
    function drainOnly(GuardedVault vault, uint256 withdrawAmount, uint256 maxIterations) external {
        uint256 iterations = 0;
        while (iterations < maxIterations) {
            uint256 myShares = vault.shares(address(this));
            if (myShares == 0) break;
            uint256 vaultBal = vault.asset().balanceOf(address(vault));
            if (vaultBal == 0) break;
            uint256 amount = withdrawAmount > myShares ? myShares : withdrawAmount;
            if (amount > vaultBal) amount = vaultBal;
            vault.withdraw(amount);
            unchecked {
                ++iterations;
            }
        }
    }

    /// @notice One large swap that pushes the pool price away from its
    /// reference price. Returns the amount received.
    function pushPriceAndSwap(GuardedPool pool, address tokenIn, uint256 amountIn)
        external
        returns (uint256 amountOut)
    {
        return pool.swap(tokenIn, amountIn, 0);
    }
}
