// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath, TickMath, SqrtPriceMath} from "./libraries/UniswapMath.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/interfaces/IUniswapV3Pool.sol";
import {IArbGuard, Action, ActionKind} from "./ArbGuard.sol";
import {IAaveOracle, AdapterError, AdapterNotConfigured} from "./AaveAdapter.sol";

/// @notice Minimal Uniswap V3 factory interface.
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @notice Minimal NonfungiblePositionManager interface (only the functions used).
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
    function ownerOf(uint256 tokenId) external view returns (address);
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
    function factory() external view returns (address);
}

/// @notice Pass-through guard for Uniswap V3 swaps and NPM positions.
///
/// The user calls the adapter instead of the pool / NPM. The adapter runs
/// `ArbGuard.check()` first, then forwards the call. No custody: tokens
/// flow user → pool and pool → user; the adapter never holds a balance
/// between calls (mint refunds any excess to the caller). Position NFTs
/// belong to `msg.sender` throughout. If the adapter is bypassed, the
/// guard simply does not apply — an opt-in firewall, not a protocol
/// upgrade.
///
/// `swap` / `decreaseLiquidity` / `collect` are guarded. `mintPosition`
/// is INTENTIONALLY UNGUARDED: minting adds liquidity, which can only
/// deepen the pool.
///
/// Units (normative, spec §2.2): for a swap, `price` stays in RAW token
/// units, 1e18-scaled (the Phase 1 price rule compares it against a raw
/// TWAP reference), while `amountOut` / `amountIn` / `tvl` /
/// `availableLiquidity` are USD 1e18 (AaveOracle, the same source as the
/// Aave adapter). The adapter owns this split; the unit tests pin it.
///
/// NO QUOTER (spec §2.1): QuoterV2 is NOT deployed on Arbitrum One at the
/// mainnet address (verified: `cast code` returns 0x), so the adapter
/// computes the expected execution price itself from `slot0` + `liquidity`
/// (§2.4) and never calls a quoter.
///
/// TICK CROSSING (spec §2.4 / §6 Q7): the adapter uses the single-tick
/// approximation (the swap is assumed not to leave the current tick-spacing
/// group, inside which liquidity is constant). If the computed price would
/// leave the group, the adapter reverts `AdapterError("swap crosses tick")`
/// — fail-closed, leaving multi-tick execution to a later phase. The fork
/// test pins this behaviour.
contract UniswapV3Adapter {
    using SafeERC20 for IERC20;

    IArbGuard public immutable guard;
    IUniswapV3Factory public immutable factory;
    INonfungiblePositionManager public immutable npm;
    IAaveOracle public immutable oracle;

    uint256 internal constant USD_1E18_PER_BASE = 1e10;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    constructor(
        IArbGuard _guard,
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _npm,
        IAaveOracle _oracle
    ) {
        if (address(_guard) == address(0)) revert AdapterError("guard is zero address");
        if (address(_factory) == address(0)) revert AdapterError("factory is zero address");
        if (address(_npm) == address(0)) revert AdapterError("npm is zero address");
        if (address(_oracle) == address(0)) revert AdapterError("oracle is zero address");
        guard = _guard;
        factory = _factory;
        npm = _npm;
        oracle = _oracle;
    }

    /// @notice Swap `amountIn` of `tokenIn` through `pool`, sending the
    /// output directly to `msg.sender`. `pool` must be a factory-recognised
    /// pool for its pair/fee. The adapter computes the expected execution
    /// price itself (no quoter), checks it against the guard, then calls
    /// `pool.swap` with the user as recipient. The pool pulls `tokenIn`
    /// from the user via the `uniswapV3SwapCallback` below, so the caller
    /// must have approved the adapter for `amountIn`.
    ///
    /// NOTE (spec §2.3 vs §2.6): §2.3 says the adapter resolves the pool
    /// from the factory "where `fee` is a parameter the caller passes",
    /// but the §2.6 interface carries neither `tokenOut` nor `fee`, so a
    /// `address(0)` pool cannot be resolved from this signature. The
    /// adapter therefore requires a pool address and VERIFIES it against
    /// the factory (reading token0/token1/fee from the pool itself); a
    /// `address(0)` pool reverts `AdapterError`. Callers pass the real
    /// pool address (e.g. the canonical 0.05% pool).
    function swap(address pool, address tokenIn, uint256 amountIn, uint160 sqrtPriceLimitX96)
        external
        returns (uint256 amountOut)
    {
        if (pool == address(0)) revert AdapterError("pool address required");
        (address token0, address token1,) = _verifiedPool(pool);
        if (tokenIn != token0 && tokenIn != token1) revert AdapterError("tokenIn is not in pool");
        bool zeroForOne = tokenIn == token0;
        address tokenOut = zeroForOne ? token1 : token0;

        (uint256 expectedOut, uint256 price) = getExpectedOutput(pool, tokenIn, amountIn);
        _checkSwap(pool, tokenIn, tokenOut, amountIn, expectedOut, price);
        amountOut = _callPoolSwap(pool, tokenIn, zeroForOne, amountIn, sqrtPriceLimitX96);
    }

    /// @notice Execute the pool swap and return the output amount. Split
    /// out of `swap` to keep that function under the compiler's stack
    /// limit. Converts a zero price limit to the pool's bound for the
    /// direction (the pool reverts SPL on a literal 0).
    function _callPoolSwap(address pool, address tokenIn, bool zeroForOne, uint256 amountIn, uint160 sqrtPriceLimitX96)
        internal
        returns (uint256 amountOut)
    {
        uint160 limit = _priceLimit(zeroForOne, sqrtPriceLimitX96);
        bytes memory callbackData = abi.encode(pool, msg.sender, tokenIn);
        (int256 amount0, int256 amount1) =
            IUniswapV3Pool(pool).swap(msg.sender, zeroForOne, int256(amountIn), limit, callbackData);
        // The pool returns signed deltas; the output token's delta is
        // negative (it leaves the pool to the user).
        amountOut = uint256(zeroForOne ? -amount1 : -amount0);
    }

    /// @notice Convert a caller-supplied sqrt price limit to the pool's
    /// bound for the direction when it is 0 ("no limit"). Split out of
    /// `swap` to keep that function under the compiler's stack limit.
    function _priceLimit(bool zeroForOne, uint160 sqrtPriceLimitX96) internal pure returns (uint160) {
        if (sqrtPriceLimitX96 != 0) return sqrtPriceLimitX96;
        return zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
    }

    /// @notice Build the SWAP action and run the guard check. Split out of
    /// `swap` so that function stays under the compiler's stack limit.
    function _checkSwap(
        address pool,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 expectedOut,
        uint256 price
    ) internal {
        uint256 amountOutUsd = getUsdValue(tokenOut, expectedOut);
        uint256 amountInUsd = getUsdValue(tokenIn, amountIn);
        uint256 availUsd = getPoolAvailableLiquidity(pool, tokenOut);
        guard.check(
            address(this),
            Action({
                kind: ActionKind.SWAP,
                token: tokenOut,
                tokenIn: tokenIn,
                amountOut: amountOutUsd,
                amountIn: amountInUsd,
                price: price,
                tvl: availUsd,
                healthFactorAfter: 0, // not applicable to swaps (rule ignores it)
                availableLiquidity: availUsd
            })
        );
    }

    /// @notice V3 swap callback: the pool pulls `tokenIn` from the payer.
    /// Only a factory-verified pool can call this, and only during a swap
    /// this adapter initiated (the pool address is encoded in `data` and
    /// must match `msg.sender`). Pays exactly the positive delta(s).
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        (address pool, address payer, address tokenIn) = abi.decode(data, (address, address, address));
        if (msg.sender != pool) revert AdapterError("callback caller is not the pool");
        (address token0, address token1) = _poolTokens(pool);
        if (amount0Delta > 0) {
            if (tokenIn != token0) revert AdapterError("callback token mismatch");
            IERC20(token0).safeTransferFrom(payer, pool, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            if (tokenIn != token1) revert AdapterError("callback token mismatch");
            IERC20(token1).safeTransferFrom(payer, pool, uint256(amount1Delta));
        }
    }

    /// @notice Remove `liquidity` from NPM position `tokenId`. Treated as a
    /// WITHDRAW: `amountOut` is the USD value removed, `tvl` is the
    /// position's total USD value, so the single-share rule bounds one
    /// removal to a share of that position. The caller must own the
    /// position (checked here) and must have approved the adapter as
    /// operator for the NFT (enforced by the NPM). Removed tokens accrue
    /// as owed to the position; call `collect` to receive them.
    function decreaseLiquidity(uint256 tokenId, uint128 liquidity, uint256 amount0Min, uint256 amount1Min) external {
        _requirePositionOwner(tokenId);
        (uint256 positionValue, uint256 liquidityValue) = _positionValues(tokenId);
        PositionHead memory head = _positionHead(tokenId);
        uint256 removedValue = _removedValue(head, liquidity, liquidityValue);
        guard.check(
            address(this),
            _withdrawAction(head.token0, removedValue, positionValue)
        );
        npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp
            })
        );
    }

    /// @notice Collect owed tokens from NPM position `tokenId` to the
    /// caller. Treated as a WITHDRAW like `decreaseLiquidity`. The caller
    /// must own the position and have approved the adapter.
    function collect(uint256 tokenId, address recipient, uint128 amount0Max, uint128 amount1Max)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (recipient != msg.sender) revert AdapterError("recipient must be msg.sender");
        _requirePositionOwner(tokenId);
        (uint256 positionValue,) = _positionValues(tokenId);
        (uint256 owed0Usd, uint256 owed1Usd) = _owedValues(tokenId, amount0Max, amount1Max);
        PositionHead memory head = _positionHead(tokenId);
        guard.check(
            address(this),
            _withdrawAction(head.token0, owed0Usd + owed1Usd, positionValue)
        );
        (amount0, amount1) = npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: msg.sender,
                amount0Max: amount0Max,
                amount1Max: amount1Max
            })
        );
    }

    /// @notice Mint a new NPM position. INTENTIONALLY UNGUARDED: minting
    /// adds liquidity, which can only deepen the pool. The caller must have
    /// approved the adapter for `amount0Desired` / `amount1Desired`; any
    /// excess over the amounts actually used is refunded to the caller.
    /// The NFT is minted to `msg.sender` (the struct's `recipient` must
    /// be the caller). Takes the NPM `MintParams` struct directly so the
    /// function stays under the compiler's stack limit.
    function mintPosition(INonfungiblePositionManager.MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (params.recipient != msg.sender) revert AdapterError("recipient must be msg.sender");
        IERC20(params.token0).safeTransferFrom(msg.sender, address(this), params.amount0Desired);
        IERC20(params.token1).safeTransferFrom(msg.sender, address(this), params.amount1Desired);
        IERC20(params.token0).forceApprove(address(npm), params.amount0Desired);
        IERC20(params.token1).forceApprove(address(npm), params.amount1Desired);
        (tokenId, liquidity, amount0, amount1) = npm.mint(params);
        // Refund any excess: the NPM only pulls what it uses, so the
        // remainder must not sit in the adapter between calls.
        if (params.amount0Desired > amount0) {
            IERC20(params.token0).safeTransfer(msg.sender, params.amount0Desired - amount0);
        }
        if (params.amount1Desired > amount1) {
            IERC20(params.token1).safeTransfer(msg.sender, params.amount1Desired - amount1);
        }
    }

    /// @notice Resolve a pool from the factory (view helper for the
    /// frontend simulator and the fork tests).
    function resolvePool(address tokenA, address tokenB, uint24 fee) external view returns (address pool) {
        return factory.getPool(tokenA, tokenB, fee);
    }

    /// @notice Expected output of swapping `amountIn` of `tokenIn` through
    /// `pool`, plus the expected execution price (raw token units, 1e18).
    /// The exact function `swap` uses internally, exposed so the frontend
    /// simulator and the fork tests can compare it against the pool's
    /// actual output (within 0.5%). Single-tick approximation; reverts
    /// `AdapterError("swap crosses tick")` if the swap would leave the
    /// current tick-spacing group (multi-tick execution is a later phase).
    function getExpectedOutput(address pool, address tokenIn, uint256 amountIn)
        public
        view
        returns (uint256 amountOut, uint256 price1e18)
    {
        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        uint128 liquidity = IUniswapV3Pool(pool).liquidity();
        if (liquidity == 0) revert AdapterError("no liquidity");
        address token0 = IUniswapV3Pool(pool).token0();
        bool zeroForOne = tokenIn == token0;
        uint24 fee = IUniswapV3Pool(pool).fee();
        // The pool takes its fee from the input; the output is computed
        // on the post-fee amount.
        uint256 amountInAfterFee = (amountIn * (1_000_000 - fee)) / 1_000_000;
        uint160 sqrtNext = SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPriceX96, liquidity, amountInAfterFee, zeroForOne);
        _requireSameTickGroup(pool, tick, sqrtNext, zeroForOne);
        if (zeroForOne) {
            amountOut = SqrtPriceMath.getAmount1Delta(sqrtNext, sqrtPriceX96, liquidity, false);
        } else {
            amountOut = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtNext, liquidity, false);
        }
        price1e18 = (amountOut * 1e18) / amountIn;
    }

    /// @notice Current USD value of NPM position `tokenId`, 1e18-scaled:
    /// the liquidity value at the pool's CURRENT price (a position entirely
    /// out of range is worth its single-token residue) plus the owed fees.
    /// The adapter reads the *current* value, not the deposited value.
    function getPositionValue(uint256 tokenId) public view returns (uint256 valueUsd1e18) {
        (uint256 positionValue,) = _positionValues(tokenId);
        return positionValue;
    }

    /// @notice Pool's available `tokenOut` reserve (its actual token
    /// balance), USD 1e18 — the same ground-truth definition as the Aave
    /// adapter (the pool can only disburse what it holds).
    function getPoolAvailableLiquidity(address pool, address tokenOut)
        public
        view
        returns (uint256 availableUsd1e18)
    {
        return getUsdValue(tokenOut, IERC20(tokenOut).balanceOf(pool));
    }

    /// @notice USD value of `amount` of `asset`, 1e18-scaled, at the
    /// AaveOracle price (shared USD convention with the Aave adapter).
    function getUsdValue(address asset, uint256 amount) public view returns (uint256 usd1e18) {
        uint256 price = oracle.getAssetPrice(asset); // 1e8-scaled USD
        uint256 decimals = IERC20Metadata(asset).decimals();
        return ((amount * price) / (10 ** decimals)) * USD_1E18_PER_BASE;
    }

    // ------------------------------------------------------------ internals
    /// @notice Read a pool's tokens and verify the factory recognises it
    /// for its own fee tier. Reverts AdapterNotConfigured for a pool the
    /// factory does not know.
    function _verifiedPool(address pool)
        internal
        view
        returns (address token0, address token1, uint24 fee)
    {
        (token0, token1) = _poolTokens(pool);
        fee = IUniswapV3Pool(pool).fee();
        if (factory.getPool(token0, token1, fee) != pool) revert AdapterNotConfigured(pool);
    }

    function _poolTokens(address pool) internal view returns (address token0, address token1) {
        token0 = IUniswapV3Pool(pool).token0();
        token1 = IUniswapV3Pool(pool).token1();
    }

    /// @notice The tick-spacing group containing `tick` is
    /// [groupStart, groupStart + spacing); liquidity is constant inside
    /// it (initialised ticks sit on multiples of the spacing). Revert if
    /// the post-swap sqrt price would leave the group.
    function _requireSameTickGroup(address pool, int24 tick, uint160 sqrtNext, bool zeroForOne) internal view {
        int24 spacing = IUniswapV3Pool(pool).tickSpacing();
        int24 groupStart = _floorDiv(tick, spacing) * spacing;
        if (groupStart < MIN_TICK) groupStart = MIN_TICK;
        int24 groupEnd = groupStart + spacing;
        if (groupEnd > MAX_TICK) groupEnd = MAX_TICK;
        if (zeroForOne) {
            // Price falls: the group floor is the binding edge.
            if (sqrtNext < TickMath.getSqrtRatioAtTick(groupStart)) {
                revert AdapterError("swap crosses tick");
            }
        } else {
            // Price rises: the group ceiling is the binding edge.
            if (sqrtNext > TickMath.getSqrtRatioAtTick(groupEnd)) {
                revert AdapterError("swap crosses tick");
            }
        }
    }

    /// @notice Floor division for (possibly negative) ticks.
    function _floorDiv(int24 a, int24 b) internal pure returns (int24) {
        int24 q = a / b;
        if ((a % b != 0) && ((a < 0) != (b < 0))) q -= 1;
        return q;
    }

    /// @notice WITHDRAW action for a position removal / collect. The
    /// health-factor rule is an Aave concept: a Uniswap position carries
    /// no debt, so the adapter passes type(uint256).max ("infinite") —
    /// passing 0 would make any policy with an HF floor reject every
    /// removal. `availableLiquidity` is the position value (same
    /// denominator as tvl, mirroring the Aave adapter).
    function _withdrawAction(address token0, uint256 amountOutUsd, uint256 positionValueUsd)
        internal
        pure
        returns (Action memory)
    {
        return Action({
            kind: ActionKind.WITHDRAW,
            token: token0,
            tokenIn: address(0),
            amountOut: amountOutUsd,
            amountIn: 0,
            price: 0,
            tvl: positionValueUsd,
            healthFactorAfter: type(uint256).max,
            availableLiquidity: positionValueUsd
        });
    }

    function _requirePositionOwner(uint256 tokenId) internal view {
        if (npm.ownerOf(tokenId) != msg.sender) revert AdapterError("caller does not own position");
    }

    /// @notice Position head fields (token0/token1/fee/ticks/liquidity/owed).
    struct PositionHead {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    function _positionHead(uint256 tokenId) internal view returns (PositionHead memory head) {
        (
            ,
            ,
            head.token0,
            head.token1,
            head.fee,
            head.tickLower,
            head.tickUpper,
            head.liquidity,
            ,
            ,
            head.tokensOwed0,
            head.tokensOwed1
        ) = npm.positions(tokenId);
    }

    /// @notice (total position value, liquidity-only value), both USD 1e18.
    /// The liquidity value excludes owed fees; the total includes them.
    function _positionValues(uint256 tokenId)
        internal
        view
        returns (uint256 positionValue, uint256 liquidityValue)
    {
        PositionHead memory head = _positionHead(tokenId);
        address pool = factory.getPool(head.token0, head.token1, head.fee);
        if (pool == address(0)) revert AdapterNotConfigured(pool);
        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        uint256 amount0;
        uint256 amount1;
        if (tick < head.tickLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtRatioAtTick(head.tickLower),
                TickMath.getSqrtRatioAtTick(head.tickUpper),
                head.liquidity,
                false
            );
        } else if (tick >= head.tickUpper) {
            amount1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(head.tickLower),
                TickMath.getSqrtRatioAtTick(head.tickUpper),
                head.liquidity,
                false
            );
        } else {
            amount0 = SqrtPriceMath.getAmount0Delta(
                sqrtPriceX96, TickMath.getSqrtRatioAtTick(head.tickUpper), head.liquidity, false
            );
            amount1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(head.tickLower), sqrtPriceX96, head.liquidity, false
            );
        }
        liquidityValue = getUsdValue(head.token0, amount0) + getUsdValue(head.token1, amount1);
        positionValue =
            liquidityValue + getUsdValue(head.token0, head.tokensOwed0) + getUsdValue(head.token1, head.tokensOwed1);
    }

    /// @notice USD value of the liquidity being removed (proportional to
    /// the liquidity-only value, not the fee-inclusive total).
    function _removedValue(PositionHead memory head, uint128 liquidityToRemove, uint256 liquidityValue)
        internal
        pure
        returns (uint256)
    {
        if (head.liquidity == 0) return 0;
        return (liquidityValue * liquidityToRemove) / head.liquidity;
    }

    /// @notice USD value of the fees being collected, capped by the
    /// requested maxima.
    function _owedValues(uint256 tokenId, uint128 amount0Max, uint128 amount1Max)
        internal
        view
        returns (uint256 owed0Usd, uint256 owed1Usd)
    {
        PositionHead memory head = _positionHead(tokenId);
        uint256 collect0 = amount0Max > head.tokensOwed0 ? head.tokensOwed0 : amount0Max;
        uint256 collect1 = amount1Max > head.tokensOwed1 ? head.tokensOwed1 : amount1Max;
        owed0Usd = getUsdValue(head.token0, collect0);
        owed1Usd = getUsdValue(head.token1, collect1);
    }
}
