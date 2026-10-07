// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IGluon {
    function fission(uint256 amountIn, address to, bytes[] calldata updateData) external payable;
    function NEUTRON_TOKEN() external view returns (address);
    function PROTON_TOKEN() external view returns (address);
}

/**
 * @title GluonPaymentRouter
 * @notice Helper contract to split Fission outputs:
 *         - Neutrons (Stable) -> Sent to Merchant
 *         - Protons (Volatile) -> Returned to User (Payer)
 */
contract GluonPaymentRouter {
    IGluon public gluon;
    IERC20 public neutron;
    IERC20 public proton;

    constructor(address _gluon) {
        require(_gluon != address(0), "Gluon: zero address");
        gluon = IGluon(_gluon);
        neutron = IERC20(gluon.NEUTRON_TOKEN());
        proton = IERC20(gluon.PROTON_TOKEN());
    }

    /**
     * @notice Performs fission with the attached value, sends Neutrons to merchant, returns Protons to sender.
     * @param merchant The address of the merchant to receive the stable payment.
     * @param updateData Pyth oracle update data (if needed).
     */
    function payWithFission(address merchant, bytes[] calldata updateData) external payable {
        require(merchant != address(0), "payWithFission: merchant is zero address");
        
        // 1. Record pre-fission balances to isolate newly minted tokens
        uint256 preNeutronBal = neutron.balanceOf(address(this));
        uint256 preProtonBal = proton.balanceOf(address(this));
        
        // 2. Perform Fission, minting both tokens to this contract
        gluon.fission{value: msg.value}(msg.value, address(this), updateData);

        // 3. Calculate only the newly minted amounts
        uint256 mintedNeutrons = neutron.balanceOf(address(this)) - preNeutronBal;
        uint256 mintedProtons = proton.balanceOf(address(this)) - preProtonBal;
        
        // 4. Verify fission produced tokens
        require(mintedNeutrons > 0 || mintedProtons > 0, "payWithFission: no tokens minted");

        // 5. Forward Neutrons to Merchant
        if (mintedNeutrons > 0) {
            neutron.transfer(merchant, mintedNeutrons);
        }

        // 6. Return Protons to Payer (User)
        if (mintedProtons > 0) {
            proton.transfer(msg.sender, mintedProtons);
        }
    }
    
    // Allow contract to receive ETH if needed (though fission usually consumes it)
    receive() external payable {}
}
