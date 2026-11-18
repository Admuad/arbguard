// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mock ERC20 (mock WETH / mock USDC) for tests and the Sepolia demo.
/// Public mint: anyone may mint in this demo environment. 18 decimals.
/// NEVER use as a real token — it has no access control on minting.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
