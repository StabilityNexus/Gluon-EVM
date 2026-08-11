# Gluon-EVM Deployments

This document records beta and test deployments of Gluon-EVM.

## Ethereum Sepolia Testnet

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
