// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "./libraries/UniswapMath.sol";
import {IArbGuard, Action, ActionKind} from "./ArbGuard.sol";

/// @notice Minimal Aave V3 Pool interface (only the functions used).
interface IPool {
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
    function getReservesList() external view returns (address[] memory);
}

/// @notice Minimal Aave V3 PoolDataProvider interface (only the functions used).
interface IPoolDataProvider {
    function getReserveData(address asset)
        external
        view
        returns (
            uint256 unbacked,
            uint256 accruedToTreasuryScaled,
            uint256 totalAToken,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            uint256 liquidityRate,
            uint256 variableBorrowRate,
            uint256 stableBorrowRate,
            uint256 averageStableBorrowRate,
            uint256 liquidityIndex,
            uint256 variableBorrowIndex,
            uint40 lastUpdateTimestamp
        );
    function getReservesList() external view returns (address[] memory);
    function getReserveTokensAddresses(address asset)
        external
        view
        returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress);
    function getReserveConfigurationData(address asset)
        external
        view
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool flashLoanEnabled,
            bool siloedBorrowingEnabled
        );
}

/// @notice Minimal AaveOracle interface.
interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

error AdapterError(string reason);
error AdapterNotConfigured(address asset);

/// @notice Pass-through guard for Aave V3 (Arbitrum One market).
///
/// The user calls the adapter instead of the Pool. The adapter runs
/// `ArbGuard.check()` first, then forwards the call unchanged. The adapter
/// holds no funds and keeps no balances: borrowed tokens go to the user
/// directly, withdrawn collateral goes to the user directly, and aTokens /
/// debt are booked to the user, never to the adapter. If the adapter is
/// bypassed (the user calls the Pool directly), the guard simply does not
/// apply — the adapter is an opt-in firewall, not a protocol upgrade.
///
/// `borrow` / `withdraw` are guarded. `supply` / `repay` are INTENTIONALLY
/// UNGUARDED: repaying can only improve a health factor, and supplying can
/// only improve it. Calling `check()` for them would spend gas to prove a
/// tautology. They are plain pass-throughs so a user can do their whole
/// flow through one contract.
///
/// Units (normative, spec §1.2): for adapter policies, `amountOut`, `tvl`
/// and `availableLiquidity` are USD 1e18, and the policy caps are
/// denominated in USD. The policy must be registered with
/// `usdDenominated == true` (the deploy-script helper enforces this).
///
/// AVAILABLE LIQUIDITY (spec §1.4 deviation, verified live 20 Nov 2026):
/// the spec says to read available as `totalAToken - totalStableDebt -
/// totalVariableDebt` from `getReserveData` and asserts it equals
/// `IERC20(asset).balanceOf(pool)`. Live reads show they DIVERGE by ~400x:
/// at block 525,970,897 the formula gives ~47,660 WETH / ~47,296 USDC
/// while the Pool actually holds 0.1 WETH / 1,068 USDC. The Pool can only
/// disburse what it holds — `borrow` checks its own token balance — so
/// the formula overstates what can leave and would let `check()` pass a
/// borrow the Pool cannot fulfil. The adapter therefore reads available
/// liquidity as the Pool's actual token balance, the ground truth for
/// "what can leave right now". The fork test records both numbers and
/// asserts the adapter's read equals `balanceOf(pool)`.
contract AaveAdapter {
    using SafeERC20 for IERC20;

    IArbGuard public immutable guard;
    IPool public immutable pool;
    IPoolDataProvider public immutable dataProvider;
    IAaveOracle public immutable oracle;

    /// @notice Reserve allowlist, set at deployment from
    /// `Pool.getReservesList()` (the deploy script derives it; the
    /// constructor takes it as an argument so the adapter never calls
    /// the Pool in its constructor). Immutable: adding a reserve means
    /// deploying a new adapter.
    mapping(address => bool) public isReserve;

    /// @notice AaveOracle prices are 1e8-scaled USD (BASE_CURRENCY_UNIT).
    uint256 internal constant ORACLE_SCALE = 1e8;
    /// @notice USD values are 1e18-scaled; Aave base currency is 1e8.
    uint256 internal constant USD_1E18_PER_BASE = 1e10;

    constructor(
        IArbGuard _guard,
        IPool _pool,
        IPoolDataProvider _dataProvider,
        IAaveOracle _oracle,
        address[] memory reserves
    ) {
        if (address(_guard) == address(0)) revert AdapterError("guard is zero address");
        if (address(_pool) == address(0)) revert AdapterError("pool is zero address");
        if (address(_dataProvider) == address(0)) revert AdapterError("data provider is zero address");
        if (address(_oracle) == address(0)) revert AdapterError("oracle is zero address");
        guard = _guard;
        pool = _pool;
        dataProvider = _dataProvider;
        oracle = _oracle;
        for (uint256 i = 0; i < reserves.length; i++) {
            isReserve[reserves[i]] = true;
        }
    }

    /// @notice Borrow `amount` of `asset` (variable rate only) for the
    /// caller. Debt is booked to `msg.sender` and the borrowed tokens are
    /// sent to `msg.sender` by the Pool. The adapter always passes
    /// interestRateMode 2 (variable); stable borrowing is disabled on this
    /// market and the adapter never requests it.
    function borrow(address asset, uint256 amount, address onBehalfOf) external {
        if (onBehalfOf != msg.sender) revert AdapterError("onBehalfOf must be msg.sender");
        if (!isReserve[asset]) revert AdapterNotConfigured(asset);
        uint256 amountUsd = getUsdValue(asset, amount);
        uint256 availUsd = getAvailableLiquidity(asset);
        uint256 hfAfter = getProjectedHealthFactor(msg.sender, asset, amount, true);
        guard.check(
            address(this),
            Action({
                kind: ActionKind.BORROW,
                token: asset,
                tokenIn: address(0),
                amountOut: amountUsd,
                amountIn: 0,
                price: 0,
                tvl: availUsd,
                healthFactorAfter: hfAfter,
                availableLiquidity: availUsd
            })
        );
        // NOTE (spec §1.2 forwarding correction, fork-verified 20 Nov
        // 2026): the spec states "the borrowed tokens are sent to
        // msg.sender" and "the adapter never receives tokens". That is
        // NOT how Aave V3 works. The Pool sends borrowed funds to ITS
        // msg.sender — the adapter — while the debt is booked to
        // onBehalfOf. Proven on an Arbitrum One fork: a middleman
        // borrowing onBehalfOf a user receives the funds itself, the user
        // receives nothing. So the adapter MUST forward the borrowed
        // amount to the caller, or the user's funds would strand in the
        // adapter. The forward below is the correction; the interface and
        // the "adapter holds no funds between calls" intent are unchanged.
        pool.borrow(asset, amount, 2, 0, msg.sender);
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    /// @notice Withdraw `amount` of `asset` collateral to the caller.
    function withdraw(address asset, uint256 amount, address to) external {
        if (to != msg.sender) revert AdapterError("to must be msg.sender");
        if (!isReserve[asset]) revert AdapterNotConfigured(asset);
        uint256 amountUsd = getUsdValue(asset, amount);
        uint256 availUsd = getAvailableLiquidity(asset);
        uint256 hfAfter = getProjectedHealthFactor(msg.sender, asset, amount, false);
        guard.check(
            address(this),
            Action({
                kind: ActionKind.WITHDRAW,
                token: asset,
                tokenIn: address(0),
                amountOut: amountUsd,
                amountIn: 0,
                price: 0,
                tvl: availUsd,
                healthFactorAfter: hfAfter,
                availableLiquidity: availUsd
            })
        );
        // NOTE (spec §1.2 forwarding correction, fork-verified 20 Nov
        // 2026): the spec states "the Pool's withdraw(asset, amount,
        // msg.sender) sends the underlying to the user" and "the adapter
        // never receives tokens". That is NOT how Aave V3 works. The Pool
        // burns aTokens from ITS msg.sender — the adapter — and sends the
        // underlying to `to`. The adapter holds no aTokens (they were
        // minted to the user by `supply`), so a bare
        // pool.withdraw(asset, amount, msg.sender) reverts: the Pool
        // tries to burn aTokens the adapter does not have (fork-verified).
        // So the adapter must first pull the user's aTokens, then call
        // pool.withdraw(asset, amount, msg.sender), then sweep any
        // rounding dust back to the caller. The user must approve the
        // adapter on the aToken once, exactly as they approve it on the
        // underlying for `supply`. The interface and the "adapter holds
        // no funds between calls" intent are unchanged.
        //
        // The pull transfers the UNDERLYING `amount`, NOT a pre-scaled
        // amount: the aToken's transferFrom takes the underlying amount
        // and divides by the liquidity index internally
        // (ScaledBalanceTokenBase._transfer does
        // amount.rayDiv(index)). Passing a pre-scaled amount divides
        // twice and the adapter receives amount/index scaled aTokens,
        // which is short of what the Pool's validateWithdraw needs
        // (fork-verified 20 Nov 2026: a 10 WETH withdraw reverted
        // NotEnoughAvailableUserBalance on a pre-scaled pull, and
        // passes on the underlying-amount pull).
        address aToken = _aTokenAddress(asset);
        IERC20(aToken).safeTransferFrom(msg.sender, address(this), amount);
        pool.withdraw(asset, amount, msg.sender);
        uint256 dust = IERC20(aToken).balanceOf(address(this));
        if (dust > 0) IERC20(aToken).safeTransfer(msg.sender, dust);
    }

    /// @notice aToken address for a reserve, via the PoolDataProvider.
    function _aTokenAddress(address asset) internal view returns (address aToken) {
        (aToken,,) = dataProvider.getReserveTokensAddresses(asset);
    }

    /// @notice Supply `amount` of `asset` on behalf of `onBehalfOf`.
    /// INTENTIONALLY UNGUARDED (see header): supplying can only improve a
    /// health factor. The adapter pulls the tokens from the caller, so the
    /// caller must have approved the adapter; nothing is retained between
    /// calls. The aTokens are minted to `onBehalfOf`.
    function supply(address asset, uint256 amount, address onBehalfOf) external {
        if (!isReserve[asset]) revert AdapterNotConfigured(asset);
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(address(pool), amount);
        pool.supply(asset, amount, onBehalfOf, 0);
    }

    /// @notice Repay `amount` of `asset` debt on behalf of `onBehalfOf`
    /// (variable rate). INTENTIONALLY UNGUARDED (see header): repaying can
    /// only improve a health factor. The adapter pulls the tokens from the
    /// caller; nothing is retained between calls.
    function repay(address asset, uint256 amount, address onBehalfOf) external {
        if (!isReserve[asset]) revert AdapterNotConfigured(asset);
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(address(pool), amount);
        pool.repay(asset, amount, 2, onBehalfOf);
    }

    /// @notice Projected post-action health factor, 1e18-scaled, computed
    /// from the Pool's own current account data plus the action's amounts
    /// — the exact function `borrow`/`withdraw` use internally, exposed so
    /// the frontend simulator and the fork tests can compare it against
    /// Aave's post-action `getUserAccountData` (must agree within 1%).
    /// `isBorrow == true` adds the amount to debt; false removes it from
    /// collateral. `debtAfter == 0` returns type(uint256).max (infinite);
    /// `collateralAfter == 0` with debt returns 0.
    function getProjectedHealthFactor(address user, address asset, uint256 amount, bool isBorrow)
        public
        view
        returns (uint256 healthFactorAfter)
    {
        (uint256 totalCollateralBase, uint256 totalDebtBase,, uint256 threshold,,) = pool.getUserAccountData(user);
        uint256 amountBase = _usdValueBase(asset, amount);
        uint256 collateralAfter;
        uint256 debtAfter;
        if (isBorrow) {
            collateralAfter = totalCollateralBase;
            debtAfter = totalDebtBase + amountBase;
        } else {
            // Saturate instead of reverting: withdrawing more collateral
            // value than the account holds leaves zero collateral, which
            // the health-factor rule then rejects (HF 0) if any debt
            // remains — a clean HEALTH_FACTOR revert, not an arithmetic
            // panic.
            collateralAfter = totalCollateralBase > amountBase ? totalCollateralBase - amountBase : 0;
            debtAfter = totalDebtBase;
        }
        if (debtAfter == 0) return type(uint256).max;
        // HF = collateral * threshold / debt, 1e18-scaled:
        // (collateralAfter * threshold * 1e18) / (debtAfter * 10000).
        // Aave's own formula is (collateral.percentMul(threshold)).div(debt)
        // with WadRayMath.div (1e18-scaled) — identical.
        return FullMath.mulDiv(collateralAfter, threshold * 1e18, debtAfter * 10_000);
    }

    /// @notice Reserve available liquidity, USD 1e18: the Pool's actual
    /// token balance, converted at the AaveOracle price. See the header
    /// note for why the balance (not the getReserveData formula) is used.
    function getAvailableLiquidity(address asset) public view returns (uint256 availableUsd1e18) {
        uint256 available = IERC20(asset).balanceOf(address(pool));
        return getUsdValue(asset, available);
    }

    /// @notice USD value of `amount` of `asset`, 1e18-scaled, at the
    /// AaveOracle price (the same source Aave uses for health factors).
    function getUsdValue(address asset, uint256 amount) public view returns (uint256 usd1e18) {
        return _usdValueBase(asset, amount) * USD_1E18_PER_BASE;
    }

    /// @notice USD value of `amount` of `asset` in Aave base-currency
    /// units (1e8-scaled), the unit `getUserAccountData` reports in.
    function _usdValueBase(address asset, uint256 amount) internal view returns (uint256) {
        uint256 price = oracle.getAssetPrice(asset); // 1e8-scaled USD
        uint256 decimals = IERC20Metadata(asset).decimals();
        return (amount * price) / (10 ** decimals);
    }
}
