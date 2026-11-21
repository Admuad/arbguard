// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {INonfungiblePositionManager} from "../src/UniswapV3Adapter.sol";
import {SqrtPriceMath, TickMath} from "../src/libraries/UniswapMath.sol";

/// @notice Test-only mocks for the Phase 2 adapters. Never in src/.
/// MockAavePool / MockPoolDataProvider / MockAaveOracle: scriptable Aave
/// V3 market. MockV3Pool / MockV3Factory / MockNPM: scriptable Uniswap V3.

contract MockAavePool {
    using SafeERC20 for IERC20;

    // Scriptable account data (base units, 1e8-scaled USD).
    uint256 public collateralBase;
    uint256 public debtBase;
    uint256 public availableBorrowsBase;
    uint256 public liquidationThreshold;
    uint256 public ltv;
    uint256 public healthFactor;

    // Last borrow call (for assertions).
    address public lastBorrowAsset;
    uint256 public lastBorrowAmount;
    uint256 public lastBorrowMode;
    address public lastBorrowOnBehalfOf;
    uint256 public borrowCalls;

    // Last withdraw / supply / repay calls.
    address public lastWithdrawAsset;
    uint256 public lastWithdrawAmount;
    address public lastWithdrawTo;
    address public lastSupplyAsset;
    uint256 public lastSupplyAmount;
    address public lastSupplyOnBehalfOf;
    address public lastRepayAsset;
    uint256 public lastRepayAmount;
    uint256 public lastRepayMode;

    address[] public reserves;
    mapping(address => address) public aTokens;

    constructor(address[] memory _reserves) {
        reserves = _reserves;
        healthFactor = type(uint256).max;
    }

    function setAToken(address asset, address aToken) external {
        aTokens[asset] = aToken;
    }

    function setAccountData(
        uint256 _collateralBase,
        uint256 _debtBase,
        uint256 _availableBorrowsBase,
        uint256 _liquidationThreshold,
        uint256 _ltv,
        uint256 _healthFactor
    ) external {
        collateralBase = _collateralBase;
        debtBase = _debtBase;
        availableBorrowsBase = _availableBorrowsBase;
        liquidationThreshold = _liquidationThreshold;
        ltv = _ltv;
        healthFactor = _healthFactor;
    }

    function getUserAccountData(address)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrows,
            uint256 currentLiquidationThreshold,
            uint256 ltv_,
            uint256 healthFactor_
        )
    {
        return (collateralBase, debtBase, availableBorrowsBase, liquidationThreshold, ltv, healthFactor);
    }

    function getReservesList() external view returns (address[] memory) {
        return reserves;
    }

    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16, address onBehalfOf) external {
        lastBorrowAsset = asset;
        lastBorrowAmount = amount;
        lastBorrowMode = interestRateMode;
        lastBorrowOnBehalfOf = onBehalfOf;
        borrowCalls++;
        // The real Pool sends borrowed funds to ITS msg.sender (the
        // adapter), while the debt is booked to onBehalfOf. The adapter
        // forwards them to the user. (Fork-verified 20 Nov 2026.)
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        lastWithdrawAsset = asset;
        lastWithdrawAmount = amount;
        lastWithdrawTo = to;
        // The real Pool burns aTokens from ITS msg.sender (the adapter)
        // and sends the underlying to `to`. The adapter pulls the user's
        // aTokens first, so the burn here consumes them. The mock aToken
        // is a plain ERC20 (not scaled), so the burn is the underlying
        // amount the adapter transferred.
        address aToken = aTokens[asset];
        if (aToken != address(0)) {
            MockERC20(aToken).burn(msg.sender, amount);
        }
        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        lastSupplyAsset = asset;
        lastSupplyAmount = amount;
        lastSupplyOnBehalfOf = onBehalfOf;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    }

    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256)
    {
        lastRepayAsset = asset;
        lastRepayAmount = amount;
        lastRepayMode = interestRateMode;
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        return amount;
    }
}

contract MockPoolDataProvider {
    uint256 public totalAToken;
    uint256 public totalStableDebt;
    uint256 public totalVariableDebt;
    mapping(address => address) public aTokens;

    function setAToken(address asset, address aToken) external {
        aTokens[asset] = aToken;
    }

    function getReserveTokensAddresses(address asset)
        external
        view
        returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress)
    {
        return (aTokens[asset], address(0), address(0));
    }

    function setReserveData(uint256 _totalAToken, uint256 _totalStableDebt, uint256 _totalVariableDebt) external {
        totalAToken = _totalAToken;
        totalStableDebt = _totalStableDebt;
        totalVariableDebt = _totalVariableDebt;
    }

    function getReserveData(address)
        external
        view
        returns (
            uint256 unbacked,
            uint256 accruedToTreasuryScaled,
            uint256 totalAToken_,
            uint256 totalStableDebt_,
            uint256 totalVariableDebt_,
            uint256 liquidityRate,
            uint256 variableBorrowRate,
            uint256 stableBorrowRate,
            uint256 averageStableBorrowRate,
            uint256 liquidityIndex,
            uint256 variableBorrowIndex,
            uint40 lastUpdateTimestamp
        )
    {
        return (0, 0, totalAToken, totalStableDebt, totalVariableDebt, 0, 0, 0, 0, 1e27, 1e27, 0);
    }

    function getReservesList() external pure returns (address[] memory) {
        return new address[](0);
    }
}

contract MockAaveOracle {
    mapping(address => uint256) public prices;

    function setPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        return prices[asset];
    }
}

/// @notice Mock Uniswap V3 pool: scriptable slot0 / liquidity / TWAP tick
/// and a simple fixed-price swap. `swapPrice` is token1 per token0 in 1e18
/// (so amountOut = amountIn * swapPrice / 1e18 for zeroForOne).
contract MockV3Pool {
    using SafeERC20 for IERC20;

    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;
    uint160 public sqrtPriceX96;
    int24 public tick;
    uint128 public liquidity;
    int24 public twapTick;
    uint256 public swapPrice; // token1 per token0, 1e18
    bool public revertOnObserve;

    constructor(address _token0, address _token1, uint24 _fee, int24 _tickSpacing) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;
        sqrtPriceX96 = 79228162514264337593543950336; // 1.0
        tick = 0;
        twapTick = 0;
        swapPrice = 1 ether;
        liquidity = 1000 ether;
    }

    function setSlot0(uint160 _sqrtPriceX96, int24 _tick) external {
        sqrtPriceX96 = _sqrtPriceX96;
        tick = _tick;
    }

    function setLiquidity(uint128 _liquidity) external {
        liquidity = _liquidity;
    }

    function setTwapTick(int24 t) external {
        twapTick = t;
    }

    function setSwapPrice(uint256 p) external {
        swapPrice = p;
    }

    function setRevert(bool r) external {
        revertOnObserve = r;
    }

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96_,
            int24 tick_,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (sqrtPriceX96, tick, 0, 1, 1, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint256[] memory secondsPerLiquidityCumulativeX128)
    {
        if (revertOnObserve) revert("OLD");
        uint32 window = secondsAgos[0];
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = int56(twapTick) * int56(int32(window));
        tickCumulatives[1] = 0;
        secondsPerLiquidityCumulativeX128 = new uint256[](2);
        return (tickCumulatives, secondsPerLiquidityCumulativeX128);
    }

    /// @notice Fixed-price swap: pulls tokenIn from the caller via the
    /// V3 callback and pays tokenOut to `recipient` at `swapPrice`.
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "mock: exact input only");
        uint256 amountIn = uint256(amountSpecified);
        uint256 amountOut;
        if (zeroForOne) {
            amountOut = amountIn * swapPrice / 1e18;
            amount0 = int256(amountIn);
            amount1 = -int256(amountOut);
            // Callback pulls token0 from the caller.
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            IERC20(token1).safeTransfer(recipient, amountOut);
        } else {
            amountOut = amountIn * 1e18 / swapPrice;
            amount0 = -int256(amountOut);
            amount1 = int256(amountIn);
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            IERC20(token0).safeTransfer(recipient, amountOut);
        }
    }
}

interface IUniswapV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

contract MockV3Factory {
    mapping(bytes32 => address) public pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pools[keccak256(abi.encode(t0, t1, fee))] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return pools[keccak256(abi.encode(t0, t1, fee))];
    }
}

/// @notice Mock NPM: scriptable positions with an owner, liquidity and
/// owed tokens. decreaseLiquidity moves value to tokensOwed; collect pays
/// them out; mint creates a position and pulls tokens from the caller.
contract MockNPM {
    using SafeERC20 for IERC20;

    struct Position {
        address owner;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    mapping(uint256 => Position) public positionsMap;
    uint256 public nextTokenId = 1;
    // Current pool price (sqrtPriceX96) and tick the mock uses to value
    // positions. Defaults to 1.0 / tick 0; set them to the pool's slot0
    // values for consistency.
    uint160 public sqrtPriceX96 = 79228162514264337593543950336; // 2^96 = 1.0
    int24 public poolTick;

    function setPoolPrice(uint160 _sqrtPriceX96, int24 _tick) external {
        sqrtPriceX96 = _sqrtPriceX96;
        poolTick = _tick;
    }

    function setPosition(
        uint256 tokenId,
        address owner,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 tokensOwed0,
        uint128 tokensOwed1
    ) external {
        positionsMap[tokenId] = Position({
            owner: owner,
            token0: token0,
            token1: token1,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            tokensOwed0: tokensOwed0,
            tokensOwed1: tokensOwed1
        });
        if (tokenId >= nextTokenId) nextTokenId = tokenId + 1;
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
        )
    {
        Position storage p = positionsMap[tokenId];
        return (
            0,
            address(0),
            p.token0,
            p.token1,
            p.fee,
            p.tickLower,
            p.tickUpper,
            p.liquidity,
            0,
            0,
            p.tokensOwed0,
            p.tokensOwed1
        );
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return positionsMap[tokenId].owner;
    }

    /// @notice Remove liquidity and accrue the removed tokens as owed.
    /// The amounts are computed with real V3 math from the position's
    /// ticks and the mock's pool price, so they are consistent with the
    /// adapter's own position valuation (the adapter and the mock must
    /// agree on what a removal is worth, or the guard's single-share
    /// check sees a phantom value).
    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage p = positionsMap[params.tokenId];
        require(p.liquidity >= params.liquidity, "mock: insufficient liquidity");
        (amount0, amount1) = _amountsForLiquidity(p, params.liquidity);
        p.liquidity -= params.liquidity;
        p.tokensOwed0 += uint128(amount0);
        p.tokensOwed1 += uint128(amount1);
    }

    /// @notice Token amounts for `liquidity` of position `p` at the mock's
    /// pool price (the same SqrtPriceMath the adapter uses).
    function _amountsForLiquidity(Position storage p, uint128 liquidity)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        int24 tick = poolTick;
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(p.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(p.tickUpper);
        if (tick < p.tickLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, false);
        } else if (tick >= p.tickUpper) {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, false);
        } else {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, false);
        }
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage p = positionsMap[params.tokenId];
        amount0 = params.amount0Max > p.tokensOwed0 ? p.tokensOwed0 : params.amount0Max;
        amount1 = params.amount1Max > p.tokensOwed1 ? p.tokensOwed1 : params.amount1Max;
        p.tokensOwed0 -= uint128(amount0);
        p.tokensOwed1 -= uint128(amount1);
        if (amount0 > 0) IERC20(p.token0).safeTransfer(params.recipient, amount0);
        if (amount1 > 0) IERC20(p.token1).safeTransfer(params.recipient, amount1);
    }

    function mint(INonfungiblePositionManager.MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        tokenId = nextTokenId++;
        liquidity = uint128(params.amount0Desired + params.amount1Desired) / 2;
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;
        positionsMap[tokenId] = Position({
            owner: params.recipient,
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            tokensOwed0: 0,
            tokensOwed1: 0
        });
        IERC20(params.token0).safeTransferFrom(msg.sender, address(this), params.amount0Desired);
        IERC20(params.token1).safeTransferFrom(msg.sender, address(this), params.amount1Desired);
    }
}
