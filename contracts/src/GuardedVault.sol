// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IArbGuard, Action, ActionKind} from "./ArbGuard.sol";

/// @notice Minimal ERC-4626-style vault holding one ERC20 (mock WETH).
/// Shares are 1:1 with the underlying and tracked in simple storage
/// (deliberately NOT an ERC20 share token — the demo only needs deposit /
/// withdraw accounting). `withdraw()` calls `arbGuard.check(...)` BEFORE
/// any state change; if the guard reverts, the whole withdrawal (and the
/// calling transaction) rolls back.
///
/// The guard is immutable and set in the constructor. `address(0)` means
/// UNGUARDED: the check is skipped, so the SAME contract serves both
/// deployments — the demo's guarded vault and its unguarded control differ
/// only in this constructor argument, never in logic.
contract GuardedVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    IArbGuard public immutable arbGuard;

    mapping(address => uint256) public shares;
    uint256 public totalShares;

    error ZeroAmount();
    error InsufficientShares(uint256 requested, uint256 held);

    event Deposit(address indexed depositor, uint256 amount);
    event Withdraw(address indexed withdrawer, uint256 amount);

    constructor(IERC20 _asset, IArbGuard _arbGuard) {
        asset = _asset;
        arbGuard = _arbGuard;
    }

    function deposit(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        shares[msg.sender] += amount;
        totalShares += amount;
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (shares[msg.sender] < amount) revert InsufficientShares(amount, shares[msg.sender]);
        if (address(arbGuard) != address(0)) {
            arbGuard.check(
                address(this),
                Action({
                    kind: ActionKind.WITHDRAW,
                    token: address(asset),
                    tokenIn: address(0),
                    amountOut: amount,
                    amountIn: 0,
                    price: 0,
                    tvl: asset.balanceOf(address(this)),
                    healthFactorAfter: 0,
                    availableLiquidity: 0
                })
            );
        }
        shares[msg.sender] -= amount;
        totalShares -= amount;
        asset.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }
}
