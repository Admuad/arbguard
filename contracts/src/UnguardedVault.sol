// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IArbGuard} from "./ArbGuard.sol";
import {GuardedVault} from "./GuardedVault.sol";

/// @notice The demo's unguarded control: the EXACT same vault logic as
/// GuardedVault, deployed with guard = address(0) so the check is skipped.
/// A thin subclass (not a copy-paste) guarantees the two deployments can
/// never drift apart — the only difference between "guarded" and
/// "unguarded" in the demo is the constructor argument.
contract UnguardedVault is GuardedVault {
    constructor(IERC20 asset) GuardedVault(asset, IArbGuard(address(0))) {}
}
