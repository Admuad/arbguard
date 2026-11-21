// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
 * ArbGuard — on-chain circuit breaker / invariant firewall (Solidity core).
 * Phase 1: oracle-fed reference prices + policy hardening.
 *
 * A protocol registers a Policy for its own address, then calls
 * `check(...)` BEFORE the sensitive state change (withdraw / mint / swap /
 * borrow). If any declared invariant breaks, `check` reverts with
 * `ArbGuardViolation(reason)` and the whole transaction rolls back, so no
 * funds move. Keepers (or the owner) can `trip` the breaker to pause the
 * guarded functions for a cooldown window, or `throttle` them to degraded
 * limits; both auto-expire and the owner can `reset` / `unthrottle` early.
 *
 * DESIGN DECISION — no `ViolationBlocked` event (documented, deliberate):
 * A reverted transaction cannot leave a persistent event on-chain: events
 * are rolled back together with the state change. Emitting a
 * `ViolationBlocked` event from `check()` would therefore be a lie — it
 * could never be observed on-chain for a blocked attempt. So this contract
 * does NOT emit one. Blocked attempts are surfaced two honest ways:
 *   (1) the revert itself — `ArbGuardViolation(reason)` — visible in the
 *       failed transaction receipt (which the frontend simulator shows);
 *   (2) `simulateCheck()`, a view that runs the exact same invariant logic
 *       without mutating state and returns `(ok, reason)`, so a UI can
 *       preview whether an action would pass or fail before sending it.
 * `CheckPassed` IS emitted (on the success path the tx persists, so the
 * event is real).
 *
 * PHASE 1 — ORACLE-FED PRICES (spec §1): v1 compared the execution price
 * against `twapPrice`, a field the CALLER supplied. The guard now resolves
 * the reference price itself, from on-chain oracles the caller cannot
 * influence: Chainlink (primary) + Uniswap V3 TWAP (cross-check / fallback),
 * with an L2 sequencer uptime check first. The `Action` no longer carries
 * a reference price; it carries `tokenIn` so the guard knows the pair.
 *
 * TWAP DECIMAL NOTE (spec §1.5 deviation, verified live 19 Nov 2026):
 * The spec's TWAP formula `sqrtRatioX96^2 * 10^(decOut-decIn) * 1e18 / 2^192`
 * is WRONG for the guard's raw-price convention. A Uniswap tick encodes the
 * price in RAW token units (reserves are raw), so the 1e18-scaled raw price
 * is simply `sqrtRatioX96^2 * 1e18 / 2^192` with NO decimal correction.
 * Live proof (Arbitrum One pool 0xC696...): spot tick -201721 gives a raw
 * ratio 1.735e-9, i.e. price1e18 = 1.735e9, matching the Chainlink ratio
 * 1.7358e9 within 0.05%. The spec's formula gives 1.735e-3 (off by 1e12)
 * and would make every Chainlink+TWAP check revert ORACLE_DISAGREEMENT.
 * The implementation uses the correct formula; ArbitrumOneFork.t.sol pins
 * it by asserting the TWAP reference matches the Chainlink reference.
 * (The Chainlink ratio formula in the spec IS correct and is implemented
 * as written, generalised to feeds with differing decimals via mulDiv.)
 *
 * PHASE 1 — POLICY HARDENING (spec §2):
 * - Timelock (default 24h, per-policy 1h–7d) on every limit change, price
 *   config change, oracle config change, and re-enable. The delay itself
 *   can only change through the timelock, and a new delay applies only to
 *   proposals made after it executes (Compound pattern). Disabling is
 *   immediate (fail-closed); keeper add/remove, trip, throttle, reset and
 *   unthrottle are immediate.
 * - Multi-keeper set (max 10) instead of a single keeper. Any keeper or
 *   the owner may trip/throttle; only the owner may reset, unthrottle,
 *   change policy, or manage keepers.
 * - Throttle mode: degraded caps (registered caps * throttleBps / 10000,
 *   default 10%) for block/hour/day windows; price and share rules
 *   unchanged. `reset()` returns to NORMAL (spec decision).
 * - Velocity windows: per-hour and per-day outflow caps keyed on
 *   wall-clock time (block.timestamp / 3600 and / 86400). 0 = unenforced.
 *   Enforcement order: block, then hour, then day.
 *
 * CHECK ORDER (spec §3.4 Phase 2, normative): caller == protocol; policy exists;
 * sequencer check (SWAP only — non-swaps spend no oracle gas, spec §1.4);
 * enabled/paused; outflow windows (block, hour, day); single share;
 * health factor (BORROW/WITHDRAW only); reserve drain (BORROW/WITHDRAW/SWAP);
 * swaps only: resolve reference and compare. `simulateCheck` mirrors `check`
 * exactly: same rules, same order, same thresholds (see Mirror.t.sol).
 *
 * ORACLE_STALE (spec §1.6 note): kept in the enum but never returned by
 * `check()` / `simulateCheck()` in Phase 1. When no oracle source is
 * usable the terminal reason is ORACLE_UNAVAILABLE, whether the cause is
 * staleness or absence. The distinction is reserved for a future UI path.
 *
 * All arithmetic is Solidity 0.8 checked arithmetic: an overflow reverts
 * (fail-closed). The Stylus checker stays out of this phase: oracle
 * resolution needs external calls, which cannot be pure functions.
 */

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {TickMath, FullMath} from "./libraries/UniswapMath.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/interfaces/IUniswapV3Pool.sol";

/// @notice Minimal Chainlink AggregatorV3 interface (proxy).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Kind of sensitive action being guarded.
enum ActionKind {
    WITHDRAW,
    MINT,
    SWAP,
    BORROW
}

/// @notice Why a check failed. NONE is a simulator-only sentinel: it is
/// returned by `simulateCheck` on success and is NEVER used in a revert.
enum Reason {
    NONE,
    OUTFLOW_PER_BLOCK,
    OUTFLOW_PER_HOUR,
    OUTFLOW_PER_DAY,
    SINGLE_SHARE,
    PRICE_DEVIATION,
    BREAKER_TRIPPED,
    ORACLE_STALE, // reserved (see header note); check() uses ORACLE_UNAVAILABLE
    ORACLE_DISAGREEMENT,
    ORACLE_UNAVAILABLE,
    SEQUENCER_DOWN,
    HEALTH_FACTOR, // Phase 2: projected post-action health factor below the floor
    RESERVE_DRAIN // Phase 2: action takes more than maxReserveDrainBps of available
}

/// @notice Graduated response state per policy.
enum Mode {
    NORMAL,
    THROTTLED,
    PAUSED
}

/// @notice Declared limits for one protocol. bps fields are out of 10000.
/// Phase 2: `usdDenominated` marks adapter policies whose amountOut / tvl /
/// availableLiquidity are USD 1e18 (demo policies stay in raw token units);
/// `minHealthFactorBps` (0 = off, else 10000..50000 = 1.0x..5.0x) is the
/// health-factor floor for BORROW/WITHDRAW; `maxReserveDrainBps` (0 = off,
/// else 1..10000) caps one action's share of available liquidity.
struct Policy {
    uint256 maxOutflowPerBlock;
    uint256 maxOutflowPerHour; // 0 = window unenforced
    uint256 maxOutflowPerDay; // 0 = window unenforced
    uint16 maxSingleShareBps;
    uint16 maxPriceDeviationBps;
    uint16 throttleBps; // 1..10000, default 1000 (10%)
    uint32 cooldownSeconds;
    uint32 policyTimelockSeconds; // default 86400, range [3600, 604800]
    bool enabled;
    bool usdDenominated;
    uint16 minHealthFactorBps;
    uint16 maxReserveDrainBps;
}

/// @notice One sensitive action submitted for enforcement.
/// Phase 2: `healthFactorAfter` is the adapter-projected post-action health
/// factor, 1e18-scaled (0 = not provided); `availableLiquidity` is the
/// reserve/pool available before the action, same units as amountOut.
struct Action {
    ActionKind kind;
    address token; // tokenOut for swaps
    address tokenIn; // token being sold; address(0) for non-swaps
    uint256 amountOut;
    uint256 amountIn;
    uint256 price; // execution price, 1e18-scaled (tokenOut per tokenIn)
    uint256 tvl; // value at risk before the action (same units as amountOut)
    uint256 healthFactorAfter;
    uint256 availableLiquidity;
}

/// @notice How the guard prices one token. A token with neither a feed
/// nor a pool has no oracle; swaps involving it skip the price rule.
struct OracleConfig {
    address chainlinkFeed; // AggregatorV3 proxy, or address(0)
    address uniswapPool; // Uniswap V3 pool for the token's USD pair, or address(0)
    uint8 feedDecimals; // cached from feed.decimals() at registration
    uint8 tokenDecimals; // token decimals, set by the owner
}

/// @notice Price source chosen per policy. Stored per policyId.
struct PriceConfig {
    uint32 twapSeconds; // default 1800, range [300, 86400]
    uint16 maxOracleDeviationBps; // default 200
    uint32 chainlinkStaleAfter; // default 7200
    address sequencerFeed; // address(0) = skip the sequencer check
}

/// @notice A proposed policy + price change awaiting its timelock.
struct PendingUpdate {
    Policy policy;
    PriceConfig price;
    uint256 executableAt;
    uint256 proposedAt;
}

/// @notice A proposed oracle config change awaiting its timelock.
struct PendingOracleUpdate {
    OracleConfig config;
    uint256 executableAt;
    uint256 proposedAt;
}

/// @notice Oracle sources + price config for one pair, gathered once so
/// the reference resolution does not hold a dozen live locals. Internal
/// plumbing only; never stored.
struct OracleSetup {
    address clFeed; // tokenOut's Chainlink feed (representative)
    address pool; // tokenOut's pool first, else tokenIn's
    bool configured; // a complete Chainlink pair exists OR a pool exists
    uint32 twapSeconds;
    uint16 maxDev; // maxOracleDeviationBps
}

/// @notice Minimal interface used by guarded protocols.
interface IArbGuard {
    function check(address protocol, Action calldata action) external;
    function simulateCheck(address protocol, Action calldata action) external view returns (bool ok, Reason reason);
}

contract ArbGuard is Ownable2Step, IArbGuard {
    // ---------------------------------------------------------------- errors
    error ArbGuardViolation(Reason reason);
    error UnknownPolicy(address protocol);
    error UnknownPolicyId(uint256 policyId);
    error PolicyAlreadyRegistered(address protocol);
    error InvalidPolicy(string reason);
    error NotProtocol(address caller, address protocol);
    error NotKeeperOrOwner(address caller);
    error BreakerStillActive(uint256 pausedUntil);
    error PendingUpdateExists(uint256 policyId);
    error NoPendingUpdate(uint256 policyId);
    error TimelockNotElapsed(uint256 executableAt);
    error ProposalExpired(uint256 proposedAt);
    error TooManyKeepers(uint256 policyId);
    error AlreadyThrottled(uint256 policyId);
    error OracleConfigInvalid(string reason);
    error UnknownOracle(address token);
    error PendingOracleUpdateExists(uint256 policyId, address token);
    error NoPendingOracleUpdate(uint256 policyId, address token);

    // ---------------------------------------------------------------- events
    event PolicyRegistered(uint256 indexed policyId, address indexed protocol);
    event PolicyUpdated(uint256 indexed policyId, address indexed protocol);
    event PolicyEnabled(uint256 indexed policyId, bool enabled);
    event PolicyUpdateProposed(uint256 indexed policyId, uint256 executableAt);
    event PolicyUpdateExecuted(uint256 indexed policyId);
    event PolicyUpdateCancelled(uint256 indexed policyId);
    event KeeperAdded(uint256 indexed policyId, address indexed keeper);
    event KeeperRemoved(uint256 indexed policyId, address indexed keeper);
    event ThrottleSet(uint256 indexed policyId, address indexed tripper, uint256 throttleUntil);
    event ThrottleCleared(uint256 indexed policyId);
    event CheckPassed(
        uint256 indexed policyId, address indexed protocol, ActionKind kind, address token, uint256 amountOut
    );
    event BreakerTripped(uint256 indexed policyId, address indexed tripper, uint256 pausedUntil, bytes evidence);
    event BreakerReset(uint256 indexed policyId);
    event OracleConfigSet(uint256 indexed policyId, address indexed token, address feed, address pool);
    event OracleConfigRemoved(uint256 indexed policyId, address indexed token);
    event OracleConfigUpdateProposed(uint256 indexed policyId, address indexed token, uint256 executableAt);
    event OracleConfigUpdateExecuted(uint256 indexed policyId, address indexed token);
    event OracleConfigUpdateCancelled(uint256 indexed policyId, address indexed token);
    event PriceConfigUpdated(uint256 indexed policyId);

    // ---------------------------------------------------------------- constants
    uint256 internal constant PROPOSAL_WINDOW = 7 days;
    uint256 internal constant SEQUENCER_GRACE_PERIOD = 3600;
    uint256 internal constant MAX_KEEPERS = 10;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    // ---------------------------------------------------------------- state
    uint256 private _nextPolicyId;
    mapping(uint256 => Policy) private _policies;
    mapping(uint256 => PriceConfig) private _priceConfigs;
    mapping(uint256 => address) private _policyProtocol;
    mapping(address => uint256) private _protocolPolicyId;
    mapping(address => bool) private _hasPolicy;

    /// @notice Cumulative amountOut checked in the current block, per policy.
    mapping(uint256 => uint256) public outflowInBlock;
    /// @notice Block number the outflow window above belongs to, per policy.
    mapping(uint256 => uint256) public outflowBlock;
    /// @notice Cumulative amountOut checked in the current hour, per policy.
    mapping(uint256 => uint256) public outflowInHour;
    /// @notice Hour id (block.timestamp / 3600) the window above belongs to.
    mapping(uint256 => uint256) public outflowHour;
    /// @notice Cumulative amountOut checked in the current day, per policy.
    mapping(uint256 => uint256) public outflowInDay;
    /// @notice Day id (block.timestamp / 86400) the window above belongs to.
    mapping(uint256 => uint256) public outflowDay;
    /// @notice Timestamp until which the policy is paused, per policy.
    mapping(uint256 => uint256) public pausedUntil;
    /// @notice Timestamp until which the policy is throttled (0 = indefinite).
    mapping(uint256 => uint256) public throttleUntil;
    /// @notice Stored response mode per policy (see _effectiveMode for auto-expiry).
    mapping(uint256 => Mode) public modeOf;

    mapping(uint256 => PendingUpdate) private _pendingUpdates;
    mapping(uint256 => bool) private _hasPendingUpdate;
    mapping(uint256 => mapping(address => OracleConfig)) private _oracleConfigs;
    mapping(uint256 => mapping(address => bool)) private _hasOracleConfig;
    mapping(uint256 => mapping(address => PendingOracleUpdate)) private _pendingOracleUpdates;
    mapping(uint256 => mapping(address => bool)) private _hasPendingOracleUpdate;

    /// @notice Keeper set per policy.
    mapping(uint256 => mapping(address => bool)) public isKeeper;
    mapping(uint256 => address[]) private _keepers;

    constructor() Ownable(msg.sender) {}

    // ------------------------------------------------------------ policy CRUD
    /// @notice Register a policy + price config for a protocol. Owner only.
    /// No timelock: a new policy guards nothing until the protocol calls
    /// `check()` with it; the protocol's own deployment is the review point.
    function registerPolicy(address protocol, Policy calldata policy, PriceConfig calldata priceConfig)
        external
        onlyOwner
        returns (uint256 policyId)
    {
        if (protocol == address(0)) revert InvalidPolicy("protocol is zero address");
        if (_hasPolicy[protocol]) revert PolicyAlreadyRegistered(protocol);
        _validatePolicy(policy);
        _validatePriceConfig(priceConfig);
        policyId = _nextPolicyId++;
        _policies[policyId] = policy;
        _priceConfigs[policyId] = priceConfig;
        _policyProtocol[policyId] = protocol;
        _protocolPolicyId[protocol] = policyId;
        _hasPolicy[protocol] = true;
        modeOf[policyId] = Mode.NORMAL;
        emit PolicyRegistered(policyId, protocol);
    }

    /// @notice Propose a policy + price change. Owner only. Executes only
    /// after `policyTimelockSeconds` (the CURRENT delay, not the proposed
    /// one) and within 7 days of proposal, via `executePolicyUpdate`.
    function proposePolicyUpdate(uint256 policyId, Policy calldata newPolicy, PriceConfig calldata newPrice)
        external
        onlyOwner
    {
        _requirePolicy(policyId);
        if (_hasPendingUpdate[policyId]) revert PendingUpdateExists(policyId);
        _validatePolicy(newPolicy);
        _validatePriceConfig(newPrice);
        _proposeUpdate(policyId, newPolicy, newPrice);
    }

    /// @notice Apply a proposed policy + price change. Owner only, only
    /// after the timelock elapsed and within 7 days of proposal.
    function executePolicyUpdate(uint256 policyId) external onlyOwner {
        _requirePolicy(policyId);
        if (!_hasPendingUpdate[policyId]) revert NoPendingUpdate(policyId);
        PendingUpdate storage pending = _pendingUpdates[policyId];
        _checkTimelock(pending.executableAt, pending.proposedAt);
        bool enabledChanged = _policies[policyId].enabled != pending.policy.enabled;
        bool newEnabled = pending.policy.enabled;
        _policies[policyId] = pending.policy;
        _priceConfigs[policyId] = pending.price;
        delete _pendingUpdates[policyId];
        _hasPendingUpdate[policyId] = false;
        emit PolicyUpdateExecuted(policyId);
        emit PolicyUpdated(policyId, _policyProtocol[policyId]);
        emit PriceConfigUpdated(policyId);
        if (enabledChanged) emit PolicyEnabled(policyId, newEnabled);
    }

    /// @notice Drop a pending policy update. Owner only, any time before execution.
    function cancelPolicyUpdate(uint256 policyId) external onlyOwner {
        _requirePolicy(policyId);
        if (!_hasPendingUpdate[policyId]) revert NoPendingUpdate(policyId);
        delete _pendingUpdates[policyId];
        _hasPendingUpdate[policyId] = false;
        emit PolicyUpdateCancelled(policyId);
    }

    /// @notice Change only the price config, through the same timelock as a
    /// policy update (there is no direct price-config write: changing what
    /// counts as a violation is equivalent to loosening a cap).
    function setPriceConfig(uint256 policyId, PriceConfig calldata newPrice) external onlyOwner {
        _requirePolicy(policyId);
        if (_hasPendingUpdate[policyId]) revert PendingUpdateExists(policyId);
        _validatePriceConfig(newPrice);
        _proposeUpdate(policyId, _policies[policyId], newPrice);
    }

    /// @notice Enable/disable a policy. Disabling is immediate (fail-closed).
    /// Re-enabling is timelocked: it proposes a pending update carrying the
    /// current policy with enabled=true, applied by `executePolicyUpdate`.
    function setEnabled(uint256 policyId, bool enabled) external onlyOwner {
        _requirePolicy(policyId);
        if (!enabled) {
            _policies[policyId].enabled = false;
            emit PolicyEnabled(policyId, false);
            return;
        }
        if (_policies[policyId].enabled) {
            emit PolicyEnabled(policyId, true);
            return;
        }
        if (_hasPendingUpdate[policyId]) revert PendingUpdateExists(policyId);
        Policy memory reenabled = _policies[policyId];
        reenabled.enabled = true;
        _proposeUpdate(policyId, reenabled, _priceConfigs[policyId]);
    }

    // ---------------------------------------------------------------- keepers
    /// @notice Add a keeper. Owner only, immediate, max 10 per policy.
    function addKeeper(uint256 policyId, address keeper) external onlyOwner {
        _requirePolicy(policyId);
        if (keeper == address(0)) revert InvalidPolicy("keeper is zero address");
        if (isKeeper[policyId][keeper]) revert InvalidPolicy("keeper already added");
        if (_keepers[policyId].length >= MAX_KEEPERS) revert TooManyKeepers(policyId);
        isKeeper[policyId][keeper] = true;
        _keepers[policyId].push(keeper);
        emit KeeperAdded(policyId, keeper);
    }

    /// @notice Remove a keeper (swap-and-pop). Owner only, immediate.
    function removeKeeper(uint256 policyId, address keeper) external onlyOwner {
        _requirePolicy(policyId);
        if (!isKeeper[policyId][keeper]) revert InvalidPolicy("not a keeper");
        isKeeper[policyId][keeper] = false;
        address[] storage keepers = _keepers[policyId];
        for (uint256 i = 0; i < keepers.length; i++) {
            if (keepers[i] == keeper) {
                keepers[i] = keepers[keepers.length - 1];
                keepers.pop();
                break;
            }
        }
        emit KeeperRemoved(policyId, keeper);
    }

    function getKeepers(uint256 policyId) external view returns (address[] memory) {
        _requirePolicy(policyId);
        return _keepers[policyId];
    }

    // ------------------------------------------------------- throttle / breaker
    /// @notice Degrade a policy to THROTTLED limits. Any keeper or owner.
    /// `durationSeconds == 0` means indefinite (until the owner clears it).
    function throttle(uint256 policyId, uint32 durationSeconds, bytes calldata evidence) external {
        _requirePolicy(policyId);
        if (!_isKeeperOrOwner(policyId, msg.sender)) revert NotKeeperOrOwner(msg.sender);
        Mode mode = _effectiveMode(policyId);
        if (mode == Mode.THROTTLED) revert AlreadyThrottled(policyId);
        if (mode == Mode.PAUSED) revert BreakerStillActive(pausedUntil[policyId]);
        modeOf[policyId] = Mode.THROTTLED;
        uint256 until = durationSeconds == 0 ? 0 : block.timestamp + durationSeconds;
        throttleUntil[policyId] = until;
        emit ThrottleSet(policyId, msg.sender, until);
    }

    /// @notice Return a THROTTLED policy to NORMAL. Owner only.
    function unthrottle(uint256 policyId) external onlyOwner {
        _requirePolicy(policyId);
        if (_effectiveMode(policyId) != Mode.THROTTLED) revert InvalidPolicy("policy is not throttled");
        modeOf[policyId] = Mode.NORMAL;
        throttleUntil[policyId] = 0;
        emit ThrottleCleared(policyId);
    }

    /// @notice Pause the policy's guarded functions until
    /// `block.timestamp + cooldownSeconds`. Keeper or owner. Re-tripping
    /// from PAUSED extends the pause (v1 behaviour).
    function trip(uint256 policyId, bytes calldata evidence) external {
        _requirePolicy(policyId);
        if (!_isKeeperOrOwner(policyId, msg.sender)) revert NotKeeperOrOwner(msg.sender);
        uint256 until = block.timestamp + _policies[policyId].cooldownSeconds;
        modeOf[policyId] = Mode.PAUSED;
        pausedUntil[policyId] = until;
        throttleUntil[policyId] = 0;
        emit BreakerTripped(policyId, msg.sender, until, evidence);
    }

    /// @notice Clear the pause after the cooldown has passed. Owner only.
    /// Returns to NORMAL (spec decision); re-throttle with one call if the
    /// worry persists. A no-op that still emits BreakerReset when the
    /// policy was never tripped (v1 behaviour). Reverts when throttled:
    /// use `unthrottle` for that mode.
    function reset(uint256 policyId) external onlyOwner {
        _requirePolicy(policyId);
        Mode mode = _effectiveMode(policyId);
        if (mode == Mode.THROTTLED) revert InvalidPolicy("policy is throttled, use unthrottle");
        if (mode == Mode.PAUSED) {
            if (block.timestamp < pausedUntil[policyId]) {
                revert BreakerStillActive(pausedUntil[policyId]);
            }
        }
        modeOf[policyId] = Mode.NORMAL;
        pausedUntil[policyId] = 0;
        throttleUntil[policyId] = 0;
        emit BreakerReset(policyId);
    }

    /// @notice Effective response mode, applying auto-expiry: a PAUSED policy
    /// past `pausedUntil` reads NORMAL, and a THROTTLED policy past a set
    /// `throttleUntil` reads NORMAL. An indefinite throttle never expires.
    function getMode(uint256 policyId) external view returns (Mode) {
        _requirePolicy(policyId);
        return _effectiveMode(policyId);
    }

    // ----------------------------------------------------------------- oracles
    /// @notice Register or change an oracle config for one token.
    /// Initial registration (no config exists yet) applies immediately.
    /// Any later change (feed/pool swap) is timelocked: this call stores a
    /// pending update applied by `executeOracleConfigUpdate` after the
    /// policy timelock. Reverts if a change is already pending.
    function setOracleConfig(uint256 policyId, address token, OracleConfig calldata cfg) external onlyOwner {
        _requirePolicy(policyId);
        if (token == address(0)) revert OracleConfigInvalid("token is zero address");
        if (_hasPendingOracleUpdate[policyId][token]) {
            revert PendingOracleUpdateExists(policyId, token);
        }
        _validateOracleConfig(cfg);
        if (!_hasOracleConfig[policyId][token]) {
            _oracleConfigs[policyId][token] = cfg;
            _hasOracleConfig[policyId][token] = true;
            emit OracleConfigSet(policyId, token, cfg.chainlinkFeed, cfg.uniswapPool);
            return;
        }
        _proposeOracleUpdate(policyId, token, cfg);
    }

    /// @notice Propose removing an oracle config. Removal loosens the price
    /// rule (swaps skip it), so it is timelocked like any other change:
    /// this call stores a pending removal applied by
    /// `executeOracleConfigUpdate`.
    function removeOracleConfig(uint256 policyId, address token) external onlyOwner {
        _requirePolicy(policyId);
        if (!_hasOracleConfig[policyId][token]) revert UnknownOracle(token);
        if (_hasPendingOracleUpdate[policyId][token]) {
            revert PendingOracleUpdateExists(policyId, token);
        }
        _proposeOracleUpdate(
            policyId,
            token,
            OracleConfig({chainlinkFeed: address(0), uniswapPool: address(0), feedDecimals: 0, tokenDecimals: 0})
        );
    }

    /// @notice Apply a pending oracle config change (or removal). Owner only,
    /// after the timelock elapsed and within 7 days of proposal.
    function executeOracleConfigUpdate(uint256 policyId, address token) external onlyOwner {
        _requirePolicy(policyId);
        if (!_hasPendingOracleUpdate[policyId][token]) revert NoPendingOracleUpdate(policyId, token);
        PendingOracleUpdate storage pending = _pendingOracleUpdates[policyId][token];
        _checkTimelock(pending.executableAt, pending.proposedAt);
        OracleConfig memory cfg = pending.config;
        delete _pendingOracleUpdates[policyId][token];
        _hasPendingOracleUpdate[policyId][token] = false;
        if (cfg.chainlinkFeed == address(0) && cfg.uniswapPool == address(0)) {
            delete _oracleConfigs[policyId][token];
            _hasOracleConfig[policyId][token] = false;
            emit OracleConfigRemoved(policyId, token);
        } else {
            _oracleConfigs[policyId][token] = cfg;
            _hasOracleConfig[policyId][token] = true;
            emit OracleConfigSet(policyId, token, cfg.chainlinkFeed, cfg.uniswapPool);
        }
        emit OracleConfigUpdateExecuted(policyId, token);
    }

    /// @notice Drop a pending oracle config change. Owner only.
    function cancelOracleConfigUpdate(uint256 policyId, address token) external onlyOwner {
        _requirePolicy(policyId);
        if (!_hasPendingOracleUpdate[policyId][token]) revert NoPendingOracleUpdate(policyId, token);
        delete _pendingOracleUpdates[policyId][token];
        _hasPendingOracleUpdate[policyId][token] = false;
        emit OracleConfigUpdateCancelled(policyId, token);
    }

    function getOracleConfig(uint256 policyId, address token) external view returns (OracleConfig memory) {
        _requirePolicy(policyId);
        return _oracleConfigs[policyId][token];
    }

    function getPendingOracleConfig(uint256 policyId, address token)
        external
        view
        returns (PendingOracleUpdate memory)
    {
        _requirePolicy(policyId);
        return _pendingOracleUpdates[policyId][token];
    }

    /// @notice The reference price `check()` would use for a swap of
    /// `tokenIn -> tokenOut`, 1e18-scaled, plus the source that supplied it
    /// (a Chainlink feed, a Uniswap pool, or address(0) when no oracle is
    /// configured). Shares the resolution code with `check()` so the two
    /// cannot drift. Reverts with the same reason `check()` would.
    function getReferencePrice(uint256 policyId, address tokenIn, address tokenOut)
        external
        view
        returns (uint256 price1e18, address source)
    {
        _requirePolicy(policyId);
        Reason seqReason = _sequencerReason(policyId);
        if (seqReason != Reason.NONE) revert ArbGuardViolation(seqReason);
        (uint256 ref, address src, Reason err) = _resolveReference(policyId, tokenIn, tokenOut);
        if (err != Reason.NONE) revert ArbGuardViolation(err);
        return (ref, src);
    }

    // -------------------------------------------------------------- enforcement
    /// @notice Enforce `policy` for `protocol`. Only the protocol itself
    /// may call. Reverts with ArbGuardViolation on the first failing rule,
    /// in order (spec §3.4 Phase 2): sequencer (swaps only), breaker/enabled,
    /// per-block outflow, per-hour outflow, per-day outflow, single share,
    /// health factor (BORROW/WITHDRAW), reserve drain (BORROW/WITHDRAW/SWAP),
    /// price deviation (swaps only). Emits CheckPassed on success.
    function check(address protocol, Action calldata action) external {
        if (msg.sender != protocol) revert NotProtocol(msg.sender, protocol);
        uint256 policyId = _policyIdOf(protocol);
        Policy storage policy = _policies[policyId];
        if (action.kind == ActionKind.SWAP) {
            Reason seqReason = _sequencerReason(policyId);
            if (seqReason != Reason.NONE) revert ArbGuardViolation(seqReason);
        }
        Mode mode = _effectiveMode(policyId);
        if (!policy.enabled || mode == Mode.PAUSED) {
            revert ArbGuardViolation(Reason.BREAKER_TRIPPED);
        }
        _checkInvariants(policy, policyId, action, mode);
        emit CheckPassed(policyId, protocol, action.kind, action.token, action.amountOut);
    }

    /// @notice Preview of `check` for frontends / the attack simulator.
    /// Runs the identical invariant logic without mutating state. Returns
    /// (true, NONE) when the action would pass. Reverts UnknownPolicy for
    /// an unregistered protocol.
    function simulateCheck(address protocol, Action calldata action) external view returns (bool ok, Reason reason) {
        uint256 policyId = _policyIdOf(protocol);
        Policy storage policy = _policies[policyId];
        if (action.kind == ActionKind.SWAP) {
            Reason seqReason = _sequencerReason(policyId);
            if (seqReason != Reason.NONE) return (false, seqReason);
        }
        Mode mode = _effectiveMode(policyId);
        if (!policy.enabled || mode == Mode.PAUSED) {
            return (false, Reason.BREAKER_TRIPPED);
        }
        return _simulateInvariants(policy, policyId, action, mode);
    }

    // ------------------------------------------------------------------ views
    function getPolicy(uint256 policyId) external view returns (Policy memory) {
        _requirePolicy(policyId);
        return _policies[policyId];
    }

    function getPriceConfig(uint256 policyId) external view returns (PriceConfig memory) {
        _requirePolicy(policyId);
        return _priceConfigs[policyId];
    }

    function getPendingUpdate(uint256 policyId) external view returns (PendingUpdate memory) {
        _requirePolicy(policyId);
        return _pendingUpdates[policyId];
    }

    function getPolicyId(address protocol) external view returns (uint256) {
        return _policyIdOf(protocol);
    }

    function getProtocol(uint256 policyId) external view returns (address) {
        _requirePolicy(policyId);
        return _policyProtocol[policyId];
    }

    // --------------------------------------------------------------- internals
    function _requirePolicy(uint256 policyId) internal view {
        if (_policyProtocol[policyId] == address(0)) revert UnknownPolicyId(policyId);
    }

    /// @notice Store a pending policy + price update, executable after the
    /// CURRENT timelock delay and within 7 days. Shared by
    /// `proposePolicyUpdate`, `setPriceConfig` and `setEnabled`.
    function _proposeUpdate(uint256 policyId, Policy memory policy, PriceConfig memory price) internal {
        uint256 delay = _policies[policyId].policyTimelockSeconds;
        _pendingUpdates[policyId] = PendingUpdate({
            policy: policy, price: price, executableAt: block.timestamp + delay, proposedAt: block.timestamp
        });
        _hasPendingUpdate[policyId] = true;
        emit PolicyUpdateProposed(policyId, block.timestamp + delay);
    }

    /// @notice Revert unless a proposal's timelock has elapsed and it is
    /// still inside the 7-day execution window. Shared by the two execute
    /// functions.
    function _checkTimelock(uint256 executableAt, uint256 proposedAt) internal view {
        if (block.timestamp < executableAt) revert TimelockNotElapsed(executableAt);
        if (block.timestamp > proposedAt + PROPOSAL_WINDOW) revert ProposalExpired(proposedAt);
    }

    /// @notice Store a pending oracle config change (or removal, when the
    /// config is empty), executable after the policy timelock. Shared by
    /// `setOracleConfig` (change path) and `removeOracleConfig`.
    function _proposeOracleUpdate(uint256 policyId, address token, OracleConfig memory cfg) internal {
        uint256 delay = _policies[policyId].policyTimelockSeconds;
        _pendingOracleUpdates[policyId][token] =
            PendingOracleUpdate({config: cfg, executableAt: block.timestamp + delay, proposedAt: block.timestamp});
        _hasPendingOracleUpdate[policyId][token] = true;
        emit OracleConfigUpdateProposed(policyId, token, block.timestamp + delay);
    }

    function _policyIdOf(address protocol) internal view returns (uint256) {
        if (!_hasPolicy[protocol]) revert UnknownPolicy(protocol);
        return _protocolPolicyId[protocol];
    }

    function _isKeeperOrOwner(uint256 policyId, address caller) internal view returns (bool) {
        return caller == owner() || isKeeper[policyId][caller];
    }

    function _validatePolicy(Policy calldata policy) internal pure {
        if (policy.maxSingleShareBps > 10_000) revert InvalidPolicy("maxSingleShareBps > 10000");
        if (policy.maxPriceDeviationBps > 10_000) revert InvalidPolicy("maxPriceDeviationBps > 10000");
        if (policy.throttleBps == 0 || policy.throttleBps > 10_000) {
            revert InvalidPolicy("throttleBps out of range 1..10000");
        }
        if (policy.cooldownSeconds == 0) revert InvalidPolicy("cooldownSeconds is zero");
        if (policy.policyTimelockSeconds < 3600 || policy.policyTimelockSeconds > 604800) {
            revert InvalidPolicy("policyTimelockSeconds out of range 3600..604800");
        }
        // Phase 2: a health-factor floor below 1.0x is already liquidatable,
        // so it is a configuration error; 0 means the rule is off.
        if (
            policy.minHealthFactorBps != 0 && (policy.minHealthFactorBps < 10_000 || policy.minHealthFactorBps > 50_000)
        ) {
            revert InvalidPolicy("minHealthFactorBps out of range");
        }
        if (policy.maxReserveDrainBps > 10_000) revert InvalidPolicy("maxReserveDrainBps out of range");
    }

    function _validatePriceConfig(PriceConfig calldata cfg) internal pure {
        if (cfg.twapSeconds < 300 || cfg.twapSeconds > 86400) {
            revert InvalidPolicy("twapSeconds out of range 300..86400");
        }
        if (cfg.maxOracleDeviationBps > 10_000) revert InvalidPolicy("maxOracleDeviationBps > 10000");
        if (cfg.chainlinkStaleAfter == 0) revert InvalidPolicy("chainlinkStaleAfter is zero");
    }

    function _validateOracleConfig(OracleConfig calldata cfg) internal view {
        if (cfg.tokenDecimals > 18) revert OracleConfigInvalid("tokenDecimals > 18");
        if (cfg.feedDecimals > 18) revert OracleConfigInvalid("feedDecimals > 18");
        if (cfg.chainlinkFeed != address(0)) {
            uint8 liveDecimals;
            try IAggregatorV3(cfg.chainlinkFeed).decimals() returns (uint8 d) {
                liveDecimals = d;
            } catch {
                revert OracleConfigInvalid("feed decimals() call failed");
            }
            if (liveDecimals != cfg.feedDecimals) revert OracleConfigInvalid("feedDecimals mismatch");
        }
    }

    function _effectiveMode(uint256 policyId) internal view returns (Mode) {
        Mode m = modeOf[policyId];
        if (m == Mode.PAUSED) {
            if (block.timestamp >= pausedUntil[policyId]) return Mode.NORMAL;
            return Mode.PAUSED;
        }
        if (m == Mode.THROTTLED) {
            uint256 until = throttleUntil[policyId];
            if (until != 0 && block.timestamp >= until) return Mode.NORMAL;
            return Mode.THROTTLED;
        }
        return Mode.NORMAL;
    }

    function _effectiveCap(uint256 cap, Mode mode, uint16 throttleBps) internal pure returns (uint256) {
        if (mode == Mode.THROTTLED) return (cap * throttleBps) / 10_000;
        return cap;
    }

    /// @notice L2 sequencer uptime check. Returns NONE when up (or when no
    /// sequencer feed is configured), SEQUENCER_DOWN when the feed reports
    /// down, when the restart grace period (< 3600 s) has not elapsed, or
    /// when the feed call itself fails (fail-closed).
    function _sequencerReason(uint256 policyId) internal view returns (Reason) {
        address feed = _priceConfigs[policyId].sequencerFeed;
        if (feed == address(0)) return Reason.NONE;
        try IAggregatorV3(feed).latestRoundData() returns (uint80, int256 answer, uint256 startedAt, uint256, uint80) {
            if (answer == 1) return Reason.SEQUENCER_DOWN;
            if (startedAt == 0) return Reason.NONE; // uninitialized feed: up
            if (startedAt > block.timestamp) return Reason.NONE;
            if (block.timestamp - startedAt < SEQUENCER_GRACE_PERIOD) return Reason.SEQUENCER_DOWN;
            return Reason.NONE;
        } catch {
            return Reason.SEQUENCER_DOWN;
        }
    }

    /// @notice Resolve the reference price for a `tokenIn -> tokenOut` swap.
    /// Returns (ref, source, err). `err == NONE` with `ref == 0` and
    /// `source == address(0)` means no oracle is configured for the pair:
    /// the price rule is skipped (v1 behaviour). `err` is
    /// ORACLE_DISAGREEMENT when both sources are fresh but disagree, and
    /// ORACLE_UNAVAILABLE when an oracle is configured but no source is
    /// usable. Chainlink wins when both agree; TWAP is the fallback.
    /// (Split across _oracleSetup + _readAndCombine so no single frame
    /// holds enough locals to trip the compiler's stack limit.)
    function _resolveReference(uint256 policyId, address tokenIn, address tokenOut)
        internal
        view
        returns (uint256 ref, address source, Reason err)
    {
        OracleSetup memory s = _oracleSetup(policyId, tokenIn, tokenOut);
        if (!s.configured) {
            return (0, address(0), Reason.NONE);
        }
        return _readAndCombine(s, policyId, tokenIn, tokenOut);
    }

    /// @notice What oracle sources exist for a pair, plus the price config
    /// the reads need. `clFeed` is tokenOut's Chainlink feed (the
    /// representative when Chainlink wins); `pool` is tokenOut's Uniswap
    /// pool first, else tokenIn's. `configured` is true when a complete
    /// Chainlink pair exists OR a pool exists.
    function _oracleSetup(uint256 policyId, address tokenIn, address tokenOut)
        internal
        view
        returns (OracleSetup memory s)
    {
        OracleConfig storage cfgIn = _oracleConfigs[policyId][tokenIn];
        OracleConfig storage cfgOut = _oracleConfigs[policyId][tokenOut];
        PriceConfig storage pc = _priceConfigs[policyId];
        bool hasChainlink = cfgIn.chainlinkFeed != address(0) && cfgOut.chainlinkFeed != address(0);
        s.pool = cfgOut.uniswapPool != address(0) ? cfgOut.uniswapPool : cfgIn.uniswapPool;
        s.clFeed = cfgOut.chainlinkFeed;
        s.configured = hasChainlink || s.pool != address(0);
        s.twapSeconds = pc.twapSeconds;
        s.maxDev = pc.maxOracleDeviationBps;
    }

    /// @notice Read both oracle sources for a pair and combine them:
    /// Chainlink wins when both agree (within maxDev), TWAP is the
    /// fallback, disagreement reverts ORACLE_DISAGREEMENT, and no usable
    /// source reverts ORACLE_UNAVAILABLE.
    function _readAndCombine(OracleSetup memory s, uint256 policyId, address tokenIn, address tokenOut)
        internal
        view
        returns (uint256 ref, address source, Reason err)
    {
        (uint256 clRef, bool clValid) = _chainlinkReferenceFor(policyId, tokenIn, tokenOut);
        (uint256 twapRef, bool twapValid) = _twapReference(s.pool, tokenIn, tokenOut, s.twapSeconds);
        if (clValid && twapValid) {
            uint256 diff = clRef > twapRef ? clRef - twapRef : twapRef - clRef;
            if (diff * 10_000 > clRef * s.maxDev) {
                return (0, address(0), Reason.ORACLE_DISAGREEMENT);
            }
            return (clRef, s.clFeed, Reason.NONE);
        }
        if (clValid) return (clRef, s.clFeed, Reason.NONE);
        if (twapValid) return (twapRef, s.pool, Reason.NONE);
        return (0, address(0), Reason.ORACLE_UNAVAILABLE);
    }

    /// @notice Chainlink USD-ratio reference for a pair. Valid only when
    /// BOTH feeds read cleanly; otherwise (0, false) and the caller falls
    /// back to TWAP or fails closed.
    function _chainlinkReferenceFor(uint256 policyId, address tokenIn, address tokenOut)
        internal
        view
        returns (uint256 ref, bool valid)
    {
        OracleConfig storage cfgIn = _oracleConfigs[policyId][tokenIn];
        OracleConfig storage cfgOut = _oracleConfigs[policyId][tokenOut];
        return _chainlinkReference(cfgIn, cfgOut, _priceConfigs[policyId].chainlinkStaleAfter);
    }

    /// @notice Chainlink USD-ratio reference. Valid only when BOTH feeds
    /// read cleanly (answer > 0, updatedAt set and fresh, answeredInRound
    /// >= roundId). Returns (0, false) otherwise — the caller falls back
    /// to TWAP or fails closed. A reverting feed read counts as invalid.
    function _chainlinkReference(OracleConfig storage cfgIn, OracleConfig storage cfgOut, uint32 staleAfter)
        internal
        view
        returns (uint256 ref, bool valid)
    {
        (int256 answerIn, bool validIn) = _readFeedPrice(cfgIn.chainlinkFeed, staleAfter);
        if (!validIn) return (0, false);
        (int256 answerOut, bool validOut) = _readFeedPrice(cfgOut.chainlinkFeed, staleAfter);
        if (!validOut) return (0, false);
        // Whole-token USD ratio, 1e18-scaled, corrected for both feed
        // decimals and both token decimals:
        //   ref = (usdIn/usdOut) * 10^(decOut+feedDecOut) / 10^(decIn+feedDecIn) * 1e18
        // in ONE mulDiv: a = answerIn, b = 1e18 * 10^(decOut+feedDecOut),
        // denominator = answerOut * 10^(decIn+feedDecIn). FullMath uses a
        // 512-bit intermediate for a*b, so the product is exact for any
        // realistic feed answer; it reverts fail-closed if the result does
        // not fit in 256 bits (or if the denominator overflows, which
        // needs an absurd answerOut > ~1e41).
        ref = FullMath.mulDiv(
            uint256(answerIn),
            1e18 * 10 ** (uint256(cfgOut.tokenDecimals) + uint256(cfgOut.feedDecimals)),
            uint256(answerOut) * 10 ** (uint256(cfgIn.tokenDecimals) + uint256(cfgIn.feedDecimals))
        );
        return (ref, true);
    }

    /// @notice One Chainlink feed read with validity. A feed reading is
    /// valid iff the call succeeds, `answer > 0`, `updatedAt != 0`,
    /// `answeredInRound >= roundId`, and the reading is fresh
    /// (`block.timestamp - updatedAt <= staleAfter`).
    function _readFeedPrice(address feed, uint32 staleAfter) internal view returns (int256 answer, bool valid) {
        if (feed == address(0)) return (0, false);
        try IAggregatorV3(feed).latestRoundData() returns (
            uint80 roundId, int256 ans, uint256, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (ans <= 0 || updatedAt == 0 || answeredInRound < roundId) return (0, false);
            if (updatedAt > block.timestamp || block.timestamp - updatedAt > staleAfter) return (0, false);
            return (ans, true);
        } catch {
            return (0, false);
        }
    }

    /// RAW token units, so the 1e18-scaled raw price is
    /// `sqrtRatioX96^2 * 1e18 / 2^192` with NO decimal correction (see the
    /// file header: the spec §1.5 decimal term is wrong for raw prices).
    /// Computed in two mulDiv steps (sqrt first, then square) so a raw
    /// ratio below 1 does not round to zero. Inverted when the swap runs
    /// token1 -> token0.
    function _twapReference(address pool, address tokenIn, address tokenOut, uint32 twapSeconds)
        internal
        view
        returns (uint256 ref, bool valid)
    {
        if (pool == address(0)) return (0, false);
        address token0;
        address token1;
        try IUniswapV3Pool(pool).token0() returns (address t0) {
            token0 = t0;
        } catch {
            return (0, false);
        }
        try IUniswapV3Pool(pool).token1() returns (address t1) {
            token1 = t1;
        } catch {
            return (0, false);
        }
        if (!((token0 == tokenIn && token1 == tokenOut) || (token0 == tokenOut && token1 == tokenIn))) {
            return (0, false); // pool prices a different pair
        }
        bool inIsToken0 = (tokenIn == token0);
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapSeconds;
        secondsAgos[1] = 0;
        int56[] memory tickCumulatives;
        try IUniswapV3Pool(pool).observe(secondsAgos) returns (int56[] memory tc, uint160[] memory) {
            tickCumulatives = tc;
        } catch {
            return (0, false);
        }
        int256 delta = int256(tickCumulatives[1]) - int256(tickCumulatives[0]);
        int256 twapTick = delta / int256(uint256(twapSeconds));
        if (delta < 0 && delta % int256(uint256(twapSeconds)) != 0) twapTick -= 1; // floor, not truncate
        if (twapTick < MIN_TICK || twapTick > MAX_TICK) return (0, false);
        uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(int24(twapTick));
        // ref01 = sqrtRatio^2 * 1e18 / 2^192, in ONE mulDiv: a = sqrtRatio,
        // b = sqrtRatio * 1e18 (fits: sqrtRatio <= 2^160, so b <= ~2^220),
        // denominator = 2^192. FullMath uses a 512-bit intermediate for
        // a*b (<= ~2^380), so the product is exact; it reverts fail-closed
        // if the result does not fit in 256 bits. token1 per token0, raw, 1e18.
        uint256 ref01 = FullMath.mulDiv(sqrtRatioX96, uint256(sqrtRatioX96) * 1e18, 1 << 192);
        if (inIsToken0) {
            return (ref01, true);
        }
        if (ref01 == 0) return (0, false);
        return (1e36 / ref01, true); // token0 per token1
    }

    /// @notice The window values a check would leave behind, computed
    /// without mutating state: the cumulative amountOut for the current
    /// block, hour and day after adding `action.amountOut` (a stale window
    /// counts as zero; an unenforced hour/day window reads as zero).
    function _windowAfter(Policy storage policy, uint256 policyId, Action calldata action)
        internal
        view
        returns (uint256 newBlock, uint256 newHour, uint256 newDay)
    {
        newBlock = (outflowBlock[policyId] == block.number ? outflowInBlock[policyId] : 0) + action.amountOut;
        if (policy.maxOutflowPerHour > 0) {
            uint256 hourId = block.timestamp / 3600;
            newHour = (outflowHour[policyId] == hourId ? outflowInHour[policyId] : 0) + action.amountOut;
        }
        if (policy.maxOutflowPerDay > 0) {
            uint256 dayId = block.timestamp / 86400;
            newDay = (outflowDay[policyId] == dayId ? outflowInDay[policyId] : 0) + action.amountOut;
        }
    }

    /// @notice The enforcement point, shared by `check()` and
    /// `simulateCheck()` so the two cannot drift: same rules, same order,
    /// same thresholds. `newBlock`/`newHour`/`newDay` are the window values
    /// from `_windowAfter`. Returns NONE when the action passes. The
    /// Stylus checker will later replace this function. `mode` is the
    /// effective mode computed once by the caller (avoids a duplicate
    /// _effectiveMode read).
    function _evaluateInvariants(
        Policy storage policy,
        uint256 policyId,
        Action calldata action,
        Mode mode,
        uint256 newBlock,
        uint256 newHour,
        uint256 newDay
    ) internal view returns (Reason) {
        // (b) Per-block outflow window (0 cap = no outflow at all, v1).
        if (newBlock > _effectiveCap(policy.maxOutflowPerBlock, mode, policy.throttleBps)) {
            return Reason.OUTFLOW_PER_BLOCK;
        }
        // (b2) Per-hour outflow window (0 cap = unenforced).
        if (policy.maxOutflowPerHour > 0 && newHour > _effectiveCap(policy.maxOutflowPerHour, mode, policy.throttleBps))
        {
            return Reason.OUTFLOW_PER_HOUR;
        }
        // (b3) Per-day outflow window (0 cap = unenforced).
        if (policy.maxOutflowPerDay > 0 && newDay > _effectiveCap(policy.maxOutflowPerDay, mode, policy.throttleBps)) {
            return Reason.OUTFLOW_PER_DAY;
        }
        // (c) Single-share of TVL (unchanged by throttle).
        if (action.tvl > 0 && policy.maxSingleShareBps > 0) {
            if (action.amountOut * 10_000 > action.tvl * policy.maxSingleShareBps) {
                return Reason.SINGLE_SHARE;
            }
        }
        // (c2) Phase 2 — health factor (BORROW/WITHDRAW only, when the
        // floor is set). healthFactorAfter is 1e18-scaled; the floor is in
        // bps where 10000 = 1.0x, so the 1e18-scaled floor is
        // minHealthFactorBps * 1e14. A missing projection (0) fails when
        // the rule is on: the adapter must always provide it.
        if (policy.minHealthFactorBps > 0 && (action.kind == ActionKind.BORROW || action.kind == ActionKind.WITHDRAW)) {
            if (action.healthFactorAfter < uint256(policy.minHealthFactorBps) * 1e14) {
                return Reason.HEALTH_FACTOR;
            }
        }
        // (c3) Phase 2 — reserve drain (BORROW/WITHDRAW/SWAP, when the cap
        // is set). Compares amountOut against availableLiquidity (what can
        // actually leave right now), not tvl (the total value at risk).
        // An empty reserve with a positive amount always reverts; a zero
        // amount against an empty reserve passes.
        if (
            policy.maxReserveDrainBps > 0
                && (action.kind == ActionKind.BORROW
                    || action.kind == ActionKind.WITHDRAW
                    || action.kind == ActionKind.SWAP)
        ) {
            if (action.amountOut * 10_000 > action.availableLiquidity * policy.maxReserveDrainBps) {
                return Reason.RESERVE_DRAIN;
            }
        }
        // (d) Price deviation vs guard-resolved reference (swaps only).
        // No oracle configured for the pair -> rule skipped (ref == 0).
        if (action.kind == ActionKind.SWAP) {
            (uint256 ref,, Reason err) = _resolveReference(policyId, action.tokenIn, action.token);
            if (err != Reason.NONE) return err;
            if (ref > 0) {
                uint256 diff = action.price > ref ? action.price - ref : ref - action.price;
                if (diff * 10_000 > ref * policy.maxPriceDeviationBps) {
                    return Reason.PRICE_DEVIATION;
                }
            }
        }
        return Reason.NONE;
    }

    /// @notice Mutating enforcement for `check()`: evaluate the invariants,
    /// then commit the outflow windows. A failing check reverts before any
    /// window is written; a revert would roll the writes back anyway, so
    /// the observable state is identical to writing first and reverting.
    function _checkInvariants(Policy storage policy, uint256 policyId, Action calldata action, Mode mode) internal {
        (uint256 newBlock, uint256 newHour, uint256 newDay) = _windowAfter(policy, policyId, action);
        Reason reason = _evaluateInvariants(policy, policyId, action, mode, newBlock, newHour, newDay);
        if (reason != Reason.NONE) revert ArbGuardViolation(reason);
        if (outflowBlock[policyId] != block.number) outflowBlock[policyId] = block.number;
        outflowInBlock[policyId] = newBlock;
        if (policy.maxOutflowPerHour > 0) {
            uint256 hourId = block.timestamp / 3600;
            if (outflowHour[policyId] != hourId) outflowHour[policyId] = hourId;
            outflowInHour[policyId] = newHour;
        }
        if (policy.maxOutflowPerDay > 0) {
            uint256 dayId = block.timestamp / 86400;
            if (outflowDay[policyId] != dayId) outflowDay[policyId] = dayId;
            outflowInDay[policyId] = newDay;
        }
    }

    /// @notice View mirror of `_checkInvariants` for `simulateCheck`.
    /// Same rules, same order, same thresholds — it reads the outflow
    /// windows through `_windowAfter` instead of mutating them.
    /// `mode` is the effective mode computed once by the caller.
    function _simulateInvariants(Policy storage policy, uint256 policyId, Action calldata action, Mode mode)
        internal
        view
        returns (bool ok, Reason reason)
    {
        (uint256 newBlock, uint256 newHour, uint256 newDay) = _windowAfter(policy, policyId, action);
        reason = _evaluateInvariants(policy, policyId, action, mode, newBlock, newHour, newDay);
        return (reason == Reason.NONE, reason);
    }
}
