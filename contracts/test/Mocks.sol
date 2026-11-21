// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Test-only mocks for the Phase 1 oracle interfaces. Never in src/.
/// MockAggregatorV3: scriptable Chainlink feed (answer, updatedAt,
/// decimals, roundId, answeredInRound, revert flag).
contract MockAggregatorV3 {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public decimals;
    uint80 public roundId;
    uint80 public answeredInRound;
    uint256 public startedAt;
    bool public revertOnRead;

    constructor(int256 _answer, uint256 _updatedAt, uint8 _decimals) {
        answer = _answer;
        updatedAt = _updatedAt;
        decimals = _decimals;
        roundId = 1;
        answeredInRound = 1;
        startedAt = _updatedAt;
    }

    function setAnswer(int256 a) external {
        answer = a;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
        startedAt = t;
    }

    function setRound(uint80 r, uint80 aIn) external {
        roundId = r;
        answeredInRound = aIn;
    }

    function setRevert(bool r) external {
        revertOnRead = r;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (revertOnRead) revert("mock feed revert");
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

/// @notice Test-only mock Uniswap V3 pool. Only the functions the guard
/// calls are implemented: token0(), token1(), observe(). `observe()` reports
/// a constant TWAP tick: tickCumulatives are built from the requested
/// window so (cum[1]-cum[0])/window == twapTick exactly. Set
/// `revertOnObserve` to simulate an OLD / empty-pool revert.
contract MockUniswapV3Pool {
    address public token0;
    address public token1;
    int24 public twapTick;
    bool public revertOnObserve;

    constructor(address _token0, address _token1, int24 _twapTick) {
        token0 = _token0;
        token1 = _token1;
        twapTick = _twapTick;
    }

    function setTwapTick(int24 t) external {
        twapTick = t;
    }

    function setRevert(bool r) external {
        revertOnObserve = r;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint256[] memory secondsPerLiquidityCumulativeX128)
    {
        if (revertOnObserve) revert("OLD");
        uint32 window = secondsAgos[0];
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = int56(twapTick) * int56(int32(window));
        secondsPerLiquidityCumulativeX128 = new uint256[](2);
        return (tickCumulatives, secondsPerLiquidityCumulativeX128);
    }
}

/// @notice Test-only mock L2 sequencer uptime feed. Scriptable answer
/// (0 = up, 1 = down) and startedAt.
contract MockSequencerFeed {
    int256 public answer;
    uint256 public startedAt;
    bool public revertOnRead;

    constructor(int256 _answer, uint256 _startedAt) {
        answer = _answer;
        startedAt = _startedAt;
    }

    function setAnswer(int256 a) external {
        answer = a;
    }

    function setStartedAt(uint256 t) external {
        startedAt = t;
    }

    function setRevert(bool r) external {
        revertOnRead = r;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (revertOnRead) revert("mock sequencer revert");
        return (1, answer, startedAt, startedAt, 1);
    }
}
