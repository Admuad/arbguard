// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
 * ArbGuard — on-chain circuit breaker / invariant firewall (Solidity core).
 *
 * A protocol registers a Policy for its own address, then calls
 * `check(...)` BEFORE the sensitive state change (withdraw / mint / swap /
 * borrow). If any declared invariant breaks, `check` reverts with
 * `ArbGuardViolation(reason)` and the whole transaction rolls back, so no
 * funds move. A keeper (or the owner) can `trip` the breaker to pause the
 * guarded functions for a cooldown window; it auto-resumes afterwards and
 * the owner can `reset` it early once the cooldown has passed.
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
 * INVARIANT MATH — `_checkInvariants()` is the single enforcement point.
 * It is written in Solidity first (per the build plan §4: "Solidity
 * fallback first"). The Stylus (Rust) checker will later replace this
 * function behind the same interface; nothing else in the system needs to
 * change. All arithmetic is Solidity 0.8 checked arithmetic: an overflow
 * in the share/deviation multiplications reverts the tx (fail-closed),
 * which is the safe direction for a firewall. Realistic token amounts
 * (<< 2^240) never come close to overflowing the x10000 bps scaling.
 *
 * TRUST MODEL (v1):
 * - One policy per protocol address. `check` only accepts calls from the
 *   registered protocol address itself (`msg.sender == protocol`).
 * - The owner (deployer, via Ownable2Step) registers/updates policies.
 * - The keeper may only trip the breaker; it cannot change policy limits.
 * - `maxOutflowPerBlock == 0` means "no outflow allowed at all".
 * - `maxSingleShareBps == 0` disables the single-share rule;
 *   `maxPriceDeviationBps == 0` means "any price deviation reverts".
 * - The per-block outflow window resets on the first check of a new block.
 */

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

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
    SINGLE_SHARE,
    PRICE_DEVIATION,
    BREAKER_TRIPPED
}

/// @notice Declared limits for one protocol. bps fields are out of 10000.
struct Policy {
    uint256 maxOutflowPerBlock;
    uint16 maxSingleShareBps;
    uint16 maxPriceDeviationBps;
    uint32 cooldownSeconds;
    address keeper;
    bool enabled;
}

/// @notice One sensitive action submitted for enforcement.
struct Action {
    ActionKind kind;
    address token;
    uint256 amountOut;
    uint256 amountIn;
    uint256 price; // execution price, 1e18-scaled (tokenOut per tokenIn)
    uint256 twapPrice; // reference price, same scale; 0 = no reference
    uint256 tvl; // value at risk before the action (same units as amountOut)
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

    // ---------------------------------------------------------------- events
    event PolicyRegistered(uint256 indexed policyId, address indexed protocol, address keeper);
    event PolicyUpdated(uint256 indexed policyId, address indexed protocol);
    event PolicyEnabled(uint256 indexed policyId, bool enabled);
    event CheckPassed(
        uint256 indexed policyId, address indexed protocol, ActionKind kind, address token, uint256 amountOut
    );
    event BreakerTripped(uint256 indexed policyId, address indexed tripper, uint256 pausedUntil, bytes evidence);
    event BreakerReset(uint256 indexed policyId);

    // ---------------------------------------------------------------- state
    uint256 private _nextPolicyId;
    mapping(uint256 => Policy) private _policies;
    mapping(uint256 => address) private _policyProtocol;
    mapping(address => uint256) private _protocolPolicyId;
    mapping(address => bool) private _hasPolicy;

    /// @notice Cumulative amountOut checked in the current block, per policy.
    mapping(uint256 => uint256) public outflowInBlock;
    /// @notice Block number the outflow window above belongs to, per policy.
    mapping(uint256 => uint256) public outflowBlock;
    /// @notice Timestamp until which the policy is paused, per policy.
    mapping(uint256 => uint256) public pausedUntil;

    constructor() Ownable(msg.sender) {}

    // ------------------------------------------------------------ policy CRUD
    function registerPolicy(address protocol, Policy calldata policy) external onlyOwner returns (uint256 policyId) {
        if (protocol == address(0)) revert InvalidPolicy("protocol is zero address");
        if (_hasPolicy[protocol]) revert PolicyAlreadyRegistered(protocol);
        _validatePolicy(policy);
        policyId = _nextPolicyId++;
        _policies[policyId] = policy;
        _policyProtocol[policyId] = protocol;
        _protocolPolicyId[protocol] = policyId;
        _hasPolicy[protocol] = true;
        emit PolicyRegistered(policyId, protocol, policy.keeper);
    }

    function updatePolicy(uint256 policyId, Policy calldata policy) external onlyOwner {
        if (_policyProtocol[policyId] == address(0)) revert UnknownPolicyId(policyId);
        _validatePolicy(policy);
        _policies[policyId] = policy;
        emit PolicyUpdated(policyId, _policyProtocol[policyId]);
    }

    function setEnabled(uint256 policyId, bool enabled) external onlyOwner {
        if (_policyProtocol[policyId] == address(0)) revert UnknownPolicyId(policyId);
        _policies[policyId].enabled = enabled;
        emit PolicyEnabled(policyId, enabled);
    }

    // -------------------------------------------------------------- enforcement
    /// @notice Enforce `policy` for `protocol`. Only the protocol itself
    /// may call. Reverts with ArbGuardViolation on the first failing rule,
    /// in order: breaker/enabled, per-block outflow, single share, price
    /// deviation. Emits CheckPassed on success.
    function check(address protocol, Action calldata action) external {
        if (msg.sender != protocol) revert NotProtocol(msg.sender, protocol);
        uint256 policyId = _policyIdOf(protocol);
        Policy storage policy = _policies[policyId];
        if (!policy.enabled || block.timestamp < pausedUntil[policyId]) {
            revert ArbGuardViolation(Reason.BREAKER_TRIPPED);
        }
        _checkInvariants(policy, policyId, action);
        emit CheckPassed(policyId, protocol, action.kind, action.token, action.amountOut);
    }

    /// @notice Preview of `check` for frontends / the attack simulator.
    /// Runs the identical invariant logic without mutating state. Returns
    /// (true, NONE) when the action would pass. Reverts UnknownPolicy for
    /// an unregistered protocol.
    function simulateCheck(address protocol, Action calldata action) external view returns (bool ok, Reason reason) {
        uint256 policyId = _policyIdOf(protocol);
        Policy storage policy = _policies[policyId];
        if (!policy.enabled || block.timestamp < pausedUntil[policyId]) {
            return (false, Reason.BREAKER_TRIPPED);
        }
        return _simulateInvariants(policy, policyId, action);
    }

    // ---------------------------------------------------------------- breaker
    /// @notice Pause the policy's guarded functions until
    /// `block.timestamp + cooldownSeconds`. Keeper or owner only.
    function trip(uint256 policyId, bytes calldata evidence) external {
        if (_policyProtocol[policyId] == address(0)) revert UnknownPolicyId(policyId);
        Policy storage policy = _policies[policyId];
        if (msg.sender != policy.keeper && msg.sender != owner()) {
            revert NotKeeperOrOwner(msg.sender);
        }
        uint256 until = block.timestamp + policy.cooldownSeconds;
        pausedUntil[policyId] = until;
        emit BreakerTripped(policyId, msg.sender, until, evidence);
    }

    /// @notice Clear the pause after the cooldown has passed. Owner only.
    /// If the cooldown already elapsed (or the breaker was never tripped)
    /// this is a harmless no-op that still emits BreakerReset.
    function reset(uint256 policyId) external onlyOwner {
        if (_policyProtocol[policyId] == address(0)) revert UnknownPolicyId(policyId);
        if (block.timestamp < pausedUntil[policyId]) {
            revert BreakerStillActive(pausedUntil[policyId]);
        }
        pausedUntil[policyId] = 0;
        emit BreakerReset(policyId);
    }

    // ------------------------------------------------------------------ views
    function getPolicy(uint256 policyId) external view returns (Policy memory) {
        if (_policyProtocol[policyId] == address(0)) revert UnknownPolicyId(policyId);
        return _policies[policyId];
    }

    function getPolicyId(address protocol) external view returns (uint256) {
        return _policyIdOf(protocol);
    }

    function getProtocol(uint256 policyId) external view returns (address) {
        if (_policyProtocol[policyId] == address(0)) revert UnknownPolicyId(policyId);
        return _policyProtocol[policyId];
    }

    // --------------------------------------------------------------- internals
    function _policyIdOf(address protocol) internal view returns (uint256) {
        if (!_hasPolicy[protocol]) revert UnknownPolicy(protocol);
        return _protocolPolicyId[protocol];
    }

    function _validatePolicy(Policy calldata policy) internal pure {
        if (policy.maxSingleShareBps > 10_000) revert InvalidPolicy("maxSingleShareBps > 10000");
        if (policy.maxPriceDeviationBps > 10_000) revert InvalidPolicy("maxPriceDeviationBps > 10000");
        if (policy.cooldownSeconds == 0) revert InvalidPolicy("cooldownSeconds is zero");
    }

    /// @notice The enforcement point (see file header). The Stylus checker
    /// replaces this function; keep `_simulateInvariants` in lock-step —
    /// same rules, same order, same thresholds.
    function _checkInvariants(Policy storage policy, uint256 policyId, Action calldata action) internal {
        // (b) Per-block outflow window.
        if (outflowBlock[policyId] != block.number) {
            outflowBlock[policyId] = block.number;
            outflowInBlock[policyId] = 0;
        }
        uint256 newTotal = outflowInBlock[policyId] + action.amountOut;
        if (newTotal > policy.maxOutflowPerBlock) {
            revert ArbGuardViolation(Reason.OUTFLOW_PER_BLOCK);
        }
        outflowInBlock[policyId] = newTotal;

        // (c) Single-share of TVL.
        if (action.tvl > 0 && policy.maxSingleShareBps > 0) {
            if (action.amountOut * 10_000 > action.tvl * policy.maxSingleShareBps) {
                revert ArbGuardViolation(Reason.SINGLE_SHARE);
            }
        }

        // (d) Price deviation vs TWAP (swaps only, only with a reference).
        if (action.kind == ActionKind.SWAP && action.twapPrice > 0) {
            uint256 diff =
                action.price > action.twapPrice ? action.price - action.twapPrice : action.twapPrice - action.price;
            if (diff * 10_000 > action.twapPrice * policy.maxPriceDeviationBps) {
                revert ArbGuardViolation(Reason.PRICE_DEVIATION);
            }
        }
    }

    /// @notice View mirror of `_checkInvariants` for `simulateCheck`.
    /// Same rules, same order, same thresholds — but reads the outflow
    /// window instead of mutating it (a stale window counts as zero).
    function _simulateInvariants(Policy storage policy, uint256 policyId, Action calldata action)
        internal
        view
        returns (bool ok, Reason reason)
    {
        uint256 windowOutflow = outflowBlock[policyId] == block.number ? outflowInBlock[policyId] : 0;
        if (windowOutflow + action.amountOut > policy.maxOutflowPerBlock) {
            return (false, Reason.OUTFLOW_PER_BLOCK);
        }
        if (action.tvl > 0 && policy.maxSingleShareBps > 0) {
            if (action.amountOut * 10_000 > action.tvl * policy.maxSingleShareBps) {
                return (false, Reason.SINGLE_SHARE);
            }
        }
        if (action.kind == ActionKind.SWAP && action.twapPrice > 0) {
            uint256 diff =
                action.price > action.twapPrice ? action.price - action.twapPrice : action.twapPrice - action.price;
            if (diff * 10_000 > action.twapPrice * policy.maxPriceDeviationBps) {
                return (false, Reason.PRICE_DEVIATION);
            }
        }
        return (true, Reason.NONE);
    }
}
