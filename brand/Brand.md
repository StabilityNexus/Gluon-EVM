# Gluon-EVM Brand Guide

Gluon-EVM is a modular DeFi protocol built on the EVM around the `StableCoinReactor`. The protocol uses fission, fusion, and transmutation to split and recombine reserve-backed value through its Proton and Neutron assets.

Gluon is developed under [Stability Nexus](https://stability.nexus/). The visual identity should reflect the same qualities as the protocol: **stable, technical, modular, and precise**. Branding should remain simple and recognizable without adding unnecessary visual complexity.

## Logo

The Gluon mark is the primary visual identity of the project. The existing Gluon symbol is used across the Gluon ecosystem and is used here as the project mark for Gluon-EVM.

- `logo.svg` — the primary Gluon project logo. Use this whenever Gluon-EVM is represented on its own.
- `org-logo.svg` — the Stability Nexus organization logo. Use it when showing the relationship between Gluon-EVM and Stability Nexus, but never as a replacement for the Gluon logo.

**Usage rules**

- Keep enough clear space around the logo so it does not feel crowded by text or other elements.
- Do not stretch, skew, rotate, or otherwise distort the logo.
- Preserve the original colors of the logo.
- Prefer the SVG asset whenever possible so the mark remains sharp at different sizes.
- When the project name is shown beside the logo, use **Gluon** or **Gluon-EVM**, not **Gluon Gold**, since Gluon-EVM is the EVM implementation of the protocol.

## Favicons and Icons

- `favicon.svg` — the Gluon mark prepared for browser tabs and other small-icon contexts.
- The favicon uses the same Gluon symbol as `logo.svg` because the mark remains recognizable without text at small sizes.
- Do not include the project name inside the favicon, since text becomes unreadable at browser-tab sizes.
- If a platform requires PNG or `.ico` assets, generate them from `favicon.svg` instead of maintaining separate redesigned icons.

## Color Palette

The Gluon-EVM palette combines the existing gold identity of the Gluon mark with supporting colors for the protocol's EVM and DeFi interfaces.

| Swatch | Hex | Role |
| --- | --- | --- |
| 🟡 | `#FCCD11` | **Gluon Gold** — primary brand color and main logo accent |
| 🟨 | `#DFB302` | **Deep Gold** — secondary gold and supporting logo accent |
| 🌑 | `#0A1128` | **Reactor Deep** — primary dark background |
| 🔵 | `#1C7CFF` | **Stable Blue** — stability, pricing, oracle, and informational states |
| 🟠 | `#FF7E5F` | **Fission Orange** — fission, energy, warnings, and important actions |
| ⚪ | `#E0E6ED` | **Neutron Gray** — neutral UI elements, borders, and secondary text |
| ⬜ | `#FFFFFF` | **White** — primary light background and text on dark surfaces |

**Usage rules**

- `#FCCD11` is the primary Gluon identity color. Use it for important accents, selected states, key diagrams, and primary brand elements.
- `#DFB302` should support the primary gold rather than replace it.
- `#0A1128` is the preferred dark background for Gluon-branded interfaces.
- `#1C7CFF` should mainly represent stable, informational, pricing, or oracle-related UI states.
- `#FF7E5F` should be used sparingly for high-attention actions or protocol operations such as fission.
- Use `#E0E6ED` for neutral borders, secondary information, and low-emphasis UI elements.
- Do not use yellow or orange for long body text on light backgrounds.
- Maintain sufficient contrast between text and backgrounds, especially for small UI text.

## Typography

Gluon-EVM does not require custom fonts for its Solidity contracts or GitHub documentation. For the landing page, WebUI, dashboards, and other Gluon-branded interfaces, the recommended typography is:

- **Headings / UI:** [Space Grotesk](https://fonts.google.com/specimen/Space+Grotesk) — geometric and technical without being overly decorative.
- **Body text:** [Inter](https://fonts.google.com/specimen/Inter) — clean and highly readable for interfaces and documentation.
- **Code / addresses / hashes:** [JetBrains Mono](https://www.jetbrains.com/lp/mono/) — useful for contract addresses, transaction hashes, oracle values, and developer-facing data.

Recommended weights:

- Regular — body text
- Medium — navigation, labels, and controls
- Semibold — section headings and buttons
- Bold — major headings and important numeric values

If these fonts are unavailable, fall back to the system font stack:

`-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif`

## Protocol Visual Language

Gluon-EVM interfaces should visually distinguish protocol concepts without creating separate brands for each component.

- **Gluon Gold** represents the overall Gluon protocol identity.
- **Stable Blue** may be used for stable-value, oracle, or pricing-related information.
- **Fission Orange** may highlight fission, state changes, or high-attention protocol actions.
- **Neutron Gray** should be used for neutral or supporting information.
- Proton and Neutron should remain visually connected to the overall Gluon identity rather than appearing as unrelated products.

Diagrams for **fission**, **fusion**, and **transmutation** should remain simple and directional so that users can understand how reserve assets, Proton, and Neutron interact.

## Organization Attribution

Gluon-EVM is developed under Stability Nexus.

The Stability Nexus logo may be used:

- in repository headers and documentation
- in landing-page footers
- beside text such as "Developed under Stability Nexus"
- in organization/project pairing graphics

The Stability Nexus logo should not replace the Gluon logo when representing the project itself.

## File Location

All Gluon-EVM brand assets and this guide live in the [`brand/`](.) folder at the repository root:

```text
brand/
├── Brand.md
├── favicon.svg
├── logo.svg
└── org-logo.svg
```
