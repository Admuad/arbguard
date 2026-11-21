// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbGuard, Policy, PriceConfig} from "../src/ArbGuard.sol";
import {AaveAdapter, IPool, IPoolDataProvider, IAaveOracle, AdapterError} from "../src/AaveAdapter.sol";
import {AdapterPolicyHelper} from "../script/DeployAdapters.s.sol";
import {Fixture} from "./Fixture.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAggregatorV3} from "../src/ArbGuard.sol";

/// @notice Minimal variable-debt-token interface (delegation approval).
interface IVariableDebtToken {
    function approveDelegation(address delegatee, uint256 amount) external;
}

/// @notice Aave adapter fork test (spec §5.2): Arbitrum One, pinned block
/// 525,970,897 (20 Nov 2026). Deploys the guard + AaveAdapter against the
/// REAL Aave V3 Pool / PoolDataProvider / AaveOracle and exercises the
/// health-factor and reserve-drain boundaries with real state.
///
/// Run: forge test --match-contract AaveForkTest -vv
/// RPC responses are cached by forge in ~/.foundry/cache, so re-runs are
/// cheap. No key needed — the public Arbitrum One RPC is used.
///
/// Pinned-block state (verified live 20 Nov 2026):
/// - WETH: LTV 8100, liquidation threshold 8400 (84%), decimals 18.
///   AaveOracle $1,660.00611635; Chainlink ETH/USD $1,662.75921904.
/// - USDC: LTV 0 (borrow-only collateral), LT 7800, decimals 6.
///   AaveOracle $0.99982444; Chainlink USDC/USD $0.99987.
/// - Pool balances: 0.1 WETH, ~1,068.54 USDC — see the divergence test.
/// - The Pool is topped up by `deal` to the spec's recorded available
///   values (WETH 47,868, USDC 10,174) so the boundary borrows are
///   feasible; the divergence between the getReserveData formula and the
///   real balance is recorded BEFORE the top-up.
contract AaveForkTest is Fixture {
    string internal constant ARB_ONE_RPC = "https://arb1.arbitrum.io/rpc";
    uint256 internal constant PINNED_BLOCK = 525_970_897;

    address internal constant POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address internal constant DATA_PROVIDER = 0x243Aa95cAC2a25651eda86e80bEe66114413c43b;
    address internal constant AAVE_ORACLE = 0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ETH_USD_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant USDC_USD_FEED = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    // Variable debt tokens (from Pool.getReserveData at the pinned block).
    address internal constant VAR_DEBT_WETH = 0x0c84331e39d6658Cd6e6b9ba04736cC4c4734351;
    address internal constant VAR_DEBT_USDC = 0xf611aEb5013fD2c0511c9CD55c7dc5C1140741A6;
    // aTokens (from Pool.getReserveData at the pinned block).
    address internal constant A_WETH = 0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8;
    address internal constant A_USDC = 0x724dc807b04555b71ed48a6896b6F41593b8C637;

    // Spec §1.3/§1.4 recorded available values (the getReserveData
    // formula's answer at the pinned block). The Pool is topped up to
    // these so the boundary borrows are feasible.
    uint256 internal constant TOP_UP_WETH = 47_868 ether;
    uint256 internal constant TOP_UP_USDC = 10_174e6;

    AaveAdapter internal aave;
    uint256 internal aavePolicyId;
    address internal user = address(0xA11CE);

    function setUp() public override {
        vm.createSelectFork(vm.envOr("ARBITRUM_ONE_RPC_URL", ARB_ONE_RPC), PINNED_BLOCK);
        super.setUp();

        address[] memory reserves = IPool(POOL).getReservesList();
        aave = new AaveAdapter(
            guard,
            IPool(POOL),
            IPoolDataProvider(DATA_PROVIDER),
            IAaveOracle(AAVE_ORACLE),
            reserves
        );
        aavePolicyId = AdapterPolicyHelper.registerAdapterPolicy(
            guard,
            address(aave),
            AdapterPolicyHelper.adapterPolicy(200_000 ether, 1_000_000 ether, 5_000_000 ether, 10_000),
            priceConfig()
        );
        guard.addKeeper(aavePolicyId, keeper);

        // Top up the Pool's real balances to the spec's recorded
        // available values so the boundary borrows are feasible.
        deal(WETH, POOL, TOP_UP_WETH);
        deal(USDC, POOL, TOP_UP_USDC);

        // Fund the user with WETH for collateral.
        deal(WETH, user, 2_000 ether);
        vm.startPrank(user);
        IERC20(WETH).approve(address(aave), type(uint256).max);
        IERC20(USDC).approve(address(aave), type(uint256).max);
        // Aave requires the borrower to delegate borrowing power to the
        // adapter (the adapter is the msg.sender the Pool sees): the user
        // approves the delegation on each variable debt token. Without
        // this the Pool reverts InsufficientBorrowAllowance.
        IVariableDebtToken(VAR_DEBT_WETH).approveDelegation(address(aave), type(uint256).max);
        IVariableDebtToken(VAR_DEBT_USDC).approveDelegation(address(aave), type(uint256).max);
        // The adapter pulls the user's aTokens on withdraw (the Pool
        // burns aTokens from its msg.sender, the adapter), so the user
        // approves the adapter on each aToken once.
        IERC20(A_WETH).approve(address(aave), type(uint256).max);
        IERC20(A_USDC).approve(address(aave), type(uint256).max);
        vm.stopPrank();
    }

    function _supplyWeth(uint256 amount) internal {
        vm.prank(user);
        aave.supply(WETH, amount, user);
    }

    function test_Fork_IsLiveArbitrumOne() public view {
        assertEq(block.chainid, 42161);
        // On Arbitrum, block.number is the L1 height (~26.4M), not the
        // L2 fork block, so the pin is verified by state instead: the
        // AaveOracle WETH price at the pinned block is $1,660.00611635.
        assertEq(IAaveOracle(AAVE_ORACLE).getAssetPrice(WETH), 166000611635);
        assertGt(block.timestamp, 0);
    }

    /// @notice The spec §1.4 divergence, recorded BEFORE any top-up
    /// effect: the getReserveData formula (totalAToken - totalStableDebt
    /// - totalVariableDebt) overstates the Pool's real available
    /// liquidity by ~400x. The adapter reads the real balance
    /// (balanceOf(pool)); this test pins that the adapter's read equals
    /// balanceOf(pool) and records both numbers.
    function test_Fork_AvailableLiquidity_Divergence() public {
        // Read the formula's inputs from the live provider.
        (
            ,
            ,
            uint256 totalAToken,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = IPoolDataProvider(DATA_PROVIDER).getReserveData(WETH);
        uint256 formulaAvailable = totalAToken - totalStableDebt - totalVariableDebt;
        uint256 realBalance = IERC20(WETH).balanceOf(POOL);
        // The adapter's read is the real balance (the top-up is included
        // here because setUp already dealt it; the pre-top-up balance was
        // 0.1 WETH, recorded in the header).
        assertEq(aave.getAvailableLiquidity(WETH), aave.getUsdValue(WETH, realBalance));
        // The formula overstates the real balance by ~400x at the pinned
        // block (47,660 WETH formula vs 0.1 WETH real, before top-up).
        // After the top-up the two are close by construction; the point
        // is the adapter uses the balance, not the formula.
        assertGt(formulaAvailable, 40_000 ether, "formula available is ~47k WETH");
        emit log_named_uint("formula available WETH", formulaAvailable);
        emit log_named_uint("real Pool WETH balance", realBalance);
    }

    /// @notice HF boundary (spec §1.3): 100 WETH collateral, LT 8400.
    /// HF = 84 / N where N is the borrow in WETH. 67 WETH -> 1.254x
    /// (passes the 1.25x floor); 68 WETH -> 1.236x (reverts).
    function test_Fork_HF_Borrow67Passes() public {
        _supplyWeth(100 ether);
        vm.prank(user);
        aave.borrow(WETH, 67 ether, user);
        assertEq(IERC20(WETH).balanceOf(user), 2_000 ether - 100 ether + 67 ether);
    }

    function test_Fork_HF_Borrow68Reverts() public {
        _supplyWeth(100 ether);
        vm.prank(user);
        vm.expectRevert();
        aave.borrow(WETH, 68 ether, user);
    }

    /// @notice The adapter's projected HF matches Aave's own post-action
    /// HF within 1% (spec §1.3): supply 100 WETH, borrow 67 WETH, then
    /// read the Pool's getUserAccountData and compare.
    function test_Fork_ProjectedHF_MatchesAave() public {
        _supplyWeth(100 ether);
        uint256 projected = aave.getProjectedHealthFactor(user, WETH, 67 ether, true);
        vm.prank(user);
        aave.borrow(WETH, 67 ether, user);
        (,,,,, uint256 actualHF) = IPool(POOL).getUserAccountData(user);
        assertApproxEqRel(projected, actualHF, 0.01 ether, "projected HF within 1% of Aave post-action HF");
        assertApproxEqRel(actualHF, 1254e15, 0.01 ether, "post-action HF ~1.254x");
    }

    /// @notice Drain boundary (spec §1.4): 5,000 USDC is 49.1% of the
    /// 10,174 USDC available (passes the 50% cap); 5,100 USDC is 50.1%
    /// (reverts RESERVE_DRAIN). Collateral is 100 WETH, so the HF rule
    /// does not bind (HF ~27.9x).
    function test_Fork_Drain_Borrow5000Passes() public {
        _supplyWeth(100 ether);
        vm.prank(user);
        aave.borrow(USDC, 5_000e6, user);
        assertEq(IERC20(USDC).balanceOf(user), 5_000e6);
    }

    function test_Fork_Drain_Borrow5100Reverts() public {
        _supplyWeth(100 ether);
        vm.prank(user);
        vm.expectRevert();
        aave.borrow(USDC, 5_100e6, user);
    }

    /// @notice Outflow cap (spec §1.2): supply 1,000 WETH, borrow 150
    /// WETH (~$249k) exceeds the $200k per-block cap. HF is ~5.6x and
    /// the drain share is ~0.3%, so the outflow rule is what binds.
    function test_Fork_OutflowCap_Borrow150Reverts() public {
        _supplyWeth(1_000 ether);
        vm.prank(user);
        vm.expectRevert();
        aave.borrow(WETH, 150 ether, user);
    }

    /// @notice A successful collateral withdrawal through the adapter:
    /// supply 100 WETH, borrow 10 WETH (HF ~8.4x), withdraw 10 WETH of
    /// collateral (HF stays ~7.6x, above the floor). The user receives
    /// the underlying and their aWETH is burned; the adapter holds no
    /// aTokens or WETH afterwards.
    function test_Fork_WithdrawCollateral_Passes() public {
        _supplyWeth(100 ether);
        vm.prank(user);
        aave.borrow(WETH, 10 ether, user);
        uint256 aWethBefore = IERC20(A_WETH).balanceOf(user);
        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        vm.prank(user);
        aave.withdraw(WETH, 10 ether, user);
        assertEq(IERC20(WETH).balanceOf(user), wethBefore + 10 ether, "user receives withdrawn WETH");
        assertLt(IERC20(A_WETH).balanceOf(user), aWethBefore, "user aWETH burned");
        assertEq(IERC20(A_WETH).balanceOf(address(aave)), 0, "adapter holds no aWETH");
        assertEq(IERC20(WETH).balanceOf(address(aave)), 0, "adapter holds no WETH");
    }

    /// @notice Withdrawing collateral that pushes the HF below the floor
    /// reverts HEALTH_FACTOR: supply 100 WETH, borrow 50 WETH (HF
    /// 1.68x), then withdraw 50 WETH of collateral -> HF 0.84x.
    function test_Fork_WithdrawCollateral_BelowFloor_Reverts() public {
        _supplyWeth(100 ether);
        vm.prank(user);
        aave.borrow(WETH, 50 ether, user);
        vm.prank(user);
        vm.expectRevert();
        aave.withdraw(WETH, 50 ether, user);
    }

    /// @notice AaveOracle vs Chainlink (spec §6 Q3): the two price
    /// sources agree within 1% for both assets at the pinned block.
    function test_Fork_AaveOracleVsChainlink_WithinOnePercent() public view {
        uint256 aaveWeth = IAaveOracle(AAVE_ORACLE).getAssetPrice(WETH);
        (, int256 linkWeth,,,) = IAggregatorV3(ETH_USD_FEED).latestRoundData();
        assertApproxEqRel(aaveWeth, uint256(linkWeth), 0.01 ether, "WETH AaveOracle vs Chainlink within 1%");
        uint256 aaveUsdc = IAaveOracle(AAVE_ORACLE).getAssetPrice(USDC);
        (, int256 linkUsdc,,,) = IAggregatorV3(USDC_USD_FEED).latestRoundData();
        assertApproxEqRel(aaveUsdc, uint256(linkUsdc), 0.01 ether, "USDC AaveOracle vs Chainlink within 1%");
    }

    /// @notice USDC LTV reads 0 (spec §6 Q5): USDC is borrow-only
    /// collateral on this market — it cannot be used as collateral.
    function test_Fork_UsdcLtvIsZero() public view {
        (uint256 decimals, uint256 ltv, uint256 lt,,,,,,,) =
            IPoolDataProvider(DATA_PROVIDER).getReserveConfigurationData(USDC);
        assertEq(decimals, 6);
        assertEq(ltv, 0, "USDC LTV is 0");
        assertEq(lt, 7800, "USDC liquidation threshold 7800");
    }

    /// @notice Provider getUserAccountData quirk (spec §6 Q6): calling it
    /// on the PoolDataProvider directly reverts, while the Pool's
    /// identical function returns cleanly. The adapter uses the Pool's.
    function test_Fork_ProviderGetUserAccountData_Reverts() public {
        // The Pool's version works (empty account -> HF max).
        (uint256 coll, uint256 debt,,,, uint256 hf) = IPool(POOL).getUserAccountData(user);
        assertEq(coll, 0);
        assertEq(debt, 0);
        assertEq(hf, type(uint256).max);
        // The Provider's version reverts on a direct call.
        (bool ok,) = DATA_PROVIDER.call(
            abi.encodeWithSignature("getUserAccountData(address)", user)
        );
        assertFalse(ok, "Provider getUserAccountData reverts on direct call");
    }
}
