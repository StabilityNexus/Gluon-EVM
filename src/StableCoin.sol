// SPDX-License-Identifier: AEL
pragma solidity ^0.8.20;

import {Tokeon} from "./tokens/Tokeon.sol";

import {IOracle} from "./interfaces/IOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract StableCoinReactor is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant WAD = 1e18;
    uint256 public constant PEGGED_ASSET_WAD = 1e18; // peg target
    uint256 public constant UPPER_RESERVE_RATIO = 2e18;
    uint256 internal constant INITIAL_RESERVE_RATIO = 15e17;
    // Prices and step coefficients remain WAD; the dimensionless peg factor has 36 decimals.
    uint256 public constant PEG_FACTOR_SCALE = 1e36;
    uint256 public constant PEG_DOWN_FACTOR_WAD = 99e16;
    uint256 public constant PEG_UP_FACTOR_WAD = 101e16;

    error InvalidBaseToken();
    error InvalidBaseTokenDecimals(uint8 decimals);
    error InvalidOracle();
    error OracleNotContract();
    error InvalidDev();
    error InvalidDevFeeReceiver();
    error InvalidDevFee();
    error OnlyDev();
    error OnlyPendingDev();
    error InvalidFissionFee();
    error InvalidFusionFee();
    error InvalidCriticalReserveRatio();
    error EmptyVaultName();
    error EmptyBaseName();
    error EmptyBaseSymbol();
    error EmptyPegName();
    error EmptyPegSymbol();
    error EmptyProtonName();
    error EmptyProtonSymbol();
    error InvalidPhi();
    error InvalidDecay();
    error AmountZero();
    error AmountTooSmall();
    error EmptyReserve();
    error EmptySupply();
    error InvalidInitialReserve();
    error OnlyFactory();
    error AlreadyInitialized();
    error PegAdjustmentNotNeeded();
    error ReserveRatioOutOfRange(uint256 reserveRatio);
    error ResultingReserveRatioBelowCritical();

    // Tokens
    Tokeon public immutable NEUTRON_TOKEN; // stable token (peg)
    Tokeon public immutable PROTON_TOKEN; // volatile token
    IERC20 public immutable BASE_TOKEN; // reserve asset (ERC20)
    uint256 internal immutable BASE_TOKEN_UNIT;

    // Metadata
    string public vaultName;
    string public baseAssetName;
    string public baseAssetSymbol;
    string public peggedAssetName;
    string public peggedAssetSymbol;

    // Oracle
    IOracle public immutable ORACLE;
    uint256 public lastSuccessfulBasePrice;

    address public immutable FACTORY;
    address public dev;
    address public pendingDev;
    address public devFeeReceiver;
    uint256 public immutable devFee;
    uint256 public immutable FISSION_FEE;
    uint256 public immutable FUSION_FEE;
    uint256 public immutable CRITICAL_RESERVE_RATIO;

    uint256 public pegFactor = PEG_FACTOR_SCALE;

    // β fee parameters
    uint256 public immutable betaPhi0;
    uint256 public immutable betaPhi1;
    uint256 public immutable decayPerSecondWad;
    uint256 private decayedVolumePlusBase;
    uint256 private decayedVolumeMinusBase;
    uint256 private lastDecayTs;

    event Fission(
        address indexed from,
        address indexed to,
        uint256 baseIn,
        uint256 neutronOut,
        uint256 protonOut,
        uint256 protocolFee,
        uint256 devFeeAmount
    );
    event Fusion(
        address indexed from,
        address indexed to,
        uint256 neutronBurn,
        uint256 protonBurn,
        uint256 baseOut,
        uint256 protocolFee,
        uint256 devFeeAmount
    );
    event TransmutePlus(
        address indexed from,
        address indexed to,
        uint256 protonIn,
        uint256 neutronOut,
        uint256 feeWad,
        uint256 newDecayedVolumePlusBase,
        uint256 newDecayedVolumeMinusBase,
        uint256 devFeeAmount
    );
    event TransmuteMinus(
        address indexed from,
        address indexed to,
        uint256 neutronIn,
        uint256 protonOut,
        uint256 feeWad,
        uint256 newDecayedVolumePlusBase,
        uint256 newDecayedVolumeMinusBase,
        uint256 devFeeAmount
    );
    event DevTransferProposed(address indexed previousDev, address indexed proposedDev);
    event DevTransferred(address indexed previousDev, address indexed newDev);
    event DevFeeReceiverChanged(address indexed previousReceiver, address indexed newReceiver);

    event PegAdjusted(uint256 previousPegFactor, uint256 newPegFactor, uint256 reserveRatio);

    constructor(
        string memory vaultNameParam,
        string memory baseAssetNameParam,
        string memory baseAssetSymbolParam,
        string memory peggedAssetNameParam,
        string memory peggedAssetSymbolParam,
        address baseTokenParam,
        address oracleParam, // Replaced specific Pyth params with generic Oracle address
        string memory protonNameParam,
        string memory protonSymbolParam,
        address devParam,
        uint256 devFeeParam,
        uint256 fissionFeeParam,
        uint256 fusionFeeParam,
        uint256 criticalReserveRatioWadParam,
        uint256 betaPhi0Param,
        uint256 betaPhi1Param,
        uint256 decayPerSecondWadParam
    ) {
        if (baseTokenParam == address(0) || baseTokenParam.code.length == 0) {
            revert InvalidBaseToken();
        }

        uint8 baseTokenDecimals;
        try IERC20Metadata(baseTokenParam).decimals() returns (uint8 decimals_) {
            baseTokenDecimals = decimals_;
        } catch {
            revert InvalidBaseToken();
        }

        if (baseTokenDecimals > 18) revert InvalidBaseTokenDecimals(baseTokenDecimals);
        BASE_TOKEN_UNIT = 10 ** uint256(baseTokenDecimals);

        if (oracleParam == address(0)) revert InvalidOracle();
        if (oracleParam.code.length == 0) revert OracleNotContract();
        if (devParam == address(0)) revert InvalidDev();
        if (devFeeParam >= WAD) revert InvalidDevFee();
        if (fissionFeeParam >= WAD - devFeeParam) revert InvalidFissionFee();
        if (fusionFeeParam >= WAD - devFeeParam) revert InvalidFusionFee();
        if (betaPhi0Param > WAD || betaPhi1Param > WAD) revert InvalidPhi();
        if (decayPerSecondWadParam > WAD) revert InvalidDecay();
        if (criticalReserveRatioWadParam < WAD || criticalReserveRatioWadParam >= UPPER_RESERVE_RATIO) {
            revert InvalidCriticalReserveRatio();
        }
        if (bytes(vaultNameParam).length == 0) revert EmptyVaultName();
        if (bytes(baseAssetNameParam).length == 0) revert EmptyBaseName();
        if (bytes(baseAssetSymbolParam).length == 0) revert EmptyBaseSymbol();
        if (bytes(peggedAssetNameParam).length == 0) revert EmptyPegName();
        if (bytes(peggedAssetSymbolParam).length == 0) revert EmptyPegSymbol();
        if (bytes(protonNameParam).length == 0) revert EmptyProtonName();
        if (bytes(protonSymbolParam).length == 0) revert EmptyProtonSymbol();

        vaultName = vaultNameParam;
        baseAssetName = baseAssetNameParam;
        baseAssetSymbol = baseAssetSymbolParam;
        peggedAssetName = peggedAssetNameParam;
        peggedAssetSymbol = peggedAssetSymbolParam;

        BASE_TOKEN = IERC20(baseTokenParam);
        ORACLE = IOracle(oracleParam);
        CRITICAL_RESERVE_RATIO = criticalReserveRatioWadParam;

        FACTORY = msg.sender;

        NEUTRON_TOKEN = new Tokeon(peggedAssetNameParam, peggedAssetSymbolParam, address(this));
        PROTON_TOKEN = new Tokeon(protonNameParam, protonSymbolParam, address(this));

        dev = devParam;
        devFeeReceiver = devParam;
        devFee = devFeeParam;
        FISSION_FEE = fissionFeeParam;
        FUSION_FEE = fusionFeeParam;

        betaPhi0 = betaPhi0Param;
        betaPhi1 = betaPhi1Param;
        decayPerSecondWad = decayPerSecondWadParam;
        lastDecayTs = block.timestamp;
    }

    function proposeDev(address newDev) external {
        if (msg.sender != dev) revert OnlyDev();
        if (newDev == address(0)) revert InvalidDev();
        pendingDev = newDev;
        emit DevTransferProposed(dev, newDev);
    }

    function acceptDev() external {
        if (msg.sender != pendingDev) revert OnlyPendingDev();
        emit DevTransferred(dev, msg.sender);
        dev = msg.sender;
        pendingDev = address(0);
    }

    function setDevFeeReceiver(address newReceiver) external {
        if (msg.sender != dev) revert OnlyDev();
        if (newReceiver == address(0)) revert InvalidDevFeeReceiver();
        emit DevFeeReceiverChanged(devFeeReceiver, newReceiver);
        devFeeReceiver = newReceiver;
    }

    function reserve() public view returns (uint256) {
        return BASE_TOKEN.balanceOf(address(this));
    }

    /// @dev Converts native reserve-token units to 18-decimal WAD units for protocol accounting.
    function _baseToWad(uint256 amount) internal view returns (uint256) {
        return Math.mulDiv(amount, WAD, BASE_TOKEN_UNIT);
    }

    /// @dev The reactor's reserve in the representation used by every protocol calculation.
    /// reserve() stays in the token's native units for the ERC-20 interface. fission() is the one
    /// caller that converts the balance itself, because it also needs the native value as the
    /// baseline for measuring the incoming deposit.
    function _normalizedReserve() internal view returns (uint256) {
        return _baseToWad(reserve());
    }

    function initialFission(uint256 amountIn) external nonReentrant {
        if (msg.sender != FACTORY) revert OnlyFactory();
        if (NEUTRON_TOKEN.totalSupply() != 0 || PROTON_TOKEN.totalSupply() != 0) revert AlreadyInitialized();
        if (amountIn == 0) revert InvalidInitialReserve();

        uint256 basePrice = _readAndCacheBasePrice();
        (uint256 neutronOut, uint256 protonOut) =
            fissionAux(amountIn, address(this), INITIAL_RESERVE_RATIO, 0, basePrice);

        if (neutronOut == 0 || protonOut == 0) revert InvalidInitialReserve();

        uint256 initialReserveRatio = _reserveRatioWad(_normalizedReserve(), neutronOut, basePrice);
        if (initialReserveRatio < CRITICAL_RESERVE_RATIO || initialReserveRatio > UPPER_RESERVE_RATIO) {
            revert InvalidInitialReserve();
        }
    }

    /// @dev Base/PeggedAsset price (WAD), falling back to the cached price when the oracle reverts.
    /// A view cannot persist a price, so only _readAndCacheBasePrice() refreshes the cache.
    function getBasePriceInPeggedAsset() public view returns (uint256) {
        try ORACLE.readValue() returns (uint256 basePrice) {
            return basePrice;
        } catch {
            return lastSuccessfulBasePrice;
        }
    }

    /// @dev Same read, but persists the price so the reactor keeps operating if the oracle later
    /// reverts. The write survives only if the calling operation completes. A zero price is
    /// returned as read but never cached: adjustPeg() and the transmutations return normally at a
    /// zero price, so caching it would persist and leave no usable fallback if the oracle then
    /// starts reverting.
    function _readAndCacheBasePrice() internal returns (uint256) {
        try ORACLE.readValue() returns (uint256 basePrice) {
            if (basePrice != 0) {
                lastSuccessfulBasePrice = basePrice;
            }
            return basePrice;
        } catch {
            return lastSuccessfulBasePrice;
        }
    }

    function _normalizedTargetPriceInBase(uint256 basePrice) internal view returns (uint256) {
        if (basePrice == 0) return type(uint256).max;

        uint256 targetPriceBase = Math.mulDiv(PEGGED_ASSET_WAD, WAD, basePrice);
        return Math.mulDiv(targetPriceBase, pegFactor, PEG_FACTOR_SCALE);
    }

    function _reserveRatioWad(uint256 normalizedReserve, uint256 neutronSupplyTokens, uint256 basePrice)
        internal
        view
        returns (uint256)
    {
        if (normalizedReserve == 0) return 0;
        if (neutronSupplyTokens == 0) return type(uint256).max;
        if (basePrice == 0) return 0;

        uint256 adjustedNeutronSupply = Math.mulDiv(neutronSupplyTokens, pegFactor, PEG_FACTOR_SCALE);
        if (adjustedNeutronSupply == 0) return type(uint256).max;

        return Math.mulDiv(normalizedReserve, basePrice, adjustedNeutronSupply);
    }

    function _requireOperatingRange(uint256 reserveRatio) internal view {
        if (reserveRatio < CRITICAL_RESERVE_RATIO || reserveRatio > UPPER_RESERVE_RATIO) {
            revert ReserveRatioOutOfRange(reserveRatio);
        }
    }

    function qWad() public view returns (uint256) {
        uint256 reserveRatio = reserveRatioPeggedAsset();
        if (reserveRatio == 0) return WAD;

        uint256 q = Math.mulDiv(WAD, WAD, reserveRatio);
        return q > WAD ? WAD : q;
    }

    function neutronPriceInBase() public view returns (uint256) {
        uint256 basePrice = getBasePriceInPeggedAsset();
        return _neutronPriceInBase(_normalizedReserve(), NEUTRON_TOKEN.totalSupply(), basePrice);
    }

    function protonPriceInBase() public view returns (uint256) {
        uint256 basePrice = getBasePriceInPeggedAsset();
        uint256 normalizedReserve = _normalizedReserve();
        uint256 neutronSupply = NEUTRON_TOKEN.totalSupply();
        (, uint256 protonPriceBase) =
            _pricesInBase(normalizedReserve, PROTON_TOKEN.totalSupply(), neutronSupply, basePrice);

        return protonPriceBase;
    }

    function neutronPriceInPeggedAsset() external view returns (uint256) {
        uint256 basePrice = getBasePriceInPeggedAsset();
        uint256 neutronBase = _neutronPriceInBase(_normalizedReserve(), NEUTRON_TOKEN.totalSupply(), basePrice);
        return Math.mulDiv(neutronBase, basePrice, WAD);
    }

    function protonPriceInPeggedAsset() external view returns (uint256) {
        uint256 basePrice = getBasePriceInPeggedAsset();
        uint256 normalizedReserve = _normalizedReserve();
        uint256 neutronSupply = NEUTRON_TOKEN.totalSupply();
        (, uint256 protonBase) = _pricesInBase(normalizedReserve, PROTON_TOKEN.totalSupply(), neutronSupply, basePrice);

        return Math.mulDiv(protonBase, basePrice, WAD);
    }

    function reserveRatioPeggedAsset() public view returns (uint256) {
        uint256 normalizedReserve = _normalizedReserve();
        uint256 neutronSupplyTotal = NEUTRON_TOKEN.totalSupply();

        if (normalizedReserve == 0) return 0;
        if (neutronSupplyTotal == 0) return type(uint256).max;

        return _reserveRatioWad(normalizedReserve, neutronSupplyTotal, getBasePriceInPeggedAsset());
    }

    function adjustPeg() external {
        uint256 normalizedReserve = _normalizedReserve();
        uint256 neutronSupplyTotal = NEUTRON_TOKEN.totalSupply();

        uint256 basePrice = _readAndCacheBasePrice();
        if (basePrice == 0) return;

        uint256 reserveRatio = _reserveRatioWad(normalizedReserve, neutronSupplyTotal, basePrice);
        uint256 previousPegFactor = pegFactor;

        if (reserveRatio < CRITICAL_RESERVE_RATIO) {
            pegFactor = Math.max(1, Math.mulDiv(previousPegFactor, PEG_DOWN_FACTOR_WAD, WAD));
        } else if (reserveRatio > UPPER_RESERVE_RATIO) {
            pegFactor = Math.mulDiv(previousPegFactor, PEG_UP_FACTOR_WAD, WAD, Math.Rounding.Ceil);
        } else {
            revert PegAdjustmentNotNeeded();
        }

        emit PegAdjusted(previousPegFactor, pegFactor, reserveRatio);
    }

    function fission(uint256 amountIn, address to) external nonReentrant {
        if (amountIn == 0) revert AmountZero();

        // Read natively rather than through _normalizedReserve(): this balance is both the ratio input
        // and the baseline fissionAux measures the incoming deposit against, and reading it
        // twice would mean two balanceOf calls.
        uint256 reserveBaseline = reserve();
        uint256 neutronSupplyBefore = NEUTRON_TOKEN.totalSupply();
        uint256 basePrice = _readAndCacheBasePrice();

        uint256 reserveRatio = _reserveRatioWad(_baseToWad(reserveBaseline), neutronSupplyBefore, basePrice);
        _requireOperatingRange(reserveRatio);

        fissionAux(amountIn, to, reserveRatio, reserveBaseline, basePrice);
    }

    function fissionAux(uint256 amountIn, address to, uint256 reserveRatio, uint256 reserveBaseline, uint256 basePrice)
        internal
        returns (uint256 neutronOut, uint256 protonOut)
    {
        uint256 protonSupplyBefore = PROTON_TOKEN.totalSupply();

        // adjustPeg() is not nonReentrant, so a hook-bearing base token could change pegFactor
        // during the transfer below. Keep the mint calculation on one pre-transfer pegFactor snapshot.
        uint256 pegFactorBefore = pegFactor;
        uint256 neutronPriceBase;
        if (protonSupplyBefore == 0) {
            neutronPriceBase = _normalizedTargetPriceInBase(basePrice);
        }

        // ERC-20 boundary. reserveBaseline, received and fee are in the token's native units:
        // the deposit is measured against a live balance; only the separate dev fee is transferred.
        BASE_TOKEN.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = reserve() - reserveBaseline;

        (uint256 netAmount, uint256 fee, uint256 devFeeAmount) = _deductFees(received, FISSION_FEE);
        if (devFeeAmount > 0) BASE_TOKEN.safeTransfer(devFeeReceiver, devFeeAmount);

        // Accounting boundary. Every reserve amount below is in the protocol representation;
        // The event reports received funds, retained protocol fees and dev fees in native units.
        uint256 net = _baseToWad(netAmount);
        uint256 reserveBefore = _baseToWad(reserveBaseline);

        uint256 adjustedBasePrice = Math.mulDiv(basePrice, PEG_FACTOR_SCALE, pegFactorBefore);
        neutronOut = Math.mulDiv(net, adjustedBasePrice, reserveRatio);

        if (protonSupplyBefore == 0) {
            uint256 neutronLiability = Math.mulDiv(neutronOut, neutronPriceBase, WAD);
            protonOut = net - neutronLiability;
        } else {
            protonOut = Math.mulDiv(net, protonSupplyBefore, reserveBefore);
        }

        if (neutronOut == 0 && protonOut == 0) revert AmountTooSmall();

        NEUTRON_TOKEN.mint(to, neutronOut);
        PROTON_TOKEN.mint(to, protonOut);

        emit Fission(msg.sender, to, received, neutronOut, protonOut, fee, devFeeAmount);
    }

    function fusion(uint256 m, address to) external nonReentrant {
        if (m == 0) revert AmountZero();
        // Entry boundary: the reserve and the requested amount are converted once, here.
        // The payout and dev fee leave in native units; the fusion fee stays in the reserve.
        uint256 normalizedReserve = _normalizedReserve();
        if (normalizedReserve == 0) revert EmptyReserve();

        uint256 baseOut = _baseToWad(m);

        uint256 neutronSupplyTotal = NEUTRON_TOKEN.totalSupply();
        uint256 protonSupplyTotal = PROTON_TOKEN.totalSupply();
        if (neutronSupplyTotal == 0 || protonSupplyTotal == 0) revert EmptySupply();

        uint256 basePrice = _readAndCacheBasePrice();
        uint256 reserveRatio = _reserveRatioWad(normalizedReserve, neutronSupplyTotal, basePrice);
        _requireOperatingRange(reserveRatio);

        uint256 nBurn = Math.mulDiv(baseOut, neutronSupplyTotal, normalizedReserve);
        uint256 pBurn = Math.mulDiv(baseOut, protonSupplyTotal, normalizedReserve);
        if (nBurn == 0 || pBurn == 0) revert AmountTooSmall();

        NEUTRON_TOKEN.burn(msg.sender, nBurn);
        PROTON_TOKEN.burn(msg.sender, pBurn);

        (uint256 net, uint256 fee, uint256 devFeeAmount) = _deductFees(m, FUSION_FEE);

        BASE_TOKEN.safeTransfer(to, net);
        if (devFeeAmount > 0) BASE_TOKEN.safeTransfer(devFeeReceiver, devFeeAmount);
        emit Fusion(msg.sender, to, nBurn, pBurn, net, fee, devFeeAmount);
    }

    // Both fees use the same gross amount. The protocol fee stays in the reserve.
    function _deductFees(uint256 amount, uint256 feeWad)
        internal
        view
        returns (uint256 net, uint256 feeAmount, uint256 devFeeAmount)
    {
        feeAmount = Math.mulDiv(amount, feeWad, WAD);
        devFeeAmount = Math.mulDiv(amount, devFee, WAD);
        net = amount - feeAmount - devFeeAmount;
    }

    function _rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        // Exponent parity check for binary exponentiation; this is not randomness.
        // slither-disable-next-line weak-prng
        z = (n % 2 != 0) ? x : WAD;
        for (n /= 2; n != 0; n /= 2) {
            x = Math.mulDiv(x, x, WAD);
            // Exponent parity check for binary exponentiation; this is not randomness.
            // slither-disable-next-line weak-prng
            if (n % 2 != 0) z = Math.mulDiv(z, x, WAD);
        }
    }

    function _decayLedger() internal {
        uint256 t = block.timestamp;
        uint256 dt = t - lastDecayTs;
        if (dt == 0) return;
        if (decayPerSecondWad == WAD) {
            // no decay
            lastDecayTs = t;
            return;
        }
        uint256 d = _rpow(decayPerSecondWad, dt);
        decayedVolumePlusBase = Math.mulDiv(decayedVolumePlusBase, d, WAD);
        decayedVolumeMinusBase = Math.mulDiv(decayedVolumeMinusBase, d, WAD);
        lastDecayTs = t;
    }

    function _betaPlusFeeWad(uint256 normalizedReserve) internal view returns (uint256) {
        uint256 volume =
            decayedVolumePlusBase > decayedVolumeMinusBase ? decayedVolumePlusBase - decayedVolumeMinusBase : 0;
        return _betaFeeWad(normalizedReserve, volume);
    }

    function _betaMinusFeeWad(uint256 normalizedReserve) internal view returns (uint256) {
        uint256 volume =
            decayedVolumeMinusBase > decayedVolumePlusBase ? decayedVolumeMinusBase - decayedVolumePlusBase : 0;
        return _betaFeeWad(normalizedReserve, volume);
    }

    function _betaFeeWad(uint256 normalizedReserve, uint256 volume) internal view returns (uint256) {
        // Above reserve * WAD, any nonzero betaPhi1 already gives a capped fee.
        uint256 boundedVolume = Math.min(volume, Math.saturatingMul(normalizedReserve, WAD));
        uint256 volumeFee = normalizedReserve == 0 ? 0 : Math.mulDiv(betaPhi1, boundedVolume, normalizedReserve);
        return Math.min(betaPhi0 + volumeFee, WAD);
    }

    function transmuteProtonToNeutron(uint256 protonIn, uint256 minNeutronOut, address to)
        external
        nonReentrant
        returns (uint256 neutronOut, uint256 feeWad)
    {
        if (protonIn == 0) revert AmountZero();
        uint256 normalizedReserve = _normalizedReserve();
        uint256 protonSupplyCached = PROTON_TOKEN.totalSupply();
        uint256 neutronSupplyCached = NEUTRON_TOKEN.totalSupply();

        uint256 basePrice = _readAndCacheBasePrice();
        if (basePrice == 0) {
            if (minNeutronOut != 0) revert AmountTooSmall();
            return (0, 0);
        }

        uint256 reserveRatio = _reserveRatioWad(normalizedReserve, neutronSupplyCached, basePrice);
        _requireOperatingRange(reserveRatio);

        (uint256 neutronPriceBase, uint256 protonPriceBase) =
            _pricesInBase(normalizedReserve, protonSupplyCached, neutronSupplyCached, basePrice);

        if (protonPriceBase == 0 || neutronPriceBase == 0) {
            if (minNeutronOut != 0) revert AmountTooSmall();
            return (0, 0);
        }

        uint256 grossBase = Math.mulDiv(protonIn, protonPriceBase, WAD);
        _decayLedger();
        feeWad = _betaPlusFeeWad(normalizedReserve);
        (uint256 netBase,, uint256 devFeeBaseWad) = _deductFees(grossBase, feeWad);
        uint256 devFeeAmount = Math.mulDiv(devFeeBaseWad, BASE_TOKEN_UNIT, WAD);

        neutronOut = Math.mulDiv(netBase, WAD, neutronPriceBase);
        if (neutronOut == 0 || neutronOut < minNeutronOut) revert AmountTooSmall();

        if (devFeeAmount > 0) BASE_TOKEN.safeTransfer(devFeeReceiver, devFeeAmount);
        uint256 resultingNeutronSupply = neutronSupplyCached + neutronOut;
        uint256 resultingReserveRatio = _reserveRatioWad(_normalizedReserve(), resultingNeutronSupply, basePrice);
        if (resultingReserveRatio < CRITICAL_RESERVE_RATIO) {
            revert ResultingReserveRatioBelowCritical();
        }

        uint256 newVolume = decayedVolumePlusBase + grossBase;

        PROTON_TOKEN.burn(msg.sender, protonIn);
        NEUTRON_TOKEN.mint(to, neutronOut);

        decayedVolumePlusBase = newVolume;

        emit TransmutePlus(
            msg.sender, to, protonIn, neutronOut, feeWad, newVolume, decayedVolumeMinusBase, devFeeAmount
        );
    }

    /**
     * β- : convert NEUTRON_TOKEN -> PROTON_TOKEN
     */

    function transmuteNeutronToProton(uint256 neutronIn, uint256 minProtonOut, address to)
        external
        nonReentrant
        returns (uint256 protonOut, uint256 feeWad)
    {
        if (neutronIn == 0) revert AmountZero();

        uint256 normalizedReserve = _normalizedReserve();
        uint256 protonSupplyCached = PROTON_TOKEN.totalSupply();
        uint256 neutronSupplyCached = NEUTRON_TOKEN.totalSupply();

        uint256 basePrice = _readAndCacheBasePrice();
        if (basePrice == 0) {
            if (minProtonOut != 0) revert AmountTooSmall();
            return (0, 0);
        }

        uint256 reserveRatio = _reserveRatioWad(normalizedReserve, neutronSupplyCached, basePrice);
        _requireOperatingRange(reserveRatio);

        (uint256 neutronPriceBase, uint256 protonPriceBase) =
            _pricesInBase(normalizedReserve, protonSupplyCached, neutronSupplyCached, basePrice);

        if (protonPriceBase == 0 || neutronPriceBase == 0) {
            if (minProtonOut != 0) revert AmountTooSmall();
            return (0, 0);
        }

        uint256 grossBase = Math.mulDiv(neutronIn, neutronPriceBase, WAD);

        _decayLedger();
        feeWad = _betaMinusFeeWad(normalizedReserve);
        (uint256 netBase,, uint256 devFeeBaseWad) = _deductFees(grossBase, feeWad);
        uint256 devFeeAmount = Math.mulDiv(devFeeBaseWad, BASE_TOKEN_UNIT, WAD);

        protonOut = Math.mulDiv(netBase, WAD, protonPriceBase);
        if (protonOut == 0 || protonOut < minProtonOut) revert AmountTooSmall();

        uint256 newVolume = decayedVolumeMinusBase + grossBase;

        NEUTRON_TOKEN.burn(msg.sender, neutronIn);
        PROTON_TOKEN.mint(to, protonOut);
        decayedVolumeMinusBase = newVolume;
        if (devFeeAmount > 0) BASE_TOKEN.safeTransfer(devFeeReceiver, devFeeAmount);

        emit TransmuteMinus(
            msg.sender, to, neutronIn, protonOut, feeWad, decayedVolumePlusBase, newVolume, devFeeAmount
        );
    }

    function _neutronPriceInBase(uint256 normalizedReserve, uint256 neutronSupplyTokens, uint256 basePrice)
        internal
        view
        returns (uint256)
    {
        if (normalizedReserve == 0) return 0;
        if (neutronSupplyTokens == 0) return _normalizedTargetPriceInBase(basePrice);

        uint256 targetPriceBase = _normalizedTargetPriceInBase(basePrice);
        uint256 reservePerNeutron = Math.mulDiv(normalizedReserve, WAD, neutronSupplyTokens);

        return targetPriceBase < reservePerNeutron ? targetPriceBase : reservePerNeutron;
    }

    function _pricesInBase(
        uint256 normalizedReserve,
        uint256 protonSupplyTokens,
        uint256 neutronSupplyTokens,
        uint256 basePrice
    ) internal view returns (uint256 neutronPriceBase, uint256 protonPriceBase) {
        neutronPriceBase = _neutronPriceInBase(normalizedReserve, neutronSupplyTokens, basePrice);
        protonPriceBase =
            _protonPriceInBase(normalizedReserve, protonSupplyTokens, neutronSupplyTokens, neutronPriceBase);
    }

    function _protonPriceInBase(
        uint256 normalizedReserve,
        uint256 protonSupplyTokens,
        uint256 neutronSupplyTokens,
        uint256 neutronPriceBase
    ) internal pure returns (uint256) {
        if (protonSupplyTokens == 0) return WAD;
        if (normalizedReserve == 0) return 0;

        uint256 liabilities = Math.mulDiv(neutronSupplyTokens, neutronPriceBase, WAD);
        uint256 equity = normalizedReserve - liabilities;

        return Math.mulDiv(equity, WAD, protonSupplyTokens);
    }
}
