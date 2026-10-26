# Gluon-EVM — Peer Audit Remediation Report

**Date:** 26 October 2026\
**Peer audit:** [Gluon-EVM PR #71](https://github.com/StabilityNexus/Gluon-EVM/pull/71) (`audit/Gluon_EVM_Peer_Audit.md`; open for review at the time of this report)\
**Repositories:** [Gluon-EVM](https://github.com/StabilityNexus/Gluon-EVM) and [Gluon-EVM-WebUI](https://github.com/StabilityNexus/Gluon-EVM-WebUI)\
**Scope:** Disposition of the two findings in the peer audit. This is a follow-up record, not a new audit or a claim of mainnet readiness.

## Summary

| Peer-audit finding | Disposition | Supporting work |
| --- | --- | --- |
| β⁻ can raise the reserve ratio above 200%, temporarily gating subsequent operations | **Protocol-design behavior; no contract change** | [Gluon-EVM PR #36](https://github.com/StabilityNexus/Gluon-EVM/pull/36), existing integration test and permissionless `adjustPeg()` |
| An arbitrary URL-provided reactor address could reach wallet interaction controls without factory verification | **Frontend remediation merged** | [Gluon-EVM-WebUI PR #66](https://github.com/StabilityNexus/Gluon-EVM-WebUI/pull/66), merged 25 October 2026 |

The peer audit did not establish reserve theft or a completed phishing exploit. The two findings have different outcomes: the first is a documented protocol tradeoff, while the second required an implementation fix.

## Finding 1 — β⁻ post-transmutation reserve ratio above 200%

**What the audit found:** `transmuteNeutronToProton()` checks the current operating range before execution but can finish above the 200% upper bound. An earlier local reproduction converted 40e18 Neutrons and moved the reserve ratio from approximately 150% to 214.29%. A subsequent Fusion attempt reverted while the ratio was outside the permitted operating range.

**Investigation:** The 4 September 2026 maintainer discussion with Bruno distinguished the *resulting* ratio from the pre-operation check: β⁻ should not revert merely because its result exceeds 200%, whereas β⁺ must revert if its resulting ratio falls below the critical ratio `r*`. This policy is reflected in [merged PR #36](https://github.com/StabilityNexus/Gluon-EVM/pull/36), which explicitly permits a β⁻ result above 200%, and in `test/GluonIntegration.t.sol::testBetaMinusMayCrossAboveUpperReserveRatio()`.

**Disposition:** **No Solidity change proposed.** Adding a post-trade 200% revert for β⁻ would change this intentionally permitted behavior. The existing pre-operation operating-range gate remains in place. `adjustPeg()` is permissionless and provides the designed recovery mechanism. An experimental upper-bound guard was not submitted.

**Remaining limitation:** Normal reactions can be temporarily unavailable while the reactor sits above the upper operating range; peg recovery can require more than one adjustment. This availability consequence is not eliminated by this disposition. Any change to the protocol boundary or recovery policy should be reviewed by the protocol maintainers separately.

## Finding 2 — Unverified reactor address supplied through a URL

**What the audit found:** The WebUI could accept a manually constructed `/c?coin=<address>` link and mount wallet interaction controls for an address that had not been verified against the configured factory. A crafted link could therefore lead a user to approve tokens to an impersonating contract. User wallet approval would still be required; opening the link alone would not move assets.

**Remediation:** [WebUI PR #66 — Verify reactor addresses before enabling interactions](https://github.com/StabilityNexus/Gluon-EVM-WebUI/pull/66) was **merged on 25 October 2026**. It:

1. Validates the requested reactor address and checks it against the configured network factory's `getAllDeployedReactors()` registry.
2. Mounts the reactor dashboard, approval buttons and transaction hooks only after the registry check succeeds.
3. Fails closed for malformed, unregistered, unsupported-network, pending-verification and RPC-error cases; rechecks when the chain changes.
4. Preserves the existing Sepolia legacy-factory lookup and prevents pending native multi-step flows from continuing after the interaction component unmounts.

**Verification recorded in PR #66:** 11 dedicated URL-verification regression tests; 218/218 total frontend tests; TypeScript, ESLint, production build and GitHub checks passed. Manual Sepolia testing confirmed an unregistered address displayed **“Reactor not verified”** with no approval or interaction controls.

**Limitations:** This was a frontend-only fix; no Solidity contract, ABI or deployment-address change was required. Factory registration confirms provenance, **not** the economic safety of a permissionlessly deployed reactor. The referenced manual check was not an end-to-end malicious-approval exploit test. Deployment of the updated frontend to every public site was not verified by this report.

## Other observations and outstanding work

PR #71 also records design/validation observations, which should not be misrepresented as fixed by this remediation document:

- **Factory code size:** The reviewed factory runtime was 24,418 bytes, leaving 158 bytes beneath the EIP-170 limit. Recheck size before future code changes.
- **Forge gas-limit sensitivity:** The extreme peg-factor test exceeded the default per-test gas cap but passed with a raised test gas limit; this is not evidence of a failed live transaction.
- **Reaction availability and paper differences:** Operating-range gates in this implementation differ from Gluon W's described always-available reactions; the implications remain a protocol-design consideration.
- **Frontend dependency advisories:** The security-audit baseline records unresolved dependency vulnerabilities. PR #66's baseline update did not patch those dependencies. Separate dependency assessment/remediation remains necessary.

## Validation boundaries and conclusion

This report cites the peer audit's earlier contract checks and the recorded validation of merged WebUI PR #66. **No new Forge, npm, deployment, or live exploit tests were run to prepare this documentation.** The 200% β⁻ behavior has an intentional-design disposition supported by merged implementation history, but its temporary availability impact remains. The reactor-URL trust-boundary issue has a merged frontend fix, subject to deployed-site verification and independent review.

**Requested review:** Please check that these dispositions match the protocol policy and the two findings in [peer-audit PR #71](https://github.com/StabilityNexus/Gluon-EVM/pull/71). This documentation PR does not change contracts or frontend runtime code.
