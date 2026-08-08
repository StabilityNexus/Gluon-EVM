# Gluon-EVM Deployments

This document lists the test/beta deployment details for the Gluon-EVM contracts.

## Ethereum Sepolia Testnet

* **Chain ID:** 11155111
* **RPC URL:** `[INSERT_SEPOLIA_RPC_URL_HERE]`

### 1. StableCoin Factory
* **Contract Address:** `[INSERT_FACTORY_ADDRESS_HERE]`
* **Constructor Parameters:**
  * None. The deployment wallet becomes the factory owner.

### 2. Chainlink Oracle Adapter
* **Contract Address:** `[INSERT_CHAINLINK_ADAPTER_ADDRESS_HERE]`
* **Constructor Parameters:**
  * `feedParam` (address): `[INSERT_CHAINLINK_FEED_ADDRESS_HERE]`

---

## Deployment Instructions

To execute this deployment again or verify:

1. Ensure your `.env` file contains your private key, Sepolia RPC URL, and Chainlink feed address:

   ```env
   PRIVATE_KEY=0x...
   SEPOLIA_RPC_URL=https://...
   CHAINLINK_FEED=0x...
   ```

2. Run the deployment script:

   ```bash
   set -a
   source .env
   set +a

   forge script script/Deploy.s.sol:DeployGluon --rpc-url "$SEPOLIA_RPC_URL" --broadcast
   ```
