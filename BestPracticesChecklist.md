# AOSSIE Best Practices Checklist

> Criteria adapted from the [OpenSSF Best Practices Badge](https://github.com/coreinfrastructure/best-practices-badge)
> (MIT / CC BY 3.0) by OpenSSF contributors. Modified for AOSSIE multi-repo template use.
> **Purpose:** Covers OpenSSF Best Practices criteria that are NOT auto-detected by OpenSSF Scorecard.
> Scorecard already handles: License, SAST tools, CI tests, Security Policy file, Branch Protection,
> Pinned Dependencies, Signed Releases, Maintained status, and Known Vulnerabilities.
>
> **How to use:**
> 1. Fill in checkboxes below — tick `[x]` for Met, leave `[ ]` for Unmet, use `[~]` for N/A
> 2. Add a brief note or URL after each item as evidence
> 3. Run the checklist-score workflow to update the badge automatically
>
> **Legend:**
> - 🔴 MUST — Required for passing
> - 🟡 SHOULD — Required unless documented rationale given
> - 🔵 SUGGESTED — Optional but recommended
> - ⚪ N/A — Mark `[~]` if not applicable, add justification

---

## Score Summary

<!-- Auto-updated by checklist-score.yml workflow — do not edit manually -->
| Category           | Met | Total | Status |
|--------------------|-----|-------|--------|
| Basics             | 0   | 8     | 🔴     |
| Change Control     | 0   | 6     | 🔴     |
| Reporting          | 0   | 8     | 🔴     |
| Quality            | 0   | 11    | 🔴     |
| Security           | 0   | 9     | 🔴     |
| Analysis           | 0   | 7     | 🔴     |
| **Total**          | **0** | **49** | **0%** |

---

## 🏗️ Basics

### Project Website & Documentation

- [x] 🔴 **description_good** — The project README/website clearly describes what the software does and what problem it solves.
  - *Evidence URL:* [README.md](README.md)

- [x] 🔴 **interact** — The project provides information on how to obtain the software, submit bug reports, and contribute.
  - *Evidence URL:* [README.md](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md)

- [x] 🔴 **contribution** — `CONTRIBUTING.md` explains the contribution process (e.g., PRs are used, how to open one).
  - *Evidence URL:* [CONTRIBUTING.md](CONTRIBUTING.md)

- [x] 🟡 **contribution_requirements** — `CONTRIBUTING.md` references acceptable contribution standards (coding style, tests required, etc.).
  - *Evidence URL:* [CONTRIBUTING.md](CONTRIBUTING.md)

- [x] 🔴 **documentation_basics** — Basic documentation exists for the software (README, Wiki, or docs folder).
  - *Evidence URL:* [README.md](README.md)

- [x] 🔴 **documentation_interface** — Reference documentation describes the external interface (API inputs/outputs, CLI flags, config schema, etc.).
  - *Evidence URL:* External contract interfaces and protocol functions are documented in [README.md](README.md) and Solidity source files under [`src/`](src/).

### Other Basics

- [x] 🔴 **discussion** — Project has a searchable, URL-addressable discussion mechanism (GitHub Issues, Discord with archive, mailing list, etc.) that doesn't require proprietary client software.
  - *Evidence URL:* [GitHub Issues](https://github.com/StabilityNexus/Gluon-EVM/issues)

- [x] 🟡 **english** — Documentation is provided in English and English bug reports/comments are accepted.
  - *Note:* Repository documentation, source comments, issues, and contribution guidelines are written in English.

---

## 🔄 Change Control

### Version Control

- [x] 🔵 **repo_distributed** — Project uses a distributed VCS (e.g., git). *(SUGGESTED)*
  - *Evidence URL:* [Gluon-EVM GitHub Repository](https://github.com/StabilityNexus/Gluon-EVM)

### Version Numbering

- [~] 🔴 **version_unique** — Each release has a unique version identifier (e.g., v1.0.0).
  - *Justification:* Not applicable yet. Gluon-EVM is currently under active beta development and does not have formal versioned releases.

- [~] 🔵 **version_semver** — Project uses [SemVer](https://semver.org) or [CalVer](https://calver.org/) format. *(SUGGESTED)*
  - *Justification:* Not applicable until formal releases are introduced.

- [~] 🔵 **version_tags** — Releases are tagged in the VCS (e.g., `git tag v1.0.0`). *(SUGGESTED)*
  - *Justification:* Not applicable until formal releases are introduced.

### Release Notes

- [~] 🔴 **release_notes** — Each release includes human-readable release notes summarizing major changes. Raw `git log` output is NOT acceptable.
  - *Justification:* Gluon-EVM does not currently publish formal releases.

- [~] 🔴 **release_notes_vulns** — Release notes identify every publicly known vulnerability (with CVE) fixed in that release.
  - *Justification:* Gluon-EVM does not currently publish formal releases.

---

## 🐛 Reporting

### Bug Reporting

- [x] 🔴 **report_process** — A bug-reporting process exists (e.g., GitHub Issues link in README).
  - *Evidence URL:* [CONTRIBUTING.md](CONTRIBUTING.md) and [GitHub Issues](https://github.com/StabilityNexus/Gluon-EVM/issues)

- [x] 🟡 **report_tracker** — An issue tracker (e.g., GitHub Issues) is used to track individual bugs.
  - *Evidence URL:* [GitHub Issues](https://github.com/StabilityNexus/Gluon-EVM/issues)

- [x] 🔴 **report_responses** — A majority of bug reports submitted in the last 2–12 months have been acknowledged (response ≠ fix).
  - *Self-certification note:* Identified bug reports in the qualifying period were acknowledged through follow-up fixes: issue #6 was addressed by PR #7 and issue #16 was addressed by PR #17. [Issue #6](https://github.com/StabilityNexus/Gluon-EVM/issues/6), [PR #7](https://github.com/StabilityNexus/Gluon-EVM/pull/7), [Issue #16](https://github.com/StabilityNexus/Gluon-EVM/issues/16), [PR #17](https://github.com/StabilityNexus/Gluon-EVM/pull/17).

- [x] 🟡 **enhancement_responses** — More than 50% of enhancement requests in the last 2–12 months have received a response.
  - *Self-certification note:* Issues #8 and #14 received responses while issue #18 has not; 2 of 3 identified enhancement requests received responses (>50%). [#8](https://github.com/StabilityNexus/Gluon-EVM/issues/8), [#14](https://github.com/StabilityNexus/Gluon-EVM/issues/14), [#18](https://github.com/StabilityNexus/Gluon-EVM/issues/18).

- [x] 🔴 **report_archive** — Reports and responses are publicly archived and searchable (GitHub Issues satisfies this).
  - *Evidence URL:* [GitHub Issues](https://github.com/StabilityNexus/Gluon-EVM/issues)

### Vulnerability Reporting

- [x] 🔴 **vulnerability_report_process** — A vulnerability reporting process is documented (e.g., `SECURITY.md`).
  - *Evidence URL:* [SECURITY.md](SECURITY.md)

- [x] 🟡 **vulnerability_report_private** — If private vulnerability reporting is supported, the method for private submission is documented.
  - *Evidence URL:* [SECURITY.md](SECURITY.md) documents private reporting through direct contact with project maintainers.

- [~] 🔴 **vulnerability_report_response** — Initial response to any vulnerability report received in the last 6 months was within 14 days.
  - *Justification:* No known vulnerability reports have been received during the current development period.

---

## ✅ Quality

### Build System

- [x] 🔴 **build** — If the project requires building, a working build system exists that can auto-rebuild from source.
  - *Evidence URL:* Gluon-EVM builds using Foundry with `forge build`.

- [x] 🔵 **build_common_tools** — Common build tools are used (npm, pip, cargo, make, gradle, etc.). *(SUGGESTED)*
  - *Evidence URL:* The project uses [Foundry](https://book.getfoundry.sh/) for Solidity builds and testing.

- [x] 🟡 **build_floss_tools** — The project can be built using only FLOSS tools.
  - *Note:* Foundry and Solidity are open-source development tools.

### Automated Testing

- [x] 🔵 **test_invocation** — The test suite can be invoked in a standard way for the language (e.g., `npm test`, `pytest`, `cargo test`). *(SUGGESTED)*
  - *Evidence URL:* Tests are executed using `forge test`.

- [ ] 🔵 **test_most** — The test suite covers most code branches, input fields, and functionality. *(SUGGESTED)*
  - *Estimated coverage:* 75.73% lines, 67.77% statements, 13.41% branches, and 77.19% functions.
  - *Note:* Coverage was measured using `forge coverage --ir-minimum` because the standard coverage build encountered a stack-too-deep compiler error.

### New Functionality Testing Policy

- [x] 🔴 **test_policy** — The project has a general policy that new functionality must include tests in the automated test suite.
  - *Evidence:* Documented in [CONTRIBUTING.md](CONTRIBUTING.md).

- [x] 🔴 **tests_are_added** — Evidence exists that the test policy has been followed in recent major changes (e.g., PRs include tests).
  - *Evidence URL:* Tests are maintained under [`test/`](test/), including `ChainlinkAdapter.t.sol`, `GenericIOracleIntegration.t.sol`, and `GluonIntegration.t.sol`.

- [x] 🔵 **tests_documented_added** — The test policy is documented in contribution instructions. *(SUGGESTED)*
  - *Evidence URL:* [CONTRIBUTING.md](CONTRIBUTING.md)

### Linting / Warning Flags

- [x] 🔴 **warnings** — At least one linter or compiler warning flag is enabled (ESLint, Pylint, clippy, golangci-lint, Slither for Solidity, etc.).
  - *Tool used:* Slither static analysis and Foundry compiler/lint checks. Slither was run with `slither . --exclude-dependencies`.

- [ ] 🔴 **warnings_fixed** — Warnings from the linter are addressed (not suppressed without reason).
  - *Note:* Requires a dedicated linter/static-analysis workflow before this criterion can be verified.

- [ ] 🔵 **warnings_strict** — Project uses maximum strictness in linter config where practical. *(SUGGESTED)*
  - *Note:* A dedicated strict static-analysis configuration has not yet been added.

---

## 🔐 Security

### Secure Development Knowledge

- [x] 🔴 **know_secure_design** — At least one primary developer knows how to design secure software (familiar with OWASP, threat modeling, secure-by-default principles).
  - *Self-certification note:* Active project development follows secure-by-default Solidity practices including access control, input validation, reentrancy protection, safe ERC-20 interactions, oracle validation, automated testing, and static analysis.

- [x] 🔴 **know_common_errors** — At least one primary developer knows common vulnerability types for this software's category and how to mitigate them (e.g., injection, XSS, reentrancy for Solidity, prompt injection for AI).
  - *Self-certification note:* Project development accounts for common Solidity vulnerabilities including reentrancy, access-control errors, unsafe type casts, invalid external inputs, oracle-related risks, precision loss, and arithmetic edge cases.

### Cryptography

- [~] 🔴 **crypto_published** — Only publicly reviewed cryptographic protocols/algorithms are used by default.
  - *Justification:* Gluon-EVM does not implement custom cryptographic algorithms.

- [~] 🟡 **crypto_call** — Project calls an established crypto library rather than reimplementing crypto functions.
  - *Justification:* Gluon-EVM does not implement custom cryptographic algorithms.

- [~] 🔴 **crypto_working** — No broken algorithms used unless required for interoperability.
  - *Justification:* Gluon-EVM does not implement custom cryptographic algorithms.

- [~] 🔴 **crypto_keylength** — Key lengths meet NIST 2030 minimums by default.
  - *Justification:* Key generation and key-length management are not implemented by the smart contracts.

- [~] 🔴 **crypto_password_storage** — Passwords for external users are stored as iterated salted hashes.
  - *Justification:* Smart contracts do not store user passwords.

- [~] 🔴 **crypto_random** — Cryptographic keys and nonces are generated using a CSPRNG.
  - *Justification:* Gluon-EVM does not generate cryptographic keys or security-sensitive random values.

- [~] 🟡 **delivery_unsigned** — Cryptographic hashes are NOT retrieved over plain HTTP without a signature check.
  - *Justification:* Gluon-EVM contracts do not retrieve cryptographic hashes over HTTP.

---

## 🔬 Analysis

### Static Code Analysis

- [x] 🔴 **static_analysis_fixed** — All medium+ severity vulnerabilities found by static analysis are fixed in a timely manner after confirmation.
  - *Note:* Slither analysis was performed and medium/high findings were manually triaged. No confirmed medium-or-higher exploitable vulnerability remains from the scan.

- [ ] 🔵 **static_analysis_common_vulnerabilities** — The static analysis tool includes checks for common vulnerabilities in the language/environment (e.g., eslint-plugin-security, bandit, Slither). *(SUGGESTED)*
  - *Tool + ruleset:* Slither is not currently integrated into the repository CI.

- [ ] 🔵 **static_analysis_often** — Static analysis runs on every commit or at least daily (CI integration). *(SUGGESTED)*
  - *Evidence URL:* Static analysis is not currently part of the CI workflow.

### Dynamic Code Analysis

- [ ] 🔵 **dynamic_analysis** — At least one dynamic analysis tool is applied before major releases (fuzzer, web app scanner like OWASP ZAP, etc.). *(SUGGESTED)*
  - *Tool used:* Dedicated fuzz/invariant testing is not currently established as part of the main test suite.

- [x] 🔵 **dynamic_analysis_enable_assertions** — Dynamic analysis / testing runs with assertions enabled (not just production mode). *(SUGGESTED)*
  - *Note:* Foundry tests use Solidity/Forge assertions to validate protocol behavior.

- [~] 🔴 **dynamic_analysis_fixed** — Medium+ severity vulnerabilities found by dynamic analysis are fixed in a timely manner.
  - *Justification:* No dedicated dynamic-analysis process is currently established, so this criterion is not applicable at this stage.

- [~] 🔵 **dynamic_analysis_unsafe** — If the project uses memory-unsafe languages (C/C++), memory safety tools (Valgrind, AddressSanitizer) are used. *(SUGGESTED)*
  - *Justification:* Not applicable. Gluon-EVM is implemented in Solidity and executes on the EVM.

---

## 📎 Project-Specific Notes

### Web3 / Solidity Notes

- Gluon-EVM is built using Solidity and Foundry.
- Oracle values used by the protocol are standardized to 18-decimal WAD precision.
- Oracle integrations use a shared `IOracle` interface.
- Current test coverage is approximately 75.73% for lines, 67.77% for statements, 13.41% for branches, and 77.19% for functions.
- `forge coverage --ir-minimum` is currently required for coverage generation because disabling `viaIR` results in a stack-too-deep compiler error.
- Slither can be introduced in CI to provide Solidity-specific static analysis.
- Additional fuzz and invariant tests can improve branch coverage for `StableCoinReactor` and `StableCoinFactory`.

---

*This checklist complements [OpenSSF Scorecard](https://scorecard.dev/) (auto-detected checks) and is
inspired by the [OpenSSF Best Practices Badge](https://www.bestpractices.dev/en/criteria/0) passing criteria.*
