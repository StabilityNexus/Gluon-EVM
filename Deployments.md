# Gluon-EVM Deployments

This document records beta and test deployments of Gluon-EVM.

## Current Ethereum Sepolia Orb + Chainlink Deployment

This is the current Sepolia development deployment used to exercise both Orb and Chainlink
through the same `StableCoinFactory`.

- **Network:** Ethereum Sepolia
- **Chain ID:** `11155111`
- **Deployment type:** Testnet / development
- **Gluon-EVM source commit:** `b29fe82f6896bc36dce0fe61d4eb8a2a2a7ef0f6`
- **Factory:** `0x3Ca248b434DF95F20fc6469393D2e242243C47C6`
- **Reserve token:** `0x54C5eE811cC0be3FCF66CBb8104900bB3A44b44a`
- **Reserve token symbol:** `dETH`

### Factory Deployment

- **Factory:** `0x3Ca248b434DF95F20fc6469393D2e242243C47C6`
- **Deployment transaction:**
  `0xfd3ed93f7e9295b418ad0bf4ec8678b50b5d421fb24cbae5ebe55ff7db182458`

The same factory contains both current Sepolia reactors.

---

### Orb Reactor

Orb is connected directly through Gluon's `IOracle` interface. No Orb-specific adapter and no
Chainlink adapter are used in this reactor.

| Item | Value |
|---|---|
| Vault | `Sepolia Orb ETH Reactor` |
| Reactor | `0x8465812dDbf49dC5F5BE1799D22A1279db828Fe1` |
| Orb oracle | `0xff2b1fca4aF0c9BCb576178e6989AA92819a0294` |
| Base token | `0x54C5eE811cC0be3FCF66CBb8104900bB3A44b44a` |
| Neutron | `0xd991f9103C26B199bF98F87400da9F181c2AfBc1` |
| Proton | `0xda5406D2721173c3548B3f191178eB9e96396A00` |
| Treasury | `0x167F6b56DA92400f5e25d02CA0532Ddf2e25da63` |
| Fission fee | `0%` |
| Fusion fee | `0%` |
| Critical reserve ratio | `100%` |

Initial verified state:

- Initial reserve: `1 dETH`
- Orb price: `30 USD/dETH`
- Reserve ratio: `150%`
- Initial Neutron supply: `20 USD`
- Initial Proton supply: approximately `0.33333333333333334 pETH`

Orb deployment transactions:

| Action | Transaction |
|---|---|
| Approve initial reserve to Factory | `0xcbd29046d6b164df6d0734fa182a5639038262c09ce1c5600be4fea0a69c9493` |
| Deploy Orb reactor | `0x5da971ec083f2f3301233f8a1d8ac229ee5360331aae4b591afc7ae07e05907b` |

Orb WebUI smoke test:

| Action | Result | Transaction |
|---|---|---|
| Approve Reactor | `0.1 dETH` | `0x7337e79f9af05b0db70c233d2a4e342c1c7bb6c24af8446ecd65062730c717be` |
| Fission | `0.1 dETH` → `2 USD` + approximately `0.033333333 pETH` | `0xb7d0de724d60f3f476425bbece82dc8b9a82c376ee72e743bc3507983d7f5c9f` |
| Fusion | approximately `0.5 USD` + `0.008333333 pETH` → `0.025 dETH` | `0xcca4cf9d9b36063903edd5cfc1c20fc649327b193724c056484cc9036e411649` |

Final verified Orb state after the smoke test:

- Reserve: `1.075 dETH`
- Reserve ratio: `150%`
- Base price: `30 USD/dETH`
- Neutron supply: `21.5 USD`
- Proton supply: approximately `0.358333333333333341 pETH`

---

### Chainlink Reactor

The Chainlink reactor uses the Sepolia ETH/USD feed through a newly deployed
`ChainlinkToOracleAdapter`.

| Item | Value |
|---|---|
| Vault | `Sepolia Chainlink ETH Reactor` |
| Reactor | `0x09d45F9F3d99c04cB4AD2f7F3EAB524b5eA65e9e` |
| Chainlink ETH/USD feed | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| Chainlink adapter | `0x245FecC8457D98181164A74DB548B351D49ef20F` |
| Base token | `0x54C5eE811cC0be3FCF66CBb8104900bB3A44b44a` |
| Neutron | `0x005f0E9c4b33EB6844a9eDd10315296f6f938Bd3` |
| Proton | `0xE414a847e82789C424b46D569E7aa94323220483` |
| Treasury | `0xb9e9770Bd713b1dB125039A0C49B38074D4FE43B` |
| Fission fee | `0%` |
| Fusion fee | `0%` |
| Critical reserve ratio | `100%` |

Initial verified state:

- Initial reserve: `0.1 dETH`
- Base price at deployment: approximately `2700.42100052 USD/dETH`
- Reserve ratio: `150%`
- Initial Neutron supply: `180.028066701333333333 USD`
- Initial Proton supply: `0.033333333333333393 PETH`

Chainlink deployment transactions:

| Action | Transaction |
|---|---|
| Deploy Chainlink adapter | `0x72ef28b804402eeba096095704ddfd6cc78eadc49ccf2685e2e9484442c736a7` |
| Approve initial reserve to Factory | `0x984947eb6aa7cb57fad6dc12d58e5b8d5e9b6c3323e012eab1fc4325c5806a0d` |
| Deploy Chainlink reactor | `0xe53bfba5405be59d8144f7981cdd181f3619b93c421729f5368b052054518f22` |

Chainlink WebUI smoke test:

| Action | Result | Transaction |
|---|---|---|
| Approve Reactor | `0.01 dETH` | `0x078c050ca3158350564f3768bb9bc27ea3efa18fcc4a507f0b77a4d7ba0111cc` |
| Fission | `0.01 dETH` → approximately `18.0028 USD` + `0.003333333 PETH` | `0x3cc1d7aad66be7928b6d441c6f17c65784a0d0c88b5b9621271f8a5364f336d7` |
| Fusion | approximately `9.001403 USD` + `0.001666667 PETH` → `0.005 dETH` | `0x13e03dfea53392c1c9de1f70203938ce8d1dd0e6153445f7572852b3f9c55f22` |

Final verified Chainlink state after the smoke test:

- Reserve: `0.105 dETH`
- Reserve ratio: `150%`
- Base price: `2700.42100052 USD/dETH`
- Neutron supply: `189.0294700364 USD`
- Proton supply: `0.035000000000000063 PETH`

### Verified Dual-Oracle Flow

Runtime oracle paths:

    Orb
     ↓
    Orb Reactor

    Chainlink ETH/USD Feed
             ↓
    ChainlinkToOracleAdapter
             ↓
    Chainlink Reactor

Deployment and discovery:

    StableCoinFactory
        ├── Orb Reactor
        └── Chainlink Reactor

Both reactors were deployed and discovered through the same Sepolia factory and exercised
end-to-end through the Gluon-EVM WebUI with MetaMask.

This deployment is for development and testnet evaluation only. It is not a production deployment.

---

## Previous Ethereum Sepolia Testnet Deployment

- **Network:** Ethereum Sepolia
- **Chain ID:** `11155111`
- **Deployment type:** Midterm beta/test deployment

### Deployer

- **Address:** `0x167f6b56da92400f5e25d02ca0532ddf2e25da63`

### Demo Base Token

- **Contract:** `DemoBaseToken`
- **Address:** `0x54c5ee811cc0be3fcf66cbb8104900bb3a44b44a`
- **Name:** `Demo Ether`
- **Symbol:** `dETH`
- **Initial supply:** `10 dETH`
- **Recipient:** Deployment wallet

> `DemoBaseToken` is a test-only ERC-20 reserve asset used for the Sepolia demonstration.

### StableCoinFactory

- **Address:** `0x12711bf6c27de360d0c27473a6dc3446de756850`
- **Constructor parameters:** None
- **Owner:** Deployment wallet

### ChainlinkToOracleAdapter

- **Address:** `0xb924a7a94056d4fff2c7a4e64333784c50979035`

Constructor parameter:

| Parameter | Value |
|---|---|
| `feedParam` | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |

The configured feed is the Chainlink ETH/USD feed on Ethereum Sepolia.

### StableCoinReactor

- **Address:** `0xa358c6e3ebf5091f8d08f0b9dcdcec571944569e`
- **Deployed through:** `StableCoinFactory`

Configuration:

| Parameter | Value |
|---|---|
| Vault name | `Sepolia ETH Reactor` |
| Base asset name | `Demo Ether` |
| Base asset symbol | `dETH` |
| Base asset | `0x54c5ee811cc0be3fcf66cbb8104900bb3a44b44a` |
| Pegged asset name | `US Dollar` |
| Pegged asset symbol | `USD` |
| Oracle | `0xb924a7a94056d4fff2c7a4e64333784c50979035` |
| Proton name | `Proton ETH` |
| Proton symbol | `pETH` |
| Treasury | `0x167f6b56da92400f5e25d02ca0532ddf2e25da63` |
| Fission fee | `0` |
| Fusion fee | `0` |
| Critical reserve ratio | `1e18` |

### Reactor Assets

The reactor created the following protocol assets during deployment:

| Asset | Address |
|---|---|
| Neutron | `0xF592e8367b2004582eE3dF205fa2443df1b7Faf2` |
| Proton | `0x017F5F95c07A3BE3d9101993aE7A666398cC69F6` |

## Deployment Transactions

| Action | Transaction |
|---|---|
| Deploy DemoBaseToken | `0xd056f7ed1c38207ee02e331681ed3a92c003c67d955e8bf63e1e13ce60516efb` |
| Deploy StableCoinFactory | `0x64721cdbe22c2330b0f8680f2523ba9e9315081d731f7ef6105fd2d373465c5c` |
| Deploy ChainlinkToOracleAdapter | `0xffe8cc7865aaa7f6ef53903e433c4e3808a19916ea11589925354f295bf83aa0` |
| Deploy reactor through factory | `0x5c7bb33cd1878646522fecb2eac4f3ee5691e07bc1411f4ba58b9a21ce63a090` |
| Approve reactor | `0x662bbc672a708e7e7630e827af72a43e3500230c9d77a55f5b1201793f36c745` |
| Fission | `0x770e699287118d9050b32982664505666f2df64fdd70ee360766e7003392f55e` |
| Fusion | `0xc9da3b597faed33d0a68a79a69935383205f7be930cec31fa83a8b5ebf0564c3` |

Transactions can be inspected using the Ethereum Sepolia block explorer.

## Verified Test Flow

The deployment was tested on Sepolia with the following sequence:

1. Mint `10 dETH` to the deployment wallet.
2. Deploy the factory and Chainlink oracle adapter.
3. Deploy a reactor through the factory.
4. Approve the reactor to transfer `1 dETH`.
5. Execute fission with `1 dETH`.
6. Mint Proton and Neutron to the deployment wallet.
7. Execute fusion for `0.25 dETH`.
8. Burn the proportional Proton and Neutron amounts.
9. Return `0.25 dETH` to the deployment wallet.

After the test flow, the reactor reserve was `0.75 dETH`.

## Deployment Notes

This is a beta/test deployment intended for development and evaluation.

The deployment uses a test-only ERC-20 reserve token and should not be treated as a production deployment.

OrbOracle integration and other unmerged changes are not included in this deployment.
