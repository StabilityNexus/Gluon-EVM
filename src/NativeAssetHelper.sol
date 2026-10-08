// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StableCoinReactor} from "./StableCoin.sol";
import {IWrappedNative} from "./interfaces/IWrappedNative.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Provides native-asset entry and exit for Gluon reactors whose
/// base token is the corresponding wrapped native ERC20.
///
/// The Gluon protocol itself continues to operate entirely with ERC20 assets.
contract NativeAssetHelper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IWrappedNative public immutable WRAPPED_NATIVE;

    error InvalidWrappedNative();
    error InvalidReactor();
    error InvalidRecipient();
    error AmountZero();
    error BaseTokenMismatch();
    error UnexpectedWrappedAmount();
    error FissionOutputBelowMinimum();
    error FusionInputAboveMaximum();
    error NativeOutputBelowMinimum();
    error NativeTransferFailed();
    error UnauthorizedNativeSender();

    event NativeFission(
        address indexed caller,
        address indexed reactor,
        address indexed recipient,
        uint256 nativeIn,
        uint256 neutronOut,
        uint256 protonOut
    );

    event NativeFusion(
        address indexed caller,
        address indexed reactor,
        address indexed recipient,
        uint256 baseAmount,
        uint256 nativeOut
    );

    constructor(address wrappedNativeParam) {
        if (wrappedNativeParam == address(0) || wrappedNativeParam.code.length == 0) {
            revert InvalidWrappedNative();
        }

        WRAPPED_NATIVE = IWrappedNative(wrappedNativeParam);
    }

    /// @notice Wrap native currency and fission the resulting wrapped token.
    /// Neutron and Proton are minted directly to `recipient`.
    function fissionNative(address reactorAddress, address recipient, uint256 minNeutronOut, uint256 minProtonOut)
        external
        payable
        nonReentrant
        returns (uint256 neutronOut, uint256 protonOut)
    {
        if (msg.value == 0) revert AmountZero();

        StableCoinReactor reactor = _validatedReactor(reactorAddress, recipient);

        IERC20 neutron = IERC20(address(reactor.NEUTRON_TOKEN()));
        IERC20 proton = IERC20(address(reactor.PROTON_TOKEN()));
        IERC20 wrapped = IERC20(address(WRAPPED_NATIVE));

        uint256 neutronBefore = neutron.balanceOf(recipient);
        uint256 protonBefore = proton.balanceOf(recipient);
        uint256 wrappedBefore = wrapped.balanceOf(address(this));

        WRAPPED_NATIVE.deposit{value: msg.value}();

        uint256 wrappedReceived = wrapped.balanceOf(address(this)) - wrappedBefore;
        if (wrappedReceived != msg.value) revert UnexpectedWrappedAmount();

        wrapped.forceApprove(reactorAddress, wrappedReceived);

        reactor.fission(wrappedReceived, recipient);

        wrapped.forceApprove(reactorAddress, 0);

        neutronOut = neutron.balanceOf(recipient) - neutronBefore;
        protonOut = proton.balanceOf(recipient) - protonBefore;

        if (neutronOut < minNeutronOut || protonOut < minProtonOut) {
            revert FissionOutputBelowMinimum();
        }

        emit NativeFission(msg.sender, reactorAddress, recipient, msg.value, neutronOut, protonOut);
    }

    /// @notice Pull the exact tranche amounts required for fusion from the
    /// caller, redeem them for wrapped native currency, unwrap it, and send
    /// the resulting native currency to `recipient`.
    function fusionNative(
        address reactorAddress,
        uint256 baseAmount,
        address recipient,
        uint256 maxNeutronIn,
        uint256 maxProtonIn,
        uint256 minNativeOut
    ) external nonReentrant returns (uint256 nativeOut, uint256 neutronIn, uint256 protonIn) {
        if (baseAmount == 0) revert AmountZero();

        StableCoinReactor reactor = _validatedReactor(reactorAddress, recipient);

        (neutronIn, protonIn) = reactor.fusionBurnAmounts(baseAmount);

        if (neutronIn > maxNeutronIn || protonIn > maxProtonIn) {
            revert FusionInputAboveMaximum();
        }

        IERC20 neutron = IERC20(address(reactor.NEUTRON_TOKEN()));
        IERC20 proton = IERC20(address(reactor.PROTON_TOKEN()));
        IERC20 wrapped = IERC20(address(WRAPPED_NATIVE));

        neutron.safeTransferFrom(msg.sender, address(this), neutronIn);
        proton.safeTransferFrom(msg.sender, address(this), protonIn);

        uint256 wrappedBefore = wrapped.balanceOf(address(this));

        reactor.fusion(baseAmount, address(this));

        nativeOut = wrapped.balanceOf(address(this)) - wrappedBefore;

        if (nativeOut < minNativeOut) revert NativeOutputBelowMinimum();

        WRAPPED_NATIVE.withdraw(nativeOut);

        (bool success,) = recipient.call{value: nativeOut}("");
        if (!success) revert NativeTransferFailed();

        emit NativeFusion(msg.sender, reactorAddress, recipient, baseAmount, nativeOut);
    }

    function _validatedReactor(address reactorAddress, address recipient)
        internal
        view
        returns (StableCoinReactor reactor)
    {
        if (reactorAddress == address(0) || reactorAddress.code.length == 0) {
            revert InvalidReactor();
        }

        if (recipient == address(0) || recipient == address(this)) {
            revert InvalidRecipient();
        }

        reactor = StableCoinReactor(reactorAddress);

        if (address(reactor.BASE_TOKEN()) != address(WRAPPED_NATIVE)) {
            revert BaseTokenMismatch();
        }
    }

    /// @dev Native currency is accepted only while WRAPPED_NATIVE.withdraw()
    /// is unwrapping assets for a fusion.
    receive() external payable {
        if (msg.sender != address(WRAPPED_NATIVE)) {
            revert UnauthorizedNativeSender();
        }
    }
}
