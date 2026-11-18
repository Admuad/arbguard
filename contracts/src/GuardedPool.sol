// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IArbGuard, Action, ActionKind} from "./ArbGuard.sol";

/// @notice Minimal constant-product AMM (x * y = k, NO fee) over two ERC20s.
/// `swap()` computes the execution price and passes kind SWAP with `price`
/// and `twapPrice` to the guard BEFORE any reserve moves, so a price-push
/// swap reverts atomically.
///
/// TWAP SIMPLIFICATION (v1, deliberate): there is no real TWAP oracle.
/// `lastPrice01` / `lastPrice10` store the last execution price per
/// direction (1e18-scaled, tokenOut per tokenIn), updated AT MOST ONCE PER
/// BLOCK — the first successful swap of a new block refreshes the stored
/// price; later swaps in the same block are checked against the stored
/// price. That makes the reference lag by up to one block and makes it
/// gameable by a patient attacker across blocks, which is exactly why a
/// real deployment must plug in a proper TWAP (e.g. Uniswap V2 cumulative
/// prices or a Chainlink feed) as `twapPrice`. For the v1 demo the
/// once-per-block stored price is enough to show the deviation rule
/// firing on a single-block price push. Do NOT treat it as a production
/// oracle.
///
/// The guard is immutable; `address(0)` means unguarded (same pattern as
/// GuardedVault) so the same contract serves the guarded pool and the
/// unguarded control.
contract GuardedPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token0;
    IERC20 public immutable token1;
    IArbGuard public immutable arbGuard;

    uint256 public reserve0;
    uint256 public reserve1;

    /// @notice Last execution price token1-per-token0, 1e18-scaled.
    uint256 public lastPrice01;
    /// @notice Last execution price token0-per-token1, 1e18-scaled.
    uint256 public lastPrice10;
    /// @notice Block the stored prices were last refreshed in.
    uint256 public lastPriceBlock;

    error InvalidToken(address token);
    error ZeroAmount();
    error InsufficientReserves();
    error Slippage(uint256 amountOut, uint256 minAmountOut);

    event LiquidityAdded(address indexed provider, uint256 amount0, uint256 amount1);
    event Swap(address indexed swapper, address indexed tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut);

    constructor(IERC20 _token0, IERC20 _token1, IArbGuard _arbGuard) {
        token0 = _token0;
        token1 = _token1;
        arbGuard = _arbGuard;
    }

    /// @notice Seed (or top up) the pool. The first call also seeds the
    /// TWAP-proxy prices from the initial reserve ratio.
    function addLiquidity(uint256 amount0, uint256 amount1) external nonReentrant {
        if (amount0 == 0 || amount1 == 0) revert ZeroAmount();
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);
        reserve0 += amount0;
        reserve1 += amount1;
        if (lastPrice01 == 0) {
            lastPrice01 = (reserve1 * 1e18) / reserve0;
            lastPrice10 = (reserve0 * 1e18) / reserve1;
            lastPriceBlock = block.number;
        }
        emit LiquidityAdded(msg.sender, amount0, amount1);
    }

    /// @notice Constant-product swap, no fee:
    /// amountOut = amountIn * reserveOut / (reserveIn + amountIn).
    function getAmountOut(address tokenIn, uint256 amountIn) public view returns (uint256) {
        (uint256 reserveIn, uint256 reserveOut) = _reservesFor(tokenIn);
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientReserves();
        return (amountIn * reserveOut) / (reserveIn + amountIn);
    }

    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        (uint256 reserveIn, uint256 reserveOut) = _reservesFor(tokenIn);
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientReserves();
        bool zeroForOne = tokenIn == address(token0);
        IERC20 tokenOut = zeroForOne ? token1 : token0;

        amountOut = (amountIn * reserveOut) / (reserveIn + amountIn);
        if (amountOut < minAmountOut) revert Slippage(amountOut, minAmountOut);
        uint256 price = (amountOut * 1e18) / amountIn;
        uint256 twapPrice = zeroForOne ? lastPrice01 : lastPrice10;

        if (address(arbGuard) != address(0)) {
            arbGuard.check(
                address(this),
                Action({
                    kind: ActionKind.SWAP,
                    token: address(tokenOut),
                    amountOut: amountOut,
                    amountIn: amountIn,
                    price: price,
                    twapPrice: twapPrice,
                    tvl: reserveOut
                })
            );
        }

        if (zeroForOne) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            reserve1 += amountIn;
            reserve0 -= amountOut;
        }

        // TWAP proxy: refresh at most once per block (see header note).
        if (block.number != lastPriceBlock) {
            if (zeroForOne) lastPrice01 = price;
            else lastPrice10 = price;
            lastPriceBlock = block.number;
        }

        if (zeroForOne) {
            token0.safeTransferFrom(msg.sender, address(this), amountIn);
        } else {
            token1.safeTransferFrom(msg.sender, address(this), amountIn);
        }
        tokenOut.safeTransfer(msg.sender, amountOut);
        emit Swap(msg.sender, tokenIn, amountIn, address(tokenOut), amountOut);
    }

    function _reservesFor(address tokenIn) internal view returns (uint256 reserveIn, uint256 reserveOut) {
        if (tokenIn == address(token0)) return (reserve0, reserve1);
        if (tokenIn == address(token1)) return (reserve1, reserve0);
        revert InvalidToken(tokenIn);
    }
}
