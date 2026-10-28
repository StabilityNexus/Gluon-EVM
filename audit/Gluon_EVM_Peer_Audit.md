# Gluon-EVM — Peer Review Report

**Repositories:** [StabilityNexus/Gluon-EVM](https://github.com/StabilityNexus/Gluon-EVM "StabilityNexus/Gluon-EVM") and [StabilityNexus/Gluon-EVM-WebUI](https://github.com/StabilityNexus/Gluon-EVM-WebUI "StabilityNexus/Gluon-EVM-WebUI")\
**Review area:** Gluon-EVM contracts and Gluon web frontend: reactor reserve accounting, fission/fusion, beta transmutations, Gluon Z pricing, peg adjustment, factory deployment and developer fees, token mint/burn permissions, oracle integration, deployment logic, wallet transaction flows, input validation, network configuration, responsive layout, and relevant tests.

## Overall assessment

The review identified two findings: (1) a beta-minus (β⁻) transmutation can raise the reserve ratio beyond the 200% operating limit, after which ordinary reactor operations revert until the peg is adjusted; and (2) the web UI accepts URL-supplied reactor addresses without verifying their provenance against the configured factory. The reserve-ratio boundary was reproduced in an earlier local integration test; no direct reserve loss or profitable exploit was established. The frontend trust-boundary scenario was confirmed in source but not reproduced as an end-to-end attack. Earlier contract and frontend test/build results are recorded in Validation.

## Findings

Both findings document observable behavior and potential impact, without asserting a completed exploit. Earlier frontend checks passed; dependency advisory details could not be retrieved. Responsive behavior, wallet interactions, and testnet flows were manually verified; see Validation.

## Finding 1 — Beta-minus transmutation can move the reserve ratio above the upper operating limit

**Severity:** Potential Medium — availability and operating-range impact; economic impact not established.  
**Location:** `src/StableCoin.sol`, `transmuteNeutronToProton()` and `adjustPeg()`; `test/GluonIntegration.t.sol`, `testBetaMinusMayCrossAboveUpperReserveRatio()`.

**Observation:** The beta-minus path checks that the reserve ratio is within the allowed operating range *before* transmutation but does not reject a transaction whose *resulting* reserve ratio exceeds 200%. Burning Neutrons reduces liability-side token supply, which can increase the ratio. In the reviewed reproduction, a transaction starting near **150%** moved the ratio to approximately **214.29%** after a 40e18-Neutron conversion. Subsequent ordinary operations, including fusion, reverted while the reactor was outside its operating range.

**Potential impact:** One otherwise valid conversion can cause subsequent routine reactor operations to be temporarily unavailable. Users depend on `adjustPeg()` being called enough times to move the reactor back into its operating range. No direct reserve loss, persistent lock, or profitable exploit was established by this test.

**Suggested resolution:** Assess the post-transmutation boundary policy and the recovery experience. Options to evaluate include a resulting-ratio bound for beta-minus or ensuring recovery is sufficiently reliable and practical before operations resume. Any change to transmutation acceptance rules requires protocol-owner review and dedicated regression tests.

## Finding 2 — Reactor page trusts an arbitrary address from the URL

**Severity:** Potential Medium — requires a crafted or untrusted link and wallet authorization; no end-to-end exploitation demonstrated.  
**Location:** WebUI `app/[coinId]/InteractionClient.tsx`, `app/[coinId]/hooks/useReactorContracts.ts` and `app/[coinId]/hooks/useReactorTransactions.ts`.

**Observation:** The `/c?coin=<address>` route passes the query value directly to the reactor interaction hooks. The UI reads reactor metadata and token addresses from that address and offers approval, fission, fusion and transmutation calls, but does not first establish factory provenance by checking it against `getAllDeployedReactors()` for the selected network. The Explorer uses factory-discovered reactors, but a direct URL bypasses that discovery path. A check that an address contains code would not, by itself, establish that it is an authorized reactor.

**Potential impact:** A malicious contract can imitate enough read methods to display attacker-controlled names, token addresses, balances or quotes, then receive wallet transactions when a user follows the link and approves/interacts. On the fission path, approval is granted to the URL-supplied reactor address for the entered amount; that contract can use the allowance to transfer that amount. Wallet approval remains required, so this is a phishing/trust-boundary issue rather than an automatic remote drain.

**Suggested resolution:** Validate the URL address against the selected network's configured factory before enabling approvals and other value-moving actions; if arbitrary or legacy reactors are intentionally supported, distinguish unverified addresses clearly and require an explicit acknowledgement. The existing factory already exposes `getAllDeployedReactors()`, so the basic provenance check can be implemented in the WebUI without changing the Solidity contracts.

## Design observation — Factory runtime is close to the EIP-170 limit

**Location:** `src/StableCoinFactory.sol`, reactor creation bytecode embedded in the factory.

Under `forge build --use 0.8.30 --force --sizes`, the factory runtime is **24,418 bytes**, leaving **158 bytes** below the 24,576-byte EIP-170 limit.

**Assessment:** Deployable at the reviewed revision and settings, but with very little room for future changes. Recheck runtime size whenever factory or reactor creation code changes.

## Design observation — Extreme peg-recovery test exceeds the default Forge gas cap

**Location:** `test/PegFactorRegression.t.sol`, `testExtremeSupplyPreservesPositiveFactorAndUpwardRecovery()`.

The prescribed `forge test --use 0.8.30 --force --fuzz-runs 512` run completed with 195 passed and one failure: this test ran out of the default 2^30 test gas cap while looping through many peg adjustments inside one test call. The test passed with `--gas-limit 3000000000`, and the full suite passed at that limit (196 passed, 0 failed).

**Assessment:** Test-harness gas-limit sensitivity, not an observed on-chain failure. Each peg adjustment can be submitted as a separate transaction in practice.

## Design observation - EVM operation gates differ from Gluon W's always-available reactions

The Gluon W paper's related-work section says users are never forbidden from performing any of its four reactions. In this EVM implementation, fission, fusion and both transmutations call `_requireOperatingRange` and revert outside the configured reserve-ratio band. `adjustPeg()` is permissionless, but recovery may require multiple 1% adjustment transactions before those user actions are enabled again. The paper's always-available redemption/reaction property and formal claims should not be assumed to apply unchanged. See the [paper's Section 5](https://cdn.jsdelivr.net/gh/StabilityNexus/Papers/papers/Gluon/W/v2.pdf).

## Other areas inspected

- Fission and fusion reserve flows, native-token decimal normalization, fee retention, and conservative rounding.
- Both beta conversion directions, minimum-output checks, developer-fee routing, and volume-ledger updates.
- Gluon Z liabilities/equity calculations and reserve-ratio boundary behavior.
- Permissionless, incremental `adjustPeg()` behavior and two-step local developer handover.
- Factory-set immutable developer settings and Tokeon ownership restricted to the reactor.
- Chainlink answer scaling and the reactor’s cached-price fallback.

The README explicitly states that age-based oracle rejection is intentionally omitted to preserve redemptions during prolonged feed outages. This behavior is treated as a design choice, not a finding. Small operations may round to zero as documented; transmutation callers can request a positive minimum output.

## Coverage checklist — review status

Statuses apply only to the reviewed source revision and the stated review depth. `No issue identified` records that the listed area was reviewed without a substantiated finding; it is not a guarantee that no such issue exists.

| Component / category | Status | Coverage note |
|---|---|---|
| Contract access control and token mint/burn permissions | No issue identified | Reactor ownership of Tokeon; developer-only settings and two-step handover paths inspected. |
| Reserve flows, fee accounting, and tranche supply changes | No issue identified | Fission, fusion, both beta directions, and fee routing inspected; rounding and value-conservation tests run. |
| Arithmetic, reserve-ratio boundaries, and decimal normalization | See Finding 1 | β⁻ post-trade upper-bound crossing documented; other 0–18 decimal and Gluon Z/rounding checks passed at the 3-billion test gas limit. |
| Reentrancy on user value-moving operations | No issue identified | Guarded fission, fusion, transmutations, and initialization call paths inspected. |
| Oracle adapter and cached-price behavior against the stated design | No issue identified | The README explicitly accepts stale prices and rejects routine freshness timeouts; treated as intended design. |
| Factory initialization and developer-fee configuration | No issue identified | Constructor and public deployment flow inspected; factory settings are immutable as designed. |
| Gluon-EVM WebUI source: wallet flows, creation inputs, oracle preflight, and network selection | See Finding 2 | No other issue identified in reviewed flows; earlier frontend checks passed. |
| Responsive layout across screen sizes and mobile browsers | Manually verified | Layout and usability were checked at different screen sizes and in mobile browsers. |
| Live wallet transactions and testnet end-to-end flows | Manually verified | Wallet interactions and testnet flows were exercised and completed successfully. |
| Frontend dependency advisory status | Not verified | npm ci reported 34 vulnerabilities (26 moderate, 6 high, 2 critical); the production-only audit could not reach the registry to provide package-level details. |

## Frontend review notes

The web UI is configured for static export and browser-side wallet interaction. The inspected code performs decimal-aware amount parsing, checks oracle addresses against deployed code and expected read methods before creation, verifies the RPC chain ID, and uses minimum-output bounds for conversion transactions. Network configuration enables a factory for Sepolia only; the other displayed networks do not have a deployment factory configured in this revision. No issue was substantiated from those behaviors.

The frontend package lock pins `next` to 14.2.16, and `scripts/security-audit.mjs` identifies a pre-reviewed high/critical dependency baseline. `npm ci` completed with 1,167 packages installed; npm reported 34 vulnerabilities (26 moderate, 6 high, 2 critical) across the dependency tree. The production-only audit could not retrieve package-level advisory details because DNS resolution for `registry.npmjs.org` failed. Accordingly, this review does not claim that the dependency tree is clear or that a particular advisory is exploitable in the static-export deployment.

## Validation

The follow-up contract and frontend source verification was read-only; no new Forge, npm, or build command was run during that verification. The Forge and frontend results below are from earlier validation passes. The β⁻ reproduction was performed separately in earlier local integration work.

- `forge fmt --check` reported newline-only diffs across files. Git reports `core.autocrlf=true` and LF in the index / CRLF in the checkout; no formatting changes were made.
- `forge build --use 0.8.30 --force --sizes`: passed.
- `forge test --use 0.8.30 --force --fuzz-runs 512`: 195 passed, 1 failed at the default gas cap described above.
- `forge test --use 0.8.30 --fuzz-runs 512 --gas-limit 3000000000`: 196 passed, 0 failed.
- Earlier separate β⁻ boundary reproduction on the combined PR #62/#67 code base: a 40e18-Neutron conversion moved the ratio from about 150% to 214.29%, and a subsequent ordinary fusion reverted until peg adjustment. This is distinct from the 196-test baseline above.
- Frontend `npm ci`: completed; 1,167 packages added. npm reported 34 vulnerabilities (26 moderate, 6 high, 2 critical).
- Frontend typecheck: passed (`npm run typecheck`).
- Frontend lint: passed (`npm run lint`, zero warnings).
- Frontend tests: 207 passed across 23 files. An initial run failed before executing tests because the sandbox temporary directory rejected cache renames; rerun passed with `TEMP`, `TMP`, and `TMPDIR` pointed to a writable directory in the checkout.
- Frontend production build: passed. Next.js warned that optional `sharp` is absent and Google Fonts could not be downloaded; it skipped font optimization and completed static generation.
- Frontend production dependency audit (`npm audit --omit=dev`): could not retrieve advisory details because `registry.npmjs.org` DNS resolution failed. The npm install summary above is the available vulnerability count; package-level audit results remain unverified.

## Conclusion

**Two findings are presented for review:** β⁻ transmutation can move the reactor above its 200% operating range and temporarily block routine operations pending peg adjustment; and the WebUI treats a URL-provided reactor address as interactable without establishing factory provenance. The β⁻ behavior was reproduced in an earlier local test; the URL-based attack path has not been reproduced end to end. Neither finding establishes direct reserve theft or a profitable exploit. Stale-price acceptance is explicitly documented as a design choice, not a vulnerability. Earlier frontend checks passed; dependency advisories remain unverified. The factory's narrow deployment-size headroom, the extreme test's default gas-limit sensitivity, and the documented reaction-gating divergence remain operational or protocol-design considerations.