//! ArbGuardChecker — Stylus (Rust) invariant checker for ArbGuard.
//!
//! Pure invariant math for the ArbGuard circuit breaker, compiled to
//! WebAssembly and deployed as a Stylus program on Arbitrum. The Solidity
//! `ArbGuard.sol` calls these three functions via cross-contract call
//! before a guarded protocol executes a sensitive action (withdraw / mint /
//! swap / borrow). Every function is pure: no storage reads, no storage
//! writes, no cross-contract state — so the pass path is as cheap as Stylus
//! gets, and the logic is unit-testable as plain Rust.
//!
//! Rules (all amounts are `uint256`; bps = basis points, 10000 = 100%):
//!
//! * `check_outflow` — true iff `window_outflow + amount_out <= max_outflow`.
//! * `check_price_deviation` — true iff `twap > 0` and
//!   `|price - twap| * 10000 <= twap * max_bps`.
//! * `check_share` — true iff `tvl == 0` (no TVL context, pass) or
//!   `amount_out * 10000 <= tvl * max_bps`.
//!
//! All arithmetic is overflow-safe: any overflow makes the check FAIL
//! (returns `false`) rather than wrap. A check that cannot be proven safe
//! must block the action — fail-closed, never fail-open.
//!
//! Note: this code is new for the Arbitrum Open House Dubai Buildathon and
//! has not been audited.

// Allow `cargo stylus export-abi` to generate a main function.
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

/// Import items from the SDK. The prelude contains common traits and macros.
use stylus_sdk::{alloy_primitives::U256, prelude::*};

// The contract has no storage: the checker is a pure function library
// exposed as a Stylus program. `ArbGuardChecker` is the entrypoint.
sol_storage! {
    #[entrypoint]
    pub struct ArbGuardChecker {}
}

/// Basis-point denominator: 10000 bps = 100%.
const BPS_DENOMINATOR: U256 = U256::from_limbs([10_000, 0, 0, 0]);

/// Outflow rule: the new withdrawal must fit inside the remaining per-window
/// outflow budget. Returns `false` on overflow (fail-closed).
///
/// * `amount_out` — value leaving the protocol in this action.
/// * `window_outflow` — value already out in the current window (e.g. block).
/// * `max_outflow` — the policy's per-window outflow cap.
pub fn check_outflow(amount_out: U256, window_outflow: U256, max_outflow: U256) -> bool {
    match window_outflow.checked_add(amount_out) {
        Some(total) => total <= max_outflow,
        // Overflow: the sum cannot be proven within budget, so block it.
        None => false,
    }
}

/// Price-deviation rule: the execution price must stay within `max_bps` of
/// the TWAP reference price. Returns `false` when `twap == 0` (no reference
/// price to compare against) or on overflow (fail-closed).
///
/// * `price` — execution / spot price of the action.
/// * `twap` — time-weighted average price reference (must be > 0).
/// * `max_bps` — maximum allowed deviation in basis points.
pub fn check_price_deviation(price: U256, twap: U256, max_bps: U256) -> bool {
    if twap.is_zero() {
        return false;
    }
    let deviation = if price >= twap {
        price - twap
    } else {
        twap - price
    };
    match (
        deviation.checked_mul(BPS_DENOMINATOR),
        twap.checked_mul(max_bps),
    ) {
        (Some(scaled_deviation), Some(scaled_cap)) => scaled_deviation <= scaled_cap,
        // Overflow on either side: cannot prove the deviation is within
        // bounds, so block it.
        _ => false,
    }
}

/// Single-action share rule: one action must not move more than `max_bps`
/// of total value locked. Returns `true` when `tvl == 0` (no TVL context
/// has been supplied, so there is nothing to compare against) and `false`
/// on overflow (fail-closed).
///
/// * `amount_out` — value leaving the protocol in this action.
/// * `tvl` — total value locked in the guarded protocol (0 = unknown/pass).
/// * `max_bps` — maximum allowed share of TVL in basis points.
pub fn check_share(amount_out: U256, tvl: U256, max_bps: U256) -> bool {
    if tvl.is_zero() {
        return true;
    }
    match (
        amount_out.checked_mul(BPS_DENOMINATOR),
        tvl.checked_mul(max_bps),
    ) {
        (Some(scaled_amount), Some(scaled_cap)) => scaled_amount <= scaled_cap,
        // Overflow on either side: cannot prove the share is within bounds,
        // so block it.
        _ => false,
    }
}

/// Declare that `ArbGuardChecker` is a contract with the following external
/// methods. Each entrypoint is a thin delegate to the pure function above,
/// so the on-chain behaviour and the unit tests exercise the same code.
#[public]
impl ArbGuardChecker {
    /// Outflow rule (see [`check_outflow`]).
    pub fn check_outflow(&self, amount_out: U256, window_outflow: U256, max_outflow: U256) -> bool {
        check_outflow(amount_out, window_outflow, max_outflow)
    }

    /// Price-deviation rule (see [`check_price_deviation`]).
    pub fn check_price_deviation(&self, price: U256, twap: U256, max_bps: U256) -> bool {
        check_price_deviation(price, twap, max_bps)
    }

    /// Single-action share rule (see [`check_share`]).
    pub fn check_share(&self, amount_out: U256, tvl: U256, max_bps: U256) -> bool {
        check_share(amount_out, tvl, max_bps)
    }
}

#[cfg(test)]
mod test {
    use super::*;

    // -- check_outflow -------------------------------------------------------

    #[test]
    fn outflow_normal_pass() {
        // 50 already out + 100 new = 150 <= 200 cap.
        assert!(check_outflow(
            U256::from(100),
            U256::from(50),
            U256::from(200)
        ));
    }

    #[test]
    fn outflow_exact_boundary_passes() {
        // 100 + 100 = 200 <= 200: exactly at the cap passes.
        assert!(check_outflow(
            U256::from(100),
            U256::from(100),
            U256::from(200)
        ));
    }

    #[test]
    fn outflow_one_over_boundary_fails() {
        // 100 + 101 = 201 > 200: one unit over the cap fails.
        assert!(!check_outflow(
            U256::from(101),
            U256::from(100),
            U256::from(200)
        ));
    }

    #[test]
    fn outflow_zero_amounts() {
        assert!(check_outflow(U256::ZERO, U256::ZERO, U256::ZERO));
        assert!(!check_outflow(U256::from(1), U256::ZERO, U256::ZERO));
    }

    #[test]
    fn outflow_overflow_fails_closed() {
        // window + amount overflows u256: must fail, never wrap.
        assert!(!check_outflow(U256::from(1), U256::MAX, U256::MAX));
        assert!(!check_outflow(U256::MAX, U256::MAX, U256::MAX));
    }

    #[test]
    fn outflow_max_values_pass_when_exact() {
        // No overflow, exactly at the maximum cap: passes.
        assert!(check_outflow(U256::MAX, U256::ZERO, U256::MAX));
    }

    // -- check_price_deviation ----------------------------------------------

    #[test]
    fn price_deviation_zero_twap_fails() {
        // No reference price: cannot prove the price is sane.
        assert!(!check_price_deviation(
            U256::from(100),
            U256::ZERO,
            U256::from(1000)
        ));
        assert!(!check_price_deviation(
            U256::ZERO,
            U256::ZERO,
            U256::from(10000)
        ));
    }

    #[test]
    fn price_deviation_exact_boundary_passes() {
        // |110 - 100| * 10000 = 100_000 <= 100 * 1000 = 100_000 (10% cap).
        assert!(check_price_deviation(
            U256::from(110),
            U256::from(100),
            U256::from(1000)
        ));
        // Same, price below TWAP.
        assert!(check_price_deviation(
            U256::from(90),
            U256::from(100),
            U256::from(1000)
        ));
    }

    #[test]
    fn price_deviation_one_over_boundary_fails() {
        // |111 - 100| * 10000 = 110_000 > 100_000.
        assert!(!check_price_deviation(
            U256::from(111),
            U256::from(100),
            U256::from(1000)
        ));
        // Same, price below TWAP.
        assert!(!check_price_deviation(
            U256::from(89),
            U256::from(100),
            U256::from(1000)
        ));
    }

    #[test]
    fn price_deviation_equal_price_always_passes() {
        assert!(check_price_deviation(
            U256::from(100),
            U256::from(100),
            U256::ZERO
        ));
    }

    #[test]
    fn price_deviation_zero_max_bps_only_exact_passes() {
        assert!(check_price_deviation(
            U256::from(100),
            U256::from(100),
            U256::ZERO
        ));
        assert!(!check_price_deviation(
            U256::from(101),
            U256::from(100),
            U256::ZERO
        ));
    }

    #[test]
    fn price_deviation_full_100_percent_cap() {
        // max_bps = 10000 allows the price to go to zero...
        assert!(check_price_deviation(
            U256::ZERO,
            U256::from(100),
            U256::from(10000)
        ));
        // ...but not to double (deviation 100 == cap 100 passes at exactly 2x).
        assert!(check_price_deviation(
            U256::from(200),
            U256::from(100),
            U256::from(10000)
        ));
        assert!(!check_price_deviation(
            U256::from(201),
            U256::from(100),
            U256::from(10000)
        ));
    }

    #[test]
    fn price_deviation_overflow_fails_closed() {
        // twap * max_bps overflows: fail, even though deviation is 0.
        assert!(!check_price_deviation(U256::MAX, U256::MAX, U256::MAX));
        // deviation * 10000 overflows: fail.
        assert!(!check_price_deviation(
            U256::MAX,
            U256::from(1),
            U256::from(10000)
        ));
    }

    // -- check_share ----------------------------------------------------------

    #[test]
    fn share_zero_tvl_passes() {
        // No TVL context: nothing to compare against, so pass.
        assert!(check_share(U256::MAX, U256::ZERO, U256::ZERO));
        assert!(check_share(U256::from(1), U256::ZERO, U256::from(500)));
    }

    #[test]
    fn share_exact_boundary_passes() {
        // 100 * 10000 = 1_000_000 <= 1000 * 1000 = 1_000_000 (10% cap).
        assert!(check_share(
            U256::from(100),
            U256::from(1000),
            U256::from(1000)
        ));
    }

    #[test]
    fn share_one_over_boundary_fails() {
        // 101 * 10000 = 1_010_000 > 1_000_000.
        assert!(!check_share(
            U256::from(101),
            U256::from(1000),
            U256::from(1000)
        ));
    }

    #[test]
    fn share_zero_amount_always_passes() {
        assert!(check_share(U256::ZERO, U256::from(1000), U256::ZERO));
    }

    #[test]
    fn share_zero_max_bps_blocks_any_positive_amount() {
        assert!(!check_share(U256::from(1), U256::from(1000), U256::ZERO));
    }

    #[test]
    fn share_overflow_fails_closed() {
        // amount * 10000 overflows: fail.
        assert!(!check_share(U256::MAX, U256::from(1000), U256::from(10000)));
        // tvl * max_bps overflows: fail.
        assert!(!check_share(U256::from(1), U256::MAX, U256::MAX));
        assert!(!check_share(U256::MAX, U256::MAX, U256::MAX));
    }

    // -- Stylus entrypoints (via TestVM) --------------------------------------
    //
    // The public entrypoints delegate to the same pure functions, so these
    // tests prove the on-chain-callable surface behaves identically.

    #[test]
    fn entrypoints_match_pure_functions() {
        use stylus_sdk::testing::*;
        let vm = TestVM::default();
        let contract = ArbGuardChecker::from(&vm);

        assert!(contract.check_outflow(U256::from(100), U256::from(50), U256::from(200)));
        assert!(!contract.check_outflow(U256::from(101), U256::from(100), U256::from(200)));

        assert!(contract.check_price_deviation(U256::from(110), U256::from(100), U256::from(1000)));
        assert!(!contract.check_price_deviation(U256::from(100), U256::ZERO, U256::from(1000)));

        assert!(contract.check_share(U256::from(100), U256::from(1000), U256::from(1000)));
        assert!(!contract.check_share(U256::from(101), U256::from(1000), U256::from(1000)));
        assert!(contract.check_share(U256::from(1), U256::ZERO, U256::ZERO));
    }
}
