// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ArbGuard, Policy, PriceConfig, OracleConfig} from "../src/ArbGuard.sol";
import {AaveAdapter, IPool, IPoolDataProvider, IAaveOracle} from "../src/AaveAdapter.sol";
import {UniswapV3Adapter, IUniswapV3Factory, INonfungiblePositionManager} from "../src/UniswapV3Adapter.sol";
import {AdapterError} from "../src/AaveAdapter.sol";

/// @notice Registration helper for adapter policies (spec §1.2, §3.1).
/// An adapter policy MUST be USD-denominated (`usdDenominated == true`);
/// registering one without the marker is a configuration error and this
/// helper reverts. Implemented as a library (internal function) so the
/// caller — deploy script or fork test — is the `msg.sender` the guard
/// sees as owner. The guard itself does not enforce the marker: it cannot
/// tell an adapter policy from a demo policy, and demo policies are
/// legitimately raw-unit.
library AdapterPolicyHelper {
    /// @notice Register an adapter policy, reverting unless it is USD-denominated.
    function registerAdapterPolicy(
        ArbGuard guard,
        address adapter,
        Policy memory policy,
        PriceConfig memory priceConfig
    ) internal returns (uint256 policyId) {
        if (!policy.usdDenominated) {
            revert AdapterError("adapter policy must be usdDenominated");
        }
        return guard.registerPolicy(adapter, policy, priceConfig);
    }

    /// @notice Demo defaults for an adapter policy (spec §1.3, §1.4):
    /// health-factor floor 1.25x, reserve-drain cap 50%. Outflow caps are
    /// in USD 1e18 and are passed in by the caller (they differ per
    /// adapter: Aave $200k/$1M/$5M, V3 $50k/$500k/$2M per the fork tests).
    function adapterPolicy(
        uint256 maxOutflowPerBlockUsd,
        uint256 maxOutflowPerHourUsd,
        uint256 maxOutflowPerDayUsd,
        uint16 maxSingleShareBps
    ) internal pure returns (Policy memory) {
        return Policy({
            maxOutflowPerBlock: maxOutflowPerBlockUsd,
            maxOutflowPerHour: maxOutflowPerHourUsd,
            maxOutflowPerDay: maxOutflowPerDayUsd,
            maxSingleShareBps: maxSingleShareBps,
            maxPriceDeviationBps: 500,
            throttleBps: 1000,
            cooldownSeconds: 3600,
            policyTimelockSeconds: 86400,
            enabled: true,
            usdDenominated: true,
            minHealthFactorBps: 12500,
            maxReserveDrainBps: 5000
        });
    }

    /// @notice Price config for adapter policies: 1800 s TWAP, 200 bps max
    /// oracle deviation, 7200 s Chainlink staleness. The sequencer feed is
    /// passed in (the real Arbitrum feed for V3; address(0) for Aave,
    /// whose actions are not swaps and never run the sequencer check).
    function adapterPriceConfig(address sequencerFeed) internal pure returns (PriceConfig memory) {
        return PriceConfig({
            twapSeconds: 1800, maxOracleDeviationBps: 200, chainlinkStaleAfter: 7200, sequencerFeed: sequencerFeed
        });
    }
}

/// @notice Deploy the Aave + Uniswap V3 adapters and register their
/// policies. NOT run against a public chain in Phase 2 (spec §6 Q1 is
/// open: the Aave/Uniswap deployments on Arbitrum Sepolia were not
/// verified). For Arbitrum One fork use, or for Sepolia once the
/// deployments there are confirmed.
///
/// Env:
///   PRIVATE_KEY   deployer's private key (never commit it)
///   KEEPER        (optional) keeper address; defaults to the deployer
///
/// The script re-derives the Aave Pool address from the
/// PoolAddressesProvider (never a hard-coded stale copy) and the reserve
/// allowlist from `Pool.getReservesList()`. The V3 adapter resolves pools
/// from the factory at runtime; the policy registers the canonical 0.05%
/// WETH/USDC pool in the OracleConfig.
contract DeployAdapters is Script {
    using AdapterPolicyHelper for ArbGuard;

    // Verified Arbitrum One addresses (spec §1.1, §2.1).
    address internal constant POOL_ADDRESSES_PROVIDER = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    address internal constant UNISWAP_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ETH_USD_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant USDC_USD_FEED = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address internal constant SEQUENCER_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    address internal constant WETH_USDC_POOL = 0xC6962004f452bE9203591991D15f6b388e09E8D0;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address keeper = vm.envOr("KEEPER", deployer);

        vm.startBroadcast(deployerKey);
        ArbGuard guard = new ArbGuard();

        // Aave: re-derive the Pool / DataProvider / Oracle from the provider.
        address poolAddr = _getAddress(POOL_ADDRESSES_PROVIDER, "getPool()");
        address dataProviderAddr = _getAddress(POOL_ADDRESSES_PROVIDER, "getPoolDataProvider()");
        address oracleAddr = _getAddress(POOL_ADDRESSES_PROVIDER, "getPriceOracle()");
        IPool pool = IPool(poolAddr);
        address[] memory reserves = pool_getReservesList(poolAddr);
        AaveAdapter aave =
            new AaveAdapter(guard, pool, IPoolDataProvider(dataProviderAddr), IAaveOracle(oracleAddr), reserves);

        // Uniswap V3.
        UniswapV3Adapter v3 = new UniswapV3Adapter(
            guard, IUniswapV3Factory(UNISWAP_FACTORY), INonfungiblePositionManager(NPM), IAaveOracle(oracleAddr)
        );

        // Aave policy: USD caps, HF floor 1.25x, drain 50%, no sequencer
        // feed (Aave actions are not swaps). Single-share 10000 so the
        // drain rule (not single-share) is the binding share rule.
        uint256 aavePolicyId = AdapterPolicyHelper.registerAdapterPolicy(
            guard,
            address(aave),
            AdapterPolicyHelper.adapterPolicy(200_000 ether, 1_000_000 ether, 5_000_000 ether, 10_000),
            AdapterPolicyHelper.adapterPriceConfig(address(0))
        );
        guard.addKeeper(aavePolicyId, keeper);

        // V3 policy: USD caps, drain 50%, single-share 50% (so position
        // removals can trip SINGLE_SHARE), HF floor off (0) — the
        // health-factor rule is an Aave concept and must not bind on
        // Uniswap removals. Real 0.05% pool in the OracleConfig, real
        // sequencer feed.
        Policy memory v3Policy = AdapterPolicyHelper.adapterPolicy(50_000 ether, 500_000 ether, 2_000_000 ether, 5000);
        v3Policy.minHealthFactorBps = 0;
        uint256 v3PolicyId = AdapterPolicyHelper.registerAdapterPolicy(
            guard, address(v3), v3Policy, AdapterPolicyHelper.adapterPriceConfig(SEQUENCER_FEED)
        );
        guard.addKeeper(v3PolicyId, keeper);
        guard.setOracleConfig(
            v3PolicyId,
            WETH,
            OracleConfig({chainlinkFeed: ETH_USD_FEED, uniswapPool: WETH_USDC_POOL, feedDecimals: 8, tokenDecimals: 18})
        );
        guard.setOracleConfig(
            v3PolicyId,
            USDC,
            OracleConfig({chainlinkFeed: USDC_USD_FEED, uniswapPool: WETH_USDC_POOL, feedDecimals: 8, tokenDecimals: 6})
        );
        vm.stopBroadcast();

        console.log("ArbGuard:        ", address(guard));
        console.log("AaveAdapter:     ", address(aave), " policyId: ", aavePolicyId);
        console.log("UniswapV3Adapter:", address(v3), " policyId: ", v3PolicyId);
        console.log("Aave Pool:       ", poolAddr);
        console.log("Reserves:        ", reserves.length);
    }

    function _getAddress(address provider, string memory sig) internal view returns (address) {
        (bool ok, bytes memory ret) = provider.staticcall(abi.encodeWithSignature(sig));
        require(ok, "provider getter failed");
        return abi.decode(ret, (address));
    }

    function pool_getReservesList(address poolAddr) internal view returns (address[] memory) {
        (bool ok, bytes memory ret) = poolAddr.staticcall(abi.encodeWithSignature("getReservesList()"));
        require(ok, "getReservesList failed");
        return abi.decode(ret, (address[]));
    }
}
