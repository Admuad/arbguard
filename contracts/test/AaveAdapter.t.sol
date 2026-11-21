// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ArbGuard, Policy, PriceConfig} from "../src/ArbGuard.sol";
import {
    AaveAdapter,
    AdapterError,
    AdapterNotConfigured,
    IPool,
    IPoolDataProvider,
    IAaveOracle
} from "../src/AaveAdapter.sol";
import {AdapterPolicyHelper} from "../script/DeployAdapters.s.sol";
import {Fixture} from "./Fixture.t.sol";
import {MockAavePool, MockPoolDataProvider, MockAaveOracle} from "./AdapterMocks.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice Aave adapter unit tests (spec §5.1) with a mock Aave market.
/// Prices mirror the live Arbitrum One read (20 Nov 2026): WETH $1,660.01,
/// USDC $0.99982 (AaveOracle, 1e8-scaled). The mock account's liquidation
/// threshold is 8400 (84%), which makes the spec §1.3 worked example exact:
/// 100 WETH collateral, borrow 67 WETH -> HF 1.254x (passes 1.25x floor),
/// borrow 68 WETH -> HF 1.236x (reverts).
contract AaveAdapterTest is Fixture {
    MockAavePool internal mockAavePool;
    MockPoolDataProvider internal mockProvider;
    MockAaveOracle internal mockOracle;
    AaveAdapter internal aave;
    uint256 internal aavePolicyId;
    // Mock aTokens (the adapter pulls the user's aTokens on withdraw, so
    // the test user must hold them and approve the adapter, as on the
    // real Pool). The mock provider's liquidity index is 1e27, so the
    // scaled aToken amount equals the underlying amount.
    MockERC20 internal aAsset;
    MockERC20 internal aToken1;

    // AaveOracle prices, 1e8-scaled.
    uint256 internal constant WETH_PRICE = 166_001_000_000; // $1,660.01
    uint256 internal constant USDC_PRICE = 99_982_000; // $0.99982
    uint256 internal constant LT = 8400; // 84% liquidation threshold

    function setUp() public override {
        super.setUp();
        address[] memory reserves = new address[](2);
        reserves[0] = address(asset);
        reserves[1] = address(token1);
        mockAavePool = new MockAavePool(reserves);
        mockProvider = new MockPoolDataProvider();
        mockOracle = new MockAaveOracle();
        mockOracle.setPrice(address(asset), WETH_PRICE);
        mockOracle.setPrice(address(token1), USDC_PRICE);
        aave = new AaveAdapter(
            guard,
            IPool(address(mockAavePool)),
            IPoolDataProvider(address(mockProvider)),
            IAaveOracle(address(mockOracle)),
            reserves
        );

        // Adapter policy via the helper: USD caps $200k/$1M/$5M, HF floor
        // 1.25x, drain 50%, single-share 10000 (drain is the binding share
        // rule). No oracle configs: Aave actions are not swaps.
        aavePolicyId = AdapterPolicyHelper.registerAdapterPolicy(
            guard,
            address(aave),
            AdapterPolicyHelper.adapterPolicy(200_000 ether, 1_000_000 ether, 5_000_000 ether, 10_000),
            priceConfig()
        );
        guard.addKeeper(aavePolicyId, keeper);

        // Fund the mock pool so borrows/withdraws can disburse.
        asset.mint(address(mockAavePool), 10_000 ether);
        token1.mint(address(mockAavePool), 10_000 ether);
        // Mock aTokens: the adapter pulls the user's aTokens on withdraw.
        aAsset = new MockERC20("Mock aWETH", "maWETH");
        aToken1 = new MockERC20("Mock aUSDC", "maUSDC");
        mockProvider.setAToken(address(asset), address(aAsset));
        mockProvider.setAToken(address(token1), address(aToken1));
        mockAavePool.setAToken(address(asset), address(aAsset));
        mockAavePool.setAToken(address(token1), address(aToken1));
        aAsset.mint(victim, 10_000 ether);
        aToken1.mint(victim, 10_000 ether);
        // The user holds collateral; the mock account data mirrors it.
        vm.startPrank(victim);
        asset.approve(address(aave), type(uint256).max);
        token1.approve(address(aave), type(uint256).max);
        aAsset.approve(address(aave), type(uint256).max);
        aToken1.approve(address(aave), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Mock account: 100 WETH collateral, no debt.
    function _setCollateralAccount() internal {
        // 100 WETH * $1,660.01 = $166,001 -> 16,600,100,000,000 base (1e8).
        mockAavePool.setAccountData(16_600_100_000_000, 0, 100_000_000_000_000, LT, 8000, type(uint256).max);
    }

    function test_Aave_BorrowForwards_DebtToUser() public {
        _setCollateralAccount();
        uint256 before = asset.balanceOf(victim);
        vm.prank(victim);
        aave.borrow(address(asset), 67 ether, victim);
        assertEq(asset.balanceOf(victim), before + 67 ether, "borrowed tokens to user");
        assertEq(mockAavePool.lastBorrowAsset(), address(asset));
        assertEq(mockAavePool.lastBorrowAmount(), 67 ether);
        assertEq(mockAavePool.lastBorrowMode(), 2, "variable mode 2");
        assertEq(mockAavePool.lastBorrowOnBehalfOf(), victim, "debt to msg.sender");
        assertEq(mockAavePool.borrowCalls(), 1);
    }

    function test_Aave_BorrowOnBehalfOfOther_Reverts() public {
        _setCollateralAccount();
        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(AdapterError.selector, "onBehalfOf must be msg.sender"));
        aave.borrow(address(asset), 1 ether, address(attacker));
    }

    function test_Aave_BorrowNonAllowlisted_Reverts() public {
        address other = address(0xBEEF);
        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(AdapterNotConfigured.selector, other));
        aave.borrow(other, 1 ether, victim);
    }

    function test_Aave_BorrowStableModeNeverIssued() public {
        // The adapter hard-codes mode 2; the mock records it. A borrow of
        // any size must record mode 2, never 1 (stable).
        _setCollateralAccount();
        vm.prank(victim);
        aave.borrow(address(asset), 1 ether, victim);
        assertEq(mockAavePool.lastBorrowMode(), 2);
        assertTrue(mockAavePool.lastBorrowMode() != 1, "stable mode 1 never issued");
    }

    function test_Aave_BorrowHF_67Passes() public {
        _setCollateralAccount();
        // 67 WETH: HF ~1.254x >= 1.25x floor -> passes.
        vm.prank(victim);
        aave.borrow(address(asset), 67 ether, victim);
    }

    function test_Aave_BorrowHF_68Reverts() public {
        _setCollateralAccount();
        // 68 WETH: HF ~1.236x < 1.25x floor -> HEALTH_FACTOR.
        // (Separate test function so the per-block outflow window from a
        // prior borrow cannot fire first: the check order runs outflow
        // before health factor.)
        vm.prank(victim);
        vm.expectRevert();
        aave.borrow(address(asset), 68 ether, victim);
    }

    function test_Aave_ProjectedHF_MatchesMockPostActionHF() public {
        _setCollateralAccount();
        // Projected HF for borrowing 67 WETH.
        uint256 projected = aave.getProjectedHealthFactor(victim, address(asset), 67 ether, true);
        // The mock's own post-action HF, computed the same way Aave does:
        // collateral 100 WETH, debt 67 WETH, threshold 8400.
        uint256 expected = (16_600_100_000_000 * LT * 1e18) / ((67 ether * WETH_PRICE / 1e18) * 10_000);
        assertApproxEqRel(projected, expected, 0.001 ether, "projected HF matches mock post-action HF");
        assertApproxEqRel(projected, 1254e15, 0.01 ether, "HF ~1.254x for 67 WETH");
        uint256 projected68 = aave.getProjectedHealthFactor(victim, address(asset), 68 ether, true);
        assertApproxEqRel(projected68, 1236e15, 0.01 ether, "HF ~1.236x for 68 WETH");
    }

    function test_Aave_ProjectedHF_DebtAfterZero_Infinite() public {
        // No debt after the action -> infinite HF.
        _setCollateralAccount();
        uint256 hf = aave.getProjectedHealthFactor(victim, address(asset), 0, true);
        assertEq(hf, type(uint256).max);
    }

    function test_Aave_ProjectedHF_OverWithdrawal_Zero() public {
        // Withdrawing more collateral value than held, with debt present
        // -> collateral saturates at 0 -> HF 0.
        mockAavePool.setAccountData(
            16_600_100_000_000, // 100 WETH collateral
            5_000_000_000_000, // ~$50,000 debt
            0,
            LT,
            8000,
            2 ether
        );
        uint256 hf = aave.getProjectedHealthFactor(victim, address(asset), 200 ether, false);
        assertEq(hf, 0, "over-withdrawal leaves HF 0");
    }

    function test_Aave_AvailableLiquidity_EqualsPoolBalance() public {
        // The adapter reads available liquidity as the Pool's actual token
        // balance (spec §1.4, the fork-verified divergence). The mock pool
        // holds 10,000 WETH -> $16,600,100 at $1,660.01.
        uint256 avail = aave.getAvailableLiquidity(address(asset));
        assertEq(avail, 10_000 ether * WETH_PRICE / 1e18 * 1e10, "available = balance * price, USD 1e18");
        // And it equals the raw balance-based read exactly.
        uint256 balance = asset.balanceOf(address(mockAavePool));
        assertEq(balance, 10_000 ether);
        assertEq(avail, aave.getUsdValue(address(asset), balance));
    }

    function test_Aave_UsdValue_MagnitudeCheck() public {
        // 1 WETH is ~$1,660.01 -> 1660.01e18 USD, ~1660x the raw amount.
        // A raw-unit amountOut passed to a USD policy would understate the
        // value by ~3 orders of magnitude: this is the split-unit seam.
        uint256 usd = aave.getUsdValue(address(asset), 1 ether);
        assertEq(usd, 166001e16, "1 WETH = $1,660.01 in USD 1e18");
        assertGt(usd, 1000 ether, "USD value is ~1660x the raw amount");
    }

    function test_Aave_SupplyRepay_DoNotTouchOutflowWindows() public {
        // supply and repay are unguarded pass-throughs: they must not
        // consume the outflow windows (checked by borrowing the full
        // per-block cap afterwards and having it pass).
        _setCollateralAccount();
        vm.prank(victim);
        aave.supply(address(asset), 10 ether, victim);
        assertEq(mockAavePool.lastSupplyAsset(), address(asset));
        assertEq(mockAavePool.lastSupplyAmount(), 10 ether);
        assertEq(mockAavePool.lastSupplyOnBehalfOf(), victim);
        vm.prank(victim);
        aave.repay(address(asset), 5 ether, victim);
        assertEq(mockAavePool.lastRepayAsset(), address(asset));
        assertEq(mockAavePool.lastRepayAmount(), 5 ether);
        assertEq(mockAavePool.lastRepayMode(), 2, "repay is variable mode 2");
        // A borrow at the HF boundary still passes: the outflow windows
        // were not consumed by supply/repay.
        vm.prank(victim);
        aave.borrow(address(asset), 67 ether, victim);
    }

    function test_Aave_WithdrawForwards_ToUser() public {
        _setCollateralAccount();
        uint256 before = asset.balanceOf(victim);
        vm.prank(victim);
        aave.withdraw(address(asset), 10 ether, victim);
        assertEq(asset.balanceOf(victim), before + 10 ether);
        assertEq(mockAavePool.lastWithdrawAsset(), address(asset));
        assertEq(mockAavePool.lastWithdrawAmount(), 10 ether);
        assertEq(mockAavePool.lastWithdrawTo(), victim);
    }

    function test_Aave_WithdrawToOther_Reverts() public {
        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(AdapterError.selector, "to must be msg.sender"));
        aave.withdraw(address(asset), 1 ether, address(attacker));
    }
}
