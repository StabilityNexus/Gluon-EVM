# Contributing to Gluon-EVM

⭐ Thank you for considering contributing to Gluon-EVM! ⭐

Gluon-EVM is an EVM-based DeFi smart-contract protocol developed under Stability Nexus.

We welcome useful bug fixes, tests, documentation improvements, and focused protocol enhancements. By participating in this project, you agree to communicate respectfully and follow the contribution process described below.

---

## 🚨 Discord Communication Is Mandatory

**All project communication must happen on Discord. GitHub should primarily be used for issues, code, and pull requests.**

Before beginning work:

- Join the [Stability Nexus Discord server](https://discord.gg/hjUhu33uAn)
- Discuss the issue or proposed change in the relevant Discord channel
- Post updates about your issue or pull request on Discord
- Ask questions on Discord when requirements are unclear

Pull requests without Discord communication may experience review delays.

---

## 📋 Table of Contents

- [How Can I Contribute?](#-how-can-i-contribute)
- [Coding with AI](#-coding-with-ai)
- [Getting Started](#-getting-started)
- [Development Workflow](#-development-workflow)
- [Testing Your Changes](#-testing-your-changes)
- [Pull Request Guidelines](#-pull-request-guidelines)
- [Solidity Code Guidelines](#-solidity-code-guidelines)
- [Oracle Guidelines](#-oracle-guidelines)
- [Documentation Guidelines](#-documentation-guidelines)
- [Security](#-security)
- [Community Guidelines](#-community-guidelines)
- [Issue Assignment](#-issue-assignment)

---

## 🤝 How Can I Contribute?

### Reporting Bugs

Before opening a bug report, search existing issues and pull requests to avoid duplicates.

A useful bug report should include:

- a clear and descriptive title
- the affected contract or function
- the Git commit or branch tested
- steps to reproduce the issue
- expected behavior
- actual behavior
- relevant transaction traces or Forge output
- environment details
- a minimal reproduction when possible

Example environment details:

```text
Operating system:
Forge version:
Solidity version:
Repository commit:
Test command:
```

Do not publicly report vulnerabilities that could place deployed contracts or user funds at risk. Follow the instructions in the [Security](#security) section instead.

### Suggesting Features

Before proposing a feature:

- search existing issues and pull requests
- discuss the idea on Discord
- explain the problem being solved
- describe the expected behavior
- identify the contracts or interfaces likely to be affected
- explain why the change belongs in Gluon-EVM
- keep the proposal focused on one improvement

Large architecture changes should not be implemented without agreement from the maintainers.

### Contributing Code

1. Create or identify a relevant issue
2. Discuss the scope on Discord
3. Wait for assignment or maintainer confirmation when required
4. Create a focused branch
5. Implement one improvement
6. Add or update tests
7. Run all required checks
8. Open a pull request
9. Post the pull request in the relevant Discord channel

Pull requests unrelated to an issue or agreed scope may take longer to review or may be closed.

---

## 🤖 Coding with AI

AI-assisted contributions are allowed, including the use of tools such as:

- ChatGPT
- GitHub Copilot
- Claude
- Cursor
- other code-generation or review tools

Transparency is required.

Your pull request description must disclose:

- the AI tool used
- which parts of the contribution used AI assistance
- whether the generated content was manually reviewed
- how the implementation was tested and verified

Example:

```markdown
## AI Usage Disclosure

ChatGPT was used to help review the initial test structure and documentation wording.

All generated suggestions were manually reviewed. The implementation was verified with:

- `forge fmt --check`
- `forge build`
- `forge test`
- `git diff --check`
```

Contributors are responsible for every line they submit.

Do not submit AI-generated code that you:

- do not understand
- have not reviewed
- have not tested
- cannot explain during review
- have not checked against the existing architecture

AI-generated code should not introduce unnecessary abstractions, unrelated refactors, duplicate helpers, or overly complex implementations.

---

## 🚀 Getting Started

### Prerequisites

Install:

- [Git](https://git-scm.com/)
- [Foundry](https://getfoundry.sh/)

Verify the installation:

```bash
git --version
forge --version
cast --version
anvil --version
```

### Fork the Repository

Fork:

```text
https://github.com/StabilityNexus/Gluon-EVM
```

### Clone Your Fork

Replace `YOUR_USERNAME` with your GitHub username:

```bash
git clone --recurse-submodules https://github.com/YOUR_USERNAME/Gluon-EVM.git
cd Gluon-EVM
```

If you cloned without submodules:

```bash
git submodule update --init --recursive
```

### Add the Upstream Repository

```bash
git remote add upstream https://github.com/StabilityNexus/Gluon-EVM.git
```

Verify the remotes:

```bash
git remote -v
```

Expected structure:

```text
origin    https://github.com/YOUR_USERNAME/Gluon-EVM.git
upstream  https://github.com/StabilityNexus/Gluon-EVM.git
```

### Build the Project

```bash
forge build
```

### Run the Test Suite

```bash
forge test
```

---

## 🔄 Development Workflow

### 1. Update Your Local Main Branch

```bash
git checkout main
git fetch upstream
git pull --rebase upstream main
```

### 2. Create a New Branch

Never make contribution changes directly on `main`.

Use a descriptive branch name:

```bash
git checkout -b feat/your-feature-name
```

```bash
git checkout -b fix/your-bug-fix
```

```bash
git checkout -b test/your-test-improvement
```

```bash
git checkout -b docs/your-documentation-change
```

Examples:

```text
feat/oracle-integration
fix/invalid-price-validation
test/fusion-edge-cases
docs/update-deployment-guide
```

### 3. Keep the Change Focused

Each pull request should contain **one improvement**.

Do not combine:

- unrelated bug fixes
- documentation rewrites with protocol changes
- formatting changes across unrelated files
- multiple independent features
- dependency upgrades with functional changes

A small and focused pull request is easier to review, test, and merge.

### 4. Make Your Changes

While implementing:

- follow the existing contract structure
- preserve the current public interface unless the change was approved
- reuse existing helpers when appropriate
- avoid unnecessary refactoring
- avoid unrelated formatting changes
- add tests for new behavior
- update documentation when behavior changes
- keep the implementation as small as reasonably possible

### 5. Review the Diff

Before testing:

```bash
git status
git diff
```

Confirm that only intended files changed.

Check for whitespace errors:

```bash
git diff --check
```

### 6. Commit Your Changes

Stage only the intended files:

```bash
git add path/to/file.sol path/to/test.t.sol
```

Create a clear commit:

```bash
git commit -m "feat: add oracle interval support"
```

### Commit Message Format

Use a concise prefix:

| Prefix | Purpose |
|---|---|
| `feat:` | New functionality |
| `fix:` | Bug fix |
| `test:` | Test additions or corrections |
| `docs:` | Documentation changes |
| `refactor:` | Internal restructuring without behavioral change |
| `style:` | Formatting-only changes |
| `chore:` | Maintenance work |
| `ci:` | CI workflow changes |

Examples:

```text
feat: add generic oracle integration tests
fix: reject invalid oracle prices
test: cover fusion after fission
docs: document Sepolia deployment process
refactor: replace separate min and max oracle reads
```

Avoid vague messages such as:

```text
update files
changes
fix stuff
final change
```

### 7. Rebase Before Pushing

```bash
git fetch upstream
git rebase upstream/main
```

Resolve conflicts carefully and rerun all checks afterward.

### 8. Push Your Branch

For the first push:

```bash
git push -u origin your-branch-name
```

After rebasing an already-pushed branch:

```bash
git push --force-with-lease
```

Use `--force-with-lease`, not plain `--force`.

---

## 🧪 Testing Your Changes

Every Solidity change should be tested.

### Format the Code

```bash
forge fmt
```

Check formatting without modifying files:

```bash
forge fmt --check
```

### Build the Contracts

```bash
forge build
```

Build with contract-size information:

```bash
forge build --sizes
```

### Run All Tests

```bash
forge test
```

### Run Tests with Verbose Output

```bash
forge test -vvv
```

For detailed traces:

```bash
forge test -vvvv
```

### Run a Specific Test File

```bash
forge test --match-path test/ChainlinkAdapter.t.sol -vvv
```

```bash
forge test --match-path test/GluonIntegration.t.sol -vvv
```

```bash
forge test --match-path test/GenericIOracleIntegration.t.sol -vvv
```

### Run a Specific Test

```bash
forge test --match-test testFunctionName -vvv
```

### Run Tests for a Specific Contract

```bash
forge test --match-contract ContractTestName -vvv
```

### Gas Snapshot

When the change affects gas usage:

```bash
forge snapshot
```

Review the snapshot before committing it.

### Coverage

Generate a coverage report with:

```bash
forge coverage
```

If the standard coverage build encounters a `stack too deep` compiler error because coverage disables the optimizer and `viaIR`, use:

```bash
forge coverage --ir-minimum
```

The `--ir-minimum` option should only be used when necessary because it can result in less accurate source mappings.

### Required Final Checks

Run these before opening a pull request:

```bash
forge fmt --check
forge build
forge test
git diff --check
```

All checks must pass.

Do not hide failing tests or remove existing tests solely to make CI pass.

---

## 📤 Pull Request Guidelines

### Before Submitting

Confirm that:

- [ ] The change addresses a documented issue or agreed task
- [ ] The pull request contains one focused improvement
- [ ] Only intended files were changed
- [ ] Existing behavior was preserved unless intentionally changed
- [ ] Tests were added or updated where needed
- [ ] `forge fmt --check` passes
- [ ] `forge build` passes
- [ ] `forge test` passes
- [ ] `git diff --check` passes
- [ ] Documentation was updated where necessary
- [ ] AI usage was disclosed
- [ ] The branch was rebased onto the latest `main`
- [ ] The pull request was posted on Discord

### Pull Request Title

Use the same style as commit messages:

```text
feat: add OrbOracle integration tests
fix: reject zero oracle address
test: cover reserve ratio using adapter price
docs: improve Gluon architecture documentation
```

### Pull Request Description

Use the repository pull request template when one is available.

A useful pull request description should include:

```markdown
## Description

Explain what the pull request changes and why the change is needed.

## Related Issue

Closes #issue_number

## Changes

- Change one
- Change two
- Change three

## Testing

- `forge fmt --check`
- `forge build`
- `forge test`
- `git diff --check`

## Screenshots or Recordings

Not applicable for smart-contract-only changes unless the change affects rendered documentation or another visual interface.

## Additional Notes

Mention dependencies, follow-up work, assumptions, or review context.

## AI Usage Disclosure

State whether AI tools were used, which tools were used, and the scope of their use.

## Checklist

- [ ] The change is focused on one improvement
- [ ] Tests were added or updated
- [ ] All local checks pass
- [ ] Documentation was updated
- [ ] AI usage was disclosed
```

### After Submission

After opening the pull request:

- post it in the relevant Discord channel
- respond to review comments
- ask questions when feedback is unclear
- push requested changes to the same branch
- rerun all checks after every meaningful update
- avoid unrelated changes during review
- do not resolve review conversations before addressing them
- remain patient while maintainers review the change

Use a draft pull request for incomplete work.

Do not use an incomplete pull request to reserve or block an issue while no meaningful work is being completed.

### Responding to Review Feedback

When updating a pull request:

1. understand the requested change
2. make the smallest appropriate correction
3. rerun formatting, build, and tests
4. push the update
5. reply with what changed
6. mention any unresolved concern clearly

Avoid silently replacing large sections of the implementation without explaining why.

### Reviewing Pull Requests

Contributors are encouraged to review existing pull requests.

A useful review should consider:

- whether the change is necessary
- whether the implementation matches the issue
- whether the change is focused
- whether protocol behavior is preserved
- whether edge cases are tested
- whether external calls and token transfers are safe
- whether oracle values and units are handled correctly
- whether the implementation adds unnecessary complexity

Do not open a duplicate pull request when an active pull request already addresses the same issue.

---

## 📝 Solidity Code Guidelines

### General Guidelines

- Follow the existing Solidity style
- Run `forge fmt`
- Use meaningful names
- Keep functions focused
- Avoid unnecessary abstractions
- Avoid duplicated logic
- Prefer existing OpenZeppelin utilities when appropriate
- Preserve checks-effects-interactions ordering
- Consider reentrancy risk around external calls
- Validate external addresses and parameters
- Use comments to explain why, not obvious syntax
- Keep public interfaces stable unless a change was approved

### Errors

Prefer custom errors over long revert strings when following existing project conventions.

Example:

```solidity
error InvalidOracle();
```

```solidity
if (oracle == address(0)) revert InvalidOracle();
```

Use clear and specific error names.

### Units and Precision

Gluon uses WAD fixed-point values:

```solidity
uint256 constant WAD = 1e18;
```

When working with prices, ratios, or fees:

- confirm the expected unit
- document conversions
- use `Math.mulDiv` where appropriate
- avoid intermediate overflow
- avoid silent precision loss
- test boundary values

### Token Operations

When working with ERC-20 reserve assets:

- use `SafeERC20`
- validate zero amounts
- verify fee behavior
- test mint and burn effects
- test reserve changes
- consider tokens with unusual behavior when relevant

### Access Control

Changes involving treasury or ownership permissions should test:

- authorized callers
- unauthorized callers
- zero addresses
- ownership assignment
- expected revert selectors

### Events

When protocol behavior changes state, verify whether an existing event should be emitted or updated.

Tests should validate important event parameters when relevant.

### Comments and Documentation

Public or externally relevant functions should have clear NatSpec where useful.

Do not add comments that merely restate the code.

Good comments explain:

- units
- assumptions
- security constraints
- non-obvious calculations
- important invariants

---

## 🔮 Oracle Guidelines

Gluon uses a shared `IOracle` interface.

Oracle implementations and adapters must follow the current shared interface:

```solidity
interface IOracle {
    function readValue() external view returns (uint256 value);

    function readValueInterval()
        external
        view
        returns (uint256 minValue, uint256 maxValue);

    function lastUpdated() external view returns (uint256 timestamp);

    function description() external view returns (string memory);
}
```

Oracle implementations and adapters should:

- return unsigned values
- normalize values to 18-decimal WAD format
- reject invalid or non-positive prices
- expose value intervals through `readValueInterval()`
- expose the latest update timestamp through `lastUpdated()`
- expose a meaningful description
- follow the shared `IOracle` interface exactly

Do not introduce an oracle-specific adapter when the oracle can implement the shared interface directly, unless maintainers approve that architecture.

For example, an oracle such as OrbOracle should be integrated directly when it implements `IOracle`, rather than introducing an unnecessary Gluon-specific adapter.

### Value Intervals

Oracle implementations should expose their supported price interval using:

```solidity
function readValueInterval()
    external
    view
    returns (uint256 minValue, uint256 maxValue);
```

For price sources that expose only one current value, both values may be identical:

```text
minValue = value
maxValue = value
```

For oracle systems that calculate an actual range, the implementation should return the corresponding minimum and maximum values.

### Timestamp and Staleness

Oracle implementations should expose their latest update timestamp through:

```solidity
function lastUpdated() external view returns (uint256 timestamp);
```

Consumers are responsible for deciding whether an oracle value is too old for their use case unless the project architecture explicitly defines otherwise.

Do not add independent staleness-revert behavior inside an oracle integration without prior discussion because it can change integration semantics.

### Oracle Tests

Oracle-related contributions should consider:

- values below 18 decimals
- values equal to 18 decimals
- values above 18 decimals
- zero values
- negative source values
- value intervals
- update timestamps
- descriptions
- invalid feed contracts
- integration with `StableCoinReactor`
- factory deployment using the oracle
- reserve-ratio behavior
- price-view behavior
- fission behavior
- fusion behavior

---

## 📚 Documentation Guidelines

Documentation changes should:

- reflect the actual repository state
- avoid unsupported claims
- avoid placeholder text
- use current contract and function names
- keep commands executable
- distinguish planned deployments from completed deployments
- avoid listing security reviews that have not occurred
- update architecture diagrams when relationships change

For Mermaid diagrams:

- keep diagrams small
- avoid long edge labels
- avoid crossing lines
- move detailed explanations below the diagram
- verify the rendering through GitHub's Markdown preview

---

## 🔐 Security

Never commit:

- private keys
- seed phrases
- RPC credentials
- API keys
- `.env` files containing secrets
- production deployment credentials

Use environment variables for deployment configuration.

Before committing:

```bash
git diff --cached
```

Check that no secret or sensitive value is present.

### Reporting Vulnerabilities

Do not open a public issue for a vulnerability that could affect deployed contracts or user funds.

Contact the Stability Nexus team privately through:

- [Discord](https://discord.gg/hjUhu33uAn)
- [Telegram](https://t.me/StabilityNexus)

Include:

- affected contract and function
- impact
- reproduction steps
- proof of concept, when safe
- suggested mitigation, when available

Do not exploit a vulnerability beyond what is necessary to demonstrate it safely.

---

## 🌟 Community Guidelines

### Communication

- Be respectful and inclusive
- Keep technical discussions constructive
- Explain disagreements with evidence
- Ask questions when requirements are unclear
- Help other contributors when possible
- Avoid personal attacks or dismissive language

### Progress Updates

Post an update on Discord when:

- implementation is taking longer than expected
- the scope needs clarification
- you encounter a blocker
- you can no longer complete an assigned issue
- a pull request is ready for review
- reviewer feedback has been addressed

### Getting Help

Before asking for help:

1. read the README and contribution guide
2. search existing issues and pull requests
3. run the failing command with verbose output
4. collect the relevant error message or trace
5. explain what you already tried

When asking for help, include enough context for others to reproduce the problem.

---

## 🎯 Issue Assignment

- Prefer one contributor per issue unless collaboration is approved
- Check for existing pull requests before starting
- Do not work on an issue actively assigned to someone else
- Discuss the task on Discord before beginning significant work
- Wait for assignment when the issue explicitly requires it
- Keep progress visible through Discord updates
- Inform maintainers when you can no longer continue
- Do not reserve an issue without making progress
- Pull requests that significantly exceed the agreed scope may be asked to split into separate changes

When an unassigned issue has no active pull request, comment with your intended approach and communicate on Discord before beginning.

---

Thank you for contributing to Gluon-EVM. Your work helps improve the protocol, its testing, and its documentation. 🚀
