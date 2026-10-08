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
    uint256 public constant ALPHA_DOWN_FACTOR = 99e16;
    uint256 public constant ALPHA_UP_FACTOR = 101e16;

    error InvalidBaseToken();
    error InvalidBaseTokenDecimals(uint8 decimals);
    error InvalidOracle();
    error OracleNotContract();
    error InvalidTreasury();
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
    error OnlyTreasury();
    error InvalidPhi();
    error InvalidDecay();
    error AmountZero();
    error AmountTooSmall();
    error EmptyReserve();
    error EmptySupply();
    error MathOverflow();
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
    address public immutable TREASURY;
    uint256 public immutable FISSION_FEE;
    uint256 public immutable FUSION_FEE;
    uint256 public immutable CRITICAL_RESERVE_RATIO;

    uint256 public alpha = WAD;

    // β fee parameters
    uint256 public betaPhi0;
    uint256 public betaPhi1;
    uint256 public decayPerSecondWad;
    int256 private decayedVolumeBase;
    uint256 private lastDecayTs;

    event Fission(
        address indexed from,
        address indexed to,
        uint256 baseIn,
        uint256 neutronOut,
        uint256 protonOut,
        uint256 feeToTreasury
    );
    event Fusion(
        address indexed from,
        address indexed to,
        uint256 neutronBurn,
        uint256 protonBurn,
        uint256 baseOut,
        uint256 feeToTreasury
    );
    event TransmutePlus(
        address indexed from,
        address indexed to,
        uint256 protonIn,
        uint256 neutronOut,
        uint256 feeWad,
        int256 newDecayedVolumeBase
    );
    event TransmuteMinus(
        address indexed from,
        address indexed to,
        uint256 neutronIn,
        uint256 protonOut,
        uint256 feeWad,
        int256 newDecayedVolumeBase
    );
    event BetaParamsSet(uint256 phi0, uint256 phi1, uint256 decayPerSecondWad);
    event PegAdjusted(uint256 previousAlpha, uint256 newAlpha, uint256 reserveRatio);

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
        address treasuryParam,
        uint256 fissionFeeParam,
        uint256 fusionFeeParam,
        uint256 criticalReserveRatioWadParam
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
        if (treasuryParam == address(0)) revert InvalidTreasury();
        if (fissionFeeParam >= WAD) revert InvalidFissionFee();
        if (fusionFeeParam >= WAD) revert InvalidFusionFee();
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

        TREASURY = treasuryParam;
        FISSION_FEE = fissionFeeParam;
        FUSION_FEE = fusionFeeParam;

        // default β-params: no fee, no decay (can be set later by TREASURY)
        betaPhi0 = 0;
        betaPhi1 = 0;
        decayPerSecondWad = WAD; // no decay
        lastDecayTs = block.timestamp;
    }

    modifier onlyTreasury() {
        if (msg.sender != TREASURY) revert OnlyTreasury();
        _;
    }

    function setBetaParams(uint256 phi0, uint256 phi1, uint256 decayPerSecondWadParam) external onlyTreasury {
        if (phi0 > WAD || phi1 > WAD) revert InvalidPhi();
        if (decayPerSecondWadParam > WAD) revert InvalidDecay();
        betaPhi0 = phi0;
        betaPhi1 = phi1;
        decayPerSecondWad = decayPerSecondWadParam;
        emit BetaParamsSet(phi0, phi1, decayPerSecondWadParam);
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
        return Math.mulDiv(targetPriceBase, alpha, WAD);
    }

    function _reserveRatioWad(uint256 normalizedReserve, uint256 neutronSupplyTokens, uint256 basePrice)
        internal
        view
        returns (uint256)
    {
        if (normalizedReserve == 0) return 0;
        if (neutronSupplyTokens == 0) return type(uint256).max;
        if (basePrice == 0) return 0;

        uint256 adjustedNeutronSupply = Math.mulDiv(neutronSupplyTokens, alpha, WAD);
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
        uint256 previousAlpha = alpha;

        if (reserveRatio < CRITICAL_RESERVE_RATIO) {
            alpha = Math.mulDiv(previousAlpha, ALPHA_DOWN_FACTOR, WAD);
        } else if (reserveRatio > UPPER_RESERVE_RATIO) {
            alpha = Math.mulDiv(previousAlpha, ALPHA_UP_FACTOR, WAD);
        } else {
            revert PegAdjustmentNotNeeded();
        }

        emit PegAdjusted(previousAlpha, alpha, reserveRatio);
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

        // adjustPeg() is not nonReentrant, so a hook-bearing base token could change alpha
        // during the transfer below. Keep the mint calculation on one pre-transfer alpha snapshot.
        uint256 alphaBefore = alpha;
        uint256 neutronPriceBase;
        if (protonSupplyBefore == 0) {
            neutronPriceBase = _normalizedTargetPriceInBase(basePrice);
        }

        // ERC-20 boundary. reserveBaseline, received and fee are in the token's native units:
        // the deposit is measured against a live balance and the fee leaves as a transfer.
        BASE_TOKEN.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = reserve() - reserveBaseline;

        uint256 fee = Math.mulDiv(received, FISSION_FEE, WAD);
        if (fee > 0) BASE_TOKEN.safeTransfer(TREASURY, fee);

        // Accounting boundary. Every reserve amount below is in the protocol representation;
        // received and fee are only touched again by the event, which reports native amounts.
        uint256 net = _baseToWad(received - fee);
        if (net == 0) revert AmountTooSmall();
        uint256 reserveBefore = _baseToWad(reserveBaseline);

        uint256 adjustedBasePrice = Math.mulDiv(basePrice, WAD, alphaBefore);
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

        emit Fission(msg.sender, to, received, neutronOut, protonOut, fee);
    }

    /// @notice Returns the Neutron and Proton amounts required to redeem `m`
    /// base-token units through fusion.
    /// @param m Base-token amount in the base token's native units.
    function fusionBurnAmounts(uint256 m) external view returns (uint256 nBurn, uint256 pBurn) {
        if (m == 0) revert AmountZero();

        uint256 normalizedReserve = _normalizedReserve();
        if (normalizedReserve == 0) revert EmptyReserve();

        uint256 neutronSupplyTotal = NEUTRON_TOKEN.totalSupply();
        uint256 protonSupplyTotal = PROTON_TOKEN.totalSupply();
        if (neutronSupplyTotal == 0 || protonSupplyTotal == 0) revert EmptySupply();

        uint256 basePrice = getBasePriceInPeggedAsset();
        uint256 reserveRatio = _reserveRatioWad(normalizedReserve, neutronSupplyTotal, basePrice);
        _requireOperatingRange(reserveRatio);

        uint256 baseOut = _baseToWad(m);

        return _fusionBurnAmounts(baseOut, normalizedReserve, neutronSupplyTotal, protonSupplyTotal);
    }

    function _fusionBurnAmounts(
        uint256 baseOut,
        uint256 normalizedReserve,
        uint256 neutronSupplyTotal,
        uint256 protonSupplyTotal
    ) internal pure returns (uint256 nBurn, uint256 pBurn) {
        nBurn = Math.mulDiv(baseOut, neutronSupplyTotal, normalizedReserve);
        pBurn = Math.mulDiv(baseOut, protonSupplyTotal, normalizedReserve);

        if (nBurn == 0 || pBurn == 0) revert AmountTooSmall();
    }

    function fusion(uint256 m, address to) external nonReentrant {
        if (m == 0) revert AmountZero();
        // Entry boundary: the reserve and the requested amount are converted once, here.
        // The payout and fee below leave in the token's native units.
        uint256 normalizedReserve = _normalizedReserve();
        if (normalizedReserve == 0) revert EmptyReserve();

        uint256 baseOut = _baseToWad(m);

        uint256 neutronSupplyTotal = NEUTRON_TOKEN.totalSupply();
        uint256 protonSupplyTotal = PROTON_TOKEN.totalSupply();
        if (neutronSupplyTotal == 0 || protonSupplyTotal == 0) revert EmptySupply();

        uint256 basePrice = _readAndCacheBasePrice();
        uint256 reserveRatio = _reserveRatioWad(normalizedReserve, neutronSupplyTotal, basePrice);
        _requireOperatingRange(reserveRatio);

        (uint256 nBurn, uint256 pBurn) =
            _fusionBurnAmounts(baseOut, normalizedReserve, neutronSupplyTotal, protonSupplyTotal);

        NEUTRON_TOKEN.burn(msg.sender, nBurn);
        PROTON_TOKEN.burn(msg.sender, pBurn);

        uint256 fee = Math.mulDiv(m, FUSION_FEE, WAD);
        uint256 net = m - fee;

        BASE_TOKEN.safeTransfer(to, net);
        if (fee > 0) BASE_TOKEN.safeTransfer(TREASURY, fee);
        emit Fusion(msg.sender, to, nBurn, pBurn, net, fee);
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
        if (decayedVolumeBase != 0) {
            int256 v = decayedVolumeBase;
            if (v > 0) {
                // v > 0 and d <= WAD, so the converted result remains within int256 range.
                // forge-lint: disable-next-line(unsafe-typecast)
                decayedVolumeBase = int256(Math.mulDiv(uint256(v), d, WAD));
            } else {
                // v < 0 here; Solidity's checked -v preserves the existing overflow protection.
                // forge-lint: disable-next-line(unsafe-typecast)
                decayedVolumeBase = -int256(Math.mulDiv(uint256(-v), d, WAD));
            }
        }
        lastDecayTs = t;
    }

    function _betaPlusFeeWad(uint256 normalizedReserve) internal view returns (uint256) {
        if (normalizedReserve == 0) return WAD;
        if (betaPhi0 == 0 && betaPhi1 == 0) return 0;
        int256 v = decayedVolumeBase;
        // The conversion is evaluated only when v > 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 pos = v > 0 ? uint256(v) : 0;
        uint256 term = Math.mulDiv(betaPhi1, pos, normalizedReserve);
        uint256 f = betaPhi0 + term;
        return f > WAD ? WAD : f;
    }

    function _betaMinusFeeWad(uint256 normalizedReserve) internal view returns (uint256) {
        if (normalizedReserve == 0) return WAD;
        if (betaPhi0 == 0 && betaPhi1 == 0) return 0;
        int256 v = decayedVolumeBase;
        // The conversion is evaluated only when v < 0; checked -v preserves overflow protection.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 neg = v < 0 ? uint256(-v) : 0;
        uint256 term = Math.mulDiv(betaPhi1, neg, normalizedReserve);
        uint256 f = betaPhi0 + term;
        return f > WAD ? WAD : f;
    }

    function transmuteProtonToNeutron(uint256 protonIn, address to)
        external
        nonReentrant
        returns (uint256 neutronOut, uint256 feeWad)
    {
        if (protonIn == 0) revert AmountZero();
        uint256 normalizedReserve = _normalizedReserve();
        uint256 protonSupplyCached = PROTON_TOKEN.totalSupply();
        uint256 neutronSupplyCached = NEUTRON_TOKEN.totalSupply();

        uint256 basePrice = _readAndCacheBasePrice();
        if (basePrice == 0) return (0, 0);

        uint256 reserveRatio = _reserveRatioWad(normalizedReserve, neutronSupplyCached, basePrice);
        _requireOperatingRange(reserveRatio);

        (uint256 neutronPriceBase, uint256 protonPriceBase) =
            _pricesInBase(normalizedReserve, protonSupplyCached, neutronSupplyCached, basePrice);

        if (protonPriceBase == 0 || neutronPriceBase == 0) return (0, 0);

        uint256 grossBase = Math.mulDiv(protonIn, protonPriceBase, WAD);
        _decayLedger();
        feeWad = _betaPlusFeeWad(normalizedReserve);
        uint256 netBase = Math.mulDiv(grossBase, (WAD - feeWad), WAD);

        neutronOut = Math.mulDiv(netBase, WAD, neutronPriceBase);
        if (neutronOut == 0) revert AmountTooSmall();

        uint256 resultingNeutronSupply = neutronSupplyCached + neutronOut;
        uint256 resultingReserveRatio = _reserveRatioWad(normalizedReserve, resultingNeutronSupply, basePrice);
        if (resultingReserveRatio < CRITICAL_RESERVE_RATIO) {
            revert ResultingReserveRatioBelowCritical();
        }

        PROTON_TOKEN.burn(msg.sender, protonIn);
        NEUTRON_TOKEN.mint(to, neutronOut);

        decayedVolumeBase += _grossBaseToInt(grossBase);

        emit TransmutePlus(msg.sender, to, protonIn, neutronOut, feeWad, decayedVolumeBase);
    }

    /**
     * β- : convert NEUTRON_TOKEN -> PROTON_TOKEN
     */

    function transmuteNeutronToProton(uint256 neutronIn, address to)
        external
        nonReentrant
        returns (uint256 protonOut, uint256 feeWad)
    {
        if (neutronIn == 0) revert AmountZero();

        uint256 normalizedReserve = _normalizedReserve();
        uint256 protonSupplyCached = PROTON_TOKEN.totalSupply();
        uint256 neutronSupplyCached = NEUTRON_TOKEN.totalSupply();

        uint256 basePrice = _readAndCacheBasePrice();
        if (basePrice == 0) return (0, 0);

        uint256 reserveRatio = _reserveRatioWad(normalizedReserve, neutronSupplyCached, basePrice);
        _requireOperatingRange(reserveRatio);

        (uint256 neutronPriceBase, uint256 protonPriceBase) =
            _pricesInBase(normalizedReserve, protonSupplyCached, neutronSupplyCached, basePrice);

        if (protonPriceBase == 0 || neutronPriceBase == 0) return (0, 0);

        uint256 grossBase = Math.mulDiv(neutronIn, neutronPriceBase, WAD);

        _decayLedger();
        feeWad = _betaMinusFeeWad(normalizedReserve);
        uint256 netBase = Math.mulDiv(grossBase, (WAD - feeWad), WAD);

        protonOut = Math.mulDiv(netBase, WAD, protonPriceBase);
        if (protonOut == 0) revert AmountTooSmall();

        NEUTRON_TOKEN.burn(msg.sender, neutronIn);
        PROTON_TOKEN.mint(to, protonOut);
        decayedVolumeBase -= _grossBaseToInt(grossBase);

        emit TransmuteMinus(msg.sender, to, neutronIn, protonOut, feeWad, decayedVolumeBase);
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

    function _grossBaseToInt(uint256 value) internal pure returns (int256) {
        if (value > uint256(type(int256).max)) revert MathOverflow();
        // The explicit bound check guarantees value fits in int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(value);
    }
}
