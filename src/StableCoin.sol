// SPDX-License-Identifier: AEL
pragma solidity ^0.8.20;

import {Tokeon} from "./tokens/Tokeon.sol";
import {IPyth, Price} from "./interfaces/IPyth.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract StableCoinReactor is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public constant WAD = 1e18;
    uint256 public constant PEGGED_ASSET_WAD = 1e18; // peg target
    uint256 public constant MAXIMUM_AGE = 60; // oracle max staleness in seconds
    uint32 private constant MAX_PRICE_EXP = 38;

    // Tokens
    Tokeon public immutable NEUTRON_TOKEN; // stable token (peg)
    Tokeon public immutable PROTON_TOKEN; // volatile token
    IERC20 public immutable BASE_TOKEN; // reserve asset (ERC20)

    // Metadata
    string public vaultName;
    string public baseAssetName;
    string public baseAssetSymbol;
    string public peggedAssetName;
    string public peggedAssetSymbol;

    IPyth public immutable PYTH_ORACLE;
    bytes32 public immutable PRICE_ID;

    address public immutable TREASURY;
    uint256 public immutable FISSION_FEE;
    uint256 public immutable FUSION_FEE;
    uint256 public immutable CRITICAL_RESERVE_RATIO;

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
    event PriceUpdated(bytes32 indexed priceId, int64 price, uint256 timestamp);
    event TransmutePlus( // β+
        address indexed from,
        address indexed to,
        uint256 protonIn,
        uint256 neutronOut,
        uint256 feeWad,
        int256 newDecayedVolumeBase
    );
    event TransmuteMinus( // β-
        address indexed from,
        address indexed to,
        uint256 neutronIn,
        uint256 protonOut,
        uint256 feeWad,
        int256 newDecayedVolumeBase
    );
    event BetaParamsSet(uint256 phi0, uint256 phi1, uint256 decayPerSecondWad);

    constructor(
        string memory vaultNameParam,
        string memory baseAssetNameParam,
        string memory baseAssetSymbolParam,
        string memory peggedAssetNameParam,
        string memory peggedAssetSymbolParam,
        address baseTokenParam,
        address pythOracleParam,
        bytes32 priceIdParam,
        string memory protonNameParam,
        string memory protonSymbolParam,
        address treasuryParam,
        uint256 fissionFeeParam,
        uint256 fusionFeeParam,
        uint256 criticalReserveRatioWadParam
    ) {
        require(baseTokenParam != address(0), "Invalid base token");
        require(pythOracleParam != address(0), "Invalid Pyth");
        require(treasuryParam != address(0), "Invalid treasury");
        require(fissionFeeParam < WAD, "fission fee >= 100%");
        require(fusionFeeParam < WAD, "fusion fee >= 100%");
        require(criticalReserveRatioWadParam >= WAD, "critical ratio < 100%");
        require(bytes(vaultNameParam).length > 0, "Empty vault name");
        require(bytes(baseAssetNameParam).length > 0, "Empty base name");
        require(bytes(baseAssetSymbolParam).length > 0, "Empty base symbol");
        require(bytes(peggedAssetNameParam).length > 0, "Empty peg name");
        require(bytes(peggedAssetSymbolParam).length > 0, "Empty peg symbol");
        require(bytes(protonNameParam).length > 0, "Empty proton name");
        require(bytes(protonSymbolParam).length > 0, "Empty proton symbol");

        vaultName = vaultNameParam;
        baseAssetName = baseAssetNameParam;
        baseAssetSymbol = baseAssetSymbolParam;
        peggedAssetName = peggedAssetNameParam;
        peggedAssetSymbol = peggedAssetSymbolParam;

        BASE_TOKEN = IERC20(baseTokenParam);
        PYTH_ORACLE = IPyth(pythOracleParam);
        PRICE_ID = priceIdParam;
        CRITICAL_RESERVE_RATIO = criticalReserveRatioWadParam;

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
        require(msg.sender == TREASURY, "only treasury");
        _;
    }

    function setBetaParams(uint256 phi0, uint256 phi1, uint256 decayPerSecondWadParam) external onlyTreasury {
        require(phi0 <= WAD && phi1 <= WAD, "phi > 1");
        require(decayPerSecondWadParam <= WAD, "decay > 1");
        betaPhi0 = phi0;
        betaPhi1 = phi1;
        decayPerSecondWad = decayPerSecondWadParam;
        emit BetaParamsSet(phi0, phi1, decayPerSecondWadParam);
    }

    function reserve() public view returns (uint256) {
        return BASE_TOKEN.balanceOf(address(this));
    }

    /// @dev Base/PeggedAsset price (WAD). Uses "unsafe" read; call updatePriceFeeds externally when needed.
    function getBasePriceInPeggedAsset() public view returns (uint256) {
        Price memory p = PYTH_ORACLE.getPriceUnsafe(PRICE_ID);
        return _pythPriceToWad(p);
    }

    /// @dev Dynamic q as defined in the Solana reference. Returns WAD in [0,1].
    function qWad() public view returns (uint256) {
        uint256 basePrice = getBasePriceInPeggedAsset();
        return _qWadDynamic(reserve(), NEUTRON_TOKEN.totalSupply(), basePrice);
    }

    /// @dev Price of NEUTRON_TOKEN in BASE units (WAD): P° = q * R / S_n
    function neutronPriceInBase() public view returns (uint256) {
        uint256 basePrice = getBasePriceInPeggedAsset();
        return _neutronPriceInBase(reserve(), NEUTRON_TOKEN.totalSupply(), basePrice);
    }

    /// @dev Price of PROTON_TOKEN in BASE units (WAD): P• = (1-q) * R / S_p
    function protonPriceInBase() public view returns (uint256) {
        uint256 basePrice = getBasePriceInPeggedAsset();
        return _protonPriceInBase(reserve(), PROTON_TOKEN.totalSupply(), NEUTRON_TOKEN.totalSupply(), basePrice);
    }

    function neutronPriceInPeggedAsset() external view returns (uint256) {
        uint256 basePrice = getBasePriceInPeggedAsset();
        uint256 neutronBase = _neutronPriceInBase(reserve(), NEUTRON_TOKEN.totalSupply(), basePrice);
        return Math.mulDiv(neutronBase, basePrice, WAD);
    }

    function protonPriceInPeggedAsset() external view returns (uint256) {
        uint256 basePrice = getBasePriceInPeggedAsset();
        uint256 protonBase =
            _protonPriceInBase(reserve(), PROTON_TOKEN.totalSupply(), NEUTRON_TOKEN.totalSupply(), basePrice);
        return Math.mulDiv(protonBase, basePrice, WAD);
    }

    /// @dev Convenience: current reserve ratio vs peg (PeggedAsset): r = (R*Pbase)/(S_n*PEG)
    function reserveRatioPeggedAsset() public view returns (uint256) {
        uint256 reserveBalance = reserve();
        uint256 neutronSupplyTotal = NEUTRON_TOKEN.totalSupply();
        if (reserveBalance == 0) return 0;
        if (neutronSupplyTotal == 0) return type(uint256).max;
        return Math.mulDiv(
            reserveBalance, getBasePriceInPeggedAsset(), Math.mulDiv(neutronSupplyTotal, PEGGED_ASSET_WAD, WAD)
        );
    }

    /// @dev Preview current fission outputs for a given base-token deposit amount.
    function previewFission(uint256 amountIn)
        external
        view
        returns (uint256 neutronOut, uint256 protonOut, uint256 feeAmount, uint256 netBase, bool bootstrap)
    {
        require(amountIn > 0, "amount=0");

        uint256 reserveBefore = reserve();
        uint256 neutronSupplyBefore = NEUTRON_TOKEN.totalSupply();
        uint256 protonSupplyBefore = PROTON_TOKEN.totalSupply();

        feeAmount = Math.mulDiv(amountIn, FISSION_FEE, WAD);
        netBase = amountIn - feeAmount;
        require(netBase > 0, "AmountTooSmall");

        if (reserveBefore == 0 && neutronSupplyBefore == 0 && protonSupplyBefore == 0) {
            bootstrap = true;
            Price memory price = PYTH_ORACLE.getPriceNoOlderThan(PRICE_ID, MAXIMUM_AGE);
            uint256 basePriceWad = _pythPriceToWad(price);
            (neutronOut, protonOut) = _bootstrapFissionOutputs(netBase, basePriceWad);
            return (neutronOut, protonOut, feeAmount, netBase, bootstrap);
        }

        require(reserveBefore > 0, "R=0");
        neutronOut = neutronSupplyBefore == 0 ? 0 : Math.mulDiv(netBase, neutronSupplyBefore, reserveBefore);
        protonOut = protonSupplyBefore == 0 ? 0 : Math.mulDiv(netBase, protonSupplyBefore, reserveBefore);
        require(neutronOut > 0 || protonOut > 0, "AmountTooSmall");
    }

    /// @dev Preview token burns and net base-token out for a given fusion amount.
    function previewFusion(uint256 m)
        external
        view
        returns (uint256 neutronBurn, uint256 protonBurn, uint256 feeAmount, uint256 netBaseOut)
    {
        require(m > 0, "amount=0");
        uint256 reserveBalance = reserve();
        require(reserveBalance > 0, "R=0");

        uint256 neutronSupplyTotal = NEUTRON_TOKEN.totalSupply();
        uint256 protonSupplyTotal = PROTON_TOKEN.totalSupply();
        require(neutronSupplyTotal > 0 && protonSupplyTotal > 0, "empty S");

        neutronBurn = Math.mulDiv(m, neutronSupplyTotal, reserveBalance);
        protonBurn = Math.mulDiv(m, protonSupplyTotal, reserveBalance);
        feeAmount = Math.mulDiv(m, FUSION_FEE, WAD);
        netBaseOut = m - feeAmount;
    }

    /// @dev Preview β+ transmute outputs from PROTON_TOKEN to NEUTRON_TOKEN using the current oracle price.
    function previewTransmuteProtonToNeutron(uint256 protonIn)
        external
        view
        returns (uint256 neutronOut, uint256 feeWad, uint256 grossBase, uint256 netBase)
    {
        require(protonIn > 0, "amount=0");

        uint256 reserveTokens = reserve();
        uint256 protonSupplyCached = PROTON_TOKEN.totalSupply();
        uint256 neutronSupplyCached = NEUTRON_TOKEN.totalSupply();

        Price memory price = PYTH_ORACLE.getPriceNoOlderThan(PRICE_ID, MAXIMUM_AGE);
        uint256 basePrice = _pythPriceToWad(price);

        uint256 protonPriceBase = _protonPriceInBase(reserveTokens, protonSupplyCached, neutronSupplyCached, basePrice);
        uint256 neutronPriceBase = _neutronPriceInBase(reserveTokens, neutronSupplyCached, basePrice);
        require(protonPriceBase > 0 && neutronPriceBase > 0, "bad price");

        grossBase = Math.mulDiv(protonIn, protonPriceBase, WAD);
        feeWad = _previewBetaPlusFeeWad(reserveTokens);
        netBase = Math.mulDiv(grossBase, (WAD - feeWad), WAD);
        neutronOut = Math.mulDiv(netBase, WAD, neutronPriceBase);
    }

    /// @dev Preview β- transmute outputs from NEUTRON_TOKEN to PROTON_TOKEN using the current oracle price.
    function previewTransmuteNeutronToProton(uint256 neutronIn)
        external
        view
        returns (uint256 protonOut, uint256 feeWad, uint256 grossBase, uint256 netBase)
    {
        require(neutronIn > 0, "amount=0");

        uint256 reserveTokens = reserve();
        uint256 protonSupplyCached = PROTON_TOKEN.totalSupply();
        uint256 neutronSupplyCached = NEUTRON_TOKEN.totalSupply();

        Price memory price = PYTH_ORACLE.getPriceNoOlderThan(PRICE_ID, MAXIMUM_AGE);
        uint256 basePrice = _pythPriceToWad(price);

        uint256 protonPriceBase = _protonPriceInBase(reserveTokens, protonSupplyCached, neutronSupplyCached, basePrice);
        uint256 neutronPriceBase = _neutronPriceInBase(reserveTokens, neutronSupplyCached, basePrice);
        require(protonPriceBase > 0 && neutronPriceBase > 0, "bad price");

        grossBase = Math.mulDiv(neutronIn, neutronPriceBase, WAD);
        feeWad = _previewBetaMinusFeeWad(reserveTokens);
        netBase = Math.mulDiv(grossBase, (WAD - feeWad), WAD);
        protonOut = Math.mulDiv(netBase, WAD, protonPriceBase);
    }

    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        // Price feed update passthrough
        uint256 fee = PYTH_ORACLE.getUpdateFee(updateData);
        require(msg.value >= fee, "fee");
        PYTH_ORACLE.updatePriceFeeds{value: fee}(updateData);
        Price memory price = PYTH_ORACLE.getPriceUnsafe(PRICE_ID);
        emit PriceUpdated(PRICE_ID, price.price, price.publishTime);
        if (msg.value > fee) payable(msg.sender).transfer(msg.value - fee);
    }

    /// @dev Implements the Solana fission logic including bootstrap case.
    function fission(uint256 amountIn, address to, bytes[] calldata updateData) external payable nonReentrant {
        require(amountIn > 0, "amount=0");

        uint256 reserveBefore = reserve();
        uint256 neutronSupplyBefore = NEUTRON_TOKEN.totalSupply();
        uint256 protonSupplyBefore = PROTON_TOKEN.totalSupply();

        uint256 pythFee = 0;
        if (updateData.length > 0) {
            pythFee = PYTH_ORACLE.getUpdateFee(updateData);
            require(msg.value >= pythFee, "insufficient oracle fee");
            PYTH_ORACLE.updatePriceFeeds{value: pythFee}(updateData);
        }

        BASE_TOKEN.safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 feeAmount = Math.mulDiv(amountIn, FISSION_FEE, WAD);
        if (feeAmount > 0) {
            BASE_TOKEN.safeTransfer(TREASURY, feeAmount);
        }
        uint256 net = amountIn - feeAmount;
        require(net > 0, "AmountTooSmall");

        uint256 neutronOut;
        uint256 protonOut;
        if (reserveBefore == 0 && neutronSupplyBefore == 0 && protonSupplyBefore == 0) {
            Price memory price = PYTH_ORACLE.getPriceNoOlderThan(PRICE_ID, MAXIMUM_AGE);
            uint256 basePriceWad = _pythPriceToWad(price);
            (neutronOut, protonOut) = _bootstrapFissionOutputs(net, basePriceWad);
        } else {
            require(reserveBefore > 0, "R=0");
            neutronOut = neutronSupplyBefore == 0 ? 0 : Math.mulDiv(net, neutronSupplyBefore, reserveBefore);
            protonOut = protonSupplyBefore == 0 ? 0 : Math.mulDiv(net, protonSupplyBefore, reserveBefore);
        }
        require(neutronOut > 0 || protonOut > 0, "AmountTooSmall");

        NEUTRON_TOKEN.mint(to, neutronOut);
        PROTON_TOKEN.mint(to, protonOut);

        uint256 excess = msg.value > pythFee ? (msg.value - pythFee) : 0;
        if (excess > 0) {
            (bool success,) = msg.sender.call{value: excess}("");
            require(success, "refund failed");
        }

        emit Fission(msg.sender, to, amountIn, neutronOut, protonOut, feeAmount);
    }

    function fusion(uint256 m, address to) external nonReentrant {
        require(m > 0, "amount=0");
        uint256 reserveBalance = reserve();
        require(reserveBalance > 0, "R=0");

        uint256 neutronSupplyTotal = NEUTRON_TOKEN.totalSupply();
        uint256 protonSupplyTotal = PROTON_TOKEN.totalSupply();
        require(neutronSupplyTotal > 0 && protonSupplyTotal > 0, "empty S");

        uint256 nBurn = Math.mulDiv(m, neutronSupplyTotal, reserveBalance);
        uint256 pBurn = Math.mulDiv(m, protonSupplyTotal, reserveBalance);

        NEUTRON_TOKEN.burn(msg.sender, nBurn);
        PROTON_TOKEN.burn(msg.sender, pBurn);

        uint256 fee = Math.mulDiv(m, FUSION_FEE, WAD);
        uint256 net = m - fee;

        BASE_TOKEN.safeTransfer(to, net);
        if (fee > 0) BASE_TOKEN.safeTransfer(TREASURY, fee);

        emit Fusion(msg.sender, to, nBurn, pBurn, net, fee);
    }

    function _rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        z = (n % 2 != 0) ? x : WAD;
        for (n /= 2; n != 0; n /= 2) {
            x = Math.mulDiv(x, x, WAD);
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
        uint256 d = _rpow(decayPerSecondWad, dt); // δ^{dt} (WAD)
        // decayedVolumeBase <- \bar V * δ^{dt}
        if (decayedVolumeBase != 0) {
            int256 v = decayedVolumeBase;
            if (v > 0) {
                decayedVolumeBase = int256(Math.mulDiv(uint256(v), d, WAD));
            } else {
                decayedVolumeBase = -int256(Math.mulDiv(uint256(-v), d, WAD));
            }
        }
        lastDecayTs = t;
    }

    function _betaPlusFeeWad(uint256 reserveTokens) internal view returns (uint256) {
        if (reserveTokens == 0) return WAD; // saturated
        if (betaPhi0 == 0 && betaPhi1 == 0) return 0;
        int256 v = decayedVolumeBase;
        uint256 pos = v > 0 ? uint256(v) : 0;
        uint256 term = Math.mulDiv(betaPhi1, pos, reserveTokens);
        uint256 f = betaPhi0 + term;
        return f > WAD ? WAD : f;
    }

    function _betaMinusFeeWad(uint256 reserveTokens) internal view returns (uint256) {
        if (reserveTokens == 0) return WAD;
        if (betaPhi0 == 0 && betaPhi1 == 0) return 0;
        int256 v = decayedVolumeBase;
        uint256 neg = v < 0 ? uint256(-v) : 0;
        uint256 term = Math.mulDiv(betaPhi1, neg, reserveTokens);
        uint256 f = betaPhi0 + term;
        return f > WAD ? WAD : f;
    }

    function _previewBetaPlusFeeWad(uint256 reserveTokens) internal view returns (uint256) {
        if (reserveTokens == 0) return WAD;
        if (betaPhi0 == 0 && betaPhi1 == 0) return 0;

        int256 v = decayedVolumeBase;
        if (decayPerSecondWad != WAD) {
            uint256 dt = block.timestamp - lastDecayTs;
            if (dt != 0) {
                uint256 d = _rpow(decayPerSecondWad, dt);
                if (v > 0) {
                    v = int256(Math.mulDiv(uint256(v), d, WAD));
                } else if (v < 0) {
                    v = -int256(Math.mulDiv(uint256(-v), d, WAD));
                }
            }
        }

        uint256 pos = v > 0 ? uint256(v) : 0;
        uint256 term = Math.mulDiv(betaPhi1, pos, reserveTokens);
        uint256 f = betaPhi0 + term;
        return f > WAD ? WAD : f;
    }

    function _previewBetaMinusFeeWad(uint256 reserveTokens) internal view returns (uint256) {
        if (reserveTokens == 0) return WAD;
        if (betaPhi0 == 0 && betaPhi1 == 0) return 0;

        int256 v = decayedVolumeBase;
        if (decayPerSecondWad != WAD) {
            uint256 dt = block.timestamp - lastDecayTs;
            if (dt != 0) {
                uint256 d = _rpow(decayPerSecondWad, dt);
                if (v > 0) {
                    v = int256(Math.mulDiv(uint256(v), d, WAD));
                } else if (v < 0) {
                    v = -int256(Math.mulDiv(uint256(-v), d, WAD));
                }
            }
        }

        uint256 neg = v < 0 ? uint256(-v) : 0;
        uint256 term = Math.mulDiv(betaPhi1, neg, reserveTokens);
        uint256 f = betaPhi0 + term;
        return f > WAD ? WAD : f;
    }

    /**
     * β+ : convert PROTON_TOKEN -> NEUTRON_TOKEN
     * - Value path (in BASE): gross = protonIn * P•_base
     * - Apply fee φβ+ on output value
     * - neutronOut = (gross * (1-φ)) / P°_base
     * - Update \bar V += +gross (decayed ledger)
     */
    function transmuteProtonToNeutron(uint256 protonIn, address to, bytes[] calldata updateData)
        external
        payable
        nonReentrant
        returns (uint256 neutronOut, uint256 feeWad)
    {
        require(protonIn > 0, "amount=0");
        uint256 reserveTokens = reserve();
        uint256 protonSupplyCached = PROTON_TOKEN.totalSupply();
        uint256 neutronSupplyCached = NEUTRON_TOKEN.totalSupply();

        uint256 pythFee = 0;
        if (updateData.length > 0) {
            pythFee = PYTH_ORACLE.getUpdateFee(updateData);
            require(msg.value >= pythFee, "insufficient oracle fee");
            PYTH_ORACLE.updatePriceFeeds{value: pythFee}(updateData);
        }

        Price memory price = PYTH_ORACLE.getPriceNoOlderThan(PRICE_ID, MAXIMUM_AGE);
        uint256 basePrice = _pythPriceToWad(price);

        uint256 protonPriceBase = _protonPriceInBase(reserveTokens, protonSupplyCached, neutronSupplyCached, basePrice);
        uint256 neutronPriceBase = _neutronPriceInBase(reserveTokens, neutronSupplyCached, basePrice);
        require(protonPriceBase > 0 && neutronPriceBase > 0, "bad price");

        // Pull/burn input
        PROTON_TOKEN.burn(msg.sender, protonIn);

        // gross value in BASE (WAD scaling): protonIn * Pp_base / WAD
        uint256 grossBase = Math.mulDiv(protonIn, protonPriceBase, WAD);

        _decayLedger();
        feeWad = _betaPlusFeeWad(reserveTokens);
        uint256 netBase = Math.mulDiv(grossBase, (WAD - feeWad), WAD);

        neutronOut = Math.mulDiv(netBase, WAD, neutronPriceBase);
        NEUTRON_TOKEN.mint(to, neutronOut);

        // \bar V update: +grossBase
        decayedVolumeBase += _grossBaseToInt(grossBase);

        uint256 excess = msg.value > pythFee ? (msg.value - pythFee) : 0;
        if (excess > 0) {
            (bool success,) = msg.sender.call{value: excess}("");
            require(success, "refund failed");
        }

        emit TransmutePlus(msg.sender, to, protonIn, neutronOut, feeWad, decayedVolumeBase);
    }

    /**
     * β- : convert NEUTRON_TOKEN -> PROTON_TOKEN
     * - Value path (in BASE): gross = neutronIn * P°_base
     * - Apply fee φβ- on output value
     * - protonOut = (gross * (1-φ)) / P•_base
     * - Update \bar V += -gross (decayed ledger)
     */
    function transmuteNeutronToProton(uint256 neutronIn, address to, bytes[] calldata updateData)
        external
        payable
        nonReentrant
        returns (uint256 protonOut, uint256 feeWad)
    {
        require(neutronIn > 0, "amount=0");

        uint256 reserveTokens = reserve();
        uint256 protonSupplyCached = PROTON_TOKEN.totalSupply();
        uint256 neutronSupplyCached = NEUTRON_TOKEN.totalSupply();

        uint256 pythFee = 0;
        if (updateData.length > 0) {
            pythFee = PYTH_ORACLE.getUpdateFee(updateData);
            require(msg.value >= pythFee, "insufficient oracle fee");
            PYTH_ORACLE.updatePriceFeeds{value: pythFee}(updateData);
        }

        Price memory price = PYTH_ORACLE.getPriceNoOlderThan(PRICE_ID, MAXIMUM_AGE);
        uint256 basePrice = _pythPriceToWad(price);

        uint256 protonPriceBase = _protonPriceInBase(reserveTokens, protonSupplyCached, neutronSupplyCached, basePrice);
        uint256 neutronPriceBase = _neutronPriceInBase(reserveTokens, neutronSupplyCached, basePrice);
        require(protonPriceBase > 0 && neutronPriceBase > 0, "bad price");
        NEUTRON_TOKEN.burn(msg.sender, neutronIn);
        uint256 grossBase = Math.mulDiv(neutronIn, neutronPriceBase, WAD);

        _decayLedger();
        feeWad = _betaMinusFeeWad(reserveTokens);
        uint256 netBase = Math.mulDiv(grossBase, (WAD - feeWad), WAD);

        protonOut = Math.mulDiv(netBase, WAD, protonPriceBase);
        PROTON_TOKEN.mint(to, protonOut);
        decayedVolumeBase -= _grossBaseToInt(grossBase);

        uint256 excess = msg.value > pythFee ? (msg.value - pythFee) : 0;
        if (excess > 0) {
            (bool success,) = msg.sender.call{value: excess}("");
            require(success, "refund failed");
        }

        emit TransmuteMinus(msg.sender, to, neutronIn, protonOut, feeWad, decayedVolumeBase);
    }

    function _bootstrapFissionOutputs(uint256 netBase, uint256 basePriceWad)
        internal
        pure
        returns (uint256 neutronOut, uint256 protonOut)
    {
        require(basePriceWad > 0, "bad price");
        uint256 depositValueWad = Math.mulDiv(netBase, basePriceWad, WAD);
        require(depositValueWad > 0, "AmountTooSmall");
        uint256 neutronValueWad = Math.mulDiv(depositValueWad, 1, 3);
        require(neutronValueWad > 0, "AmountTooSmall");
        uint256 baseForNeutronWad = Math.mulDiv(neutronValueWad, WAD, basePriceWad);
        require(baseForNeutronWad > 0 && baseForNeutronWad < netBase, "invalid split");
        uint256 protonBaseWad = netBase - baseForNeutronWad;
        require(protonBaseWad > 0, "invalid split");
        return (neutronValueWad, protonBaseWad);
    }

    function _neutronPriceInBase(uint256 reserveTokens, uint256 neutronSupplyTokens, uint256 basePriceWad)
        internal
        view
        returns (uint256)
    {
        uint256 rWad = reserveTokens;
        if (rWad == 0) return 0;
        if (neutronSupplyTokens == 0) {
            require(basePriceWad > 0, "bad price");
            return Math.mulDiv(PEGGED_ASSET_WAD, WAD, basePriceWad);
        }
        uint256 q = _qWadDynamic(reserveTokens, neutronSupplyTokens, basePriceWad);
        return Math.mulDiv(q, rWad, neutronSupplyTokens);
    }

    function _protonPriceInBase(
        uint256 reserveTokens,
        uint256 protonSupplyTokens,
        uint256 neutronSupplyTokens,
        uint256 basePriceWad
    ) internal view returns (uint256) {
        if (protonSupplyTokens == 0) {
            return WAD;
        }
        uint256 rWad = reserveTokens;
        if (rWad == 0) {
            return 0;
        }
        uint256 q = _qWadDynamic(reserveTokens, neutronSupplyTokens, basePriceWad);
        if (q >= WAD) {
            return 0;
        }
        uint256 oneMinusQ = WAD - q;
        return Math.mulDiv(oneMinusQ, rWad, protonSupplyTokens);
    }

    function _qWadDynamic(uint256 reserveTokens, uint256 neutronSupplyTokens, uint256 basePriceWad)
        internal
        view
        returns (uint256)
    {
        if (neutronSupplyTokens == 0) {
            return 0;
        }
        require(basePriceWad > 0, "bad price");

        uint256 pStarBaseWad = Math.mulDiv(WAD, WAD, basePriceWad);
        uint256 denom = Math.mulDiv(neutronSupplyTokens, pStarBaseWad, 1);
        if (denom == 0) {
            return 0;
        }
        uint256 rScaled = Math.mulDiv(reserveTokens, WAD, 1);
        uint256 rWad = Math.mulDiv(rScaled, WAD, denom);

        uint256 rTilde;
        if (rWad > CRITICAL_RESERVE_RATIO) {
            rTilde = rWad;
        } else {
            uint256 rOverStar = Math.mulDiv(rWad, WAD, CRITICAL_RESERVE_RATIO);
            uint256 diff = CRITICAL_RESERVE_RATIO - WAD;
            uint256 part = Math.mulDiv(rOverStar, diff, WAD);
            rTilde = WAD + part;
        }
        if (rTilde == 0) return 0;
        uint256 q = Math.mulDiv(WAD, WAD, rTilde);
        return q > WAD ? WAD : q;
    }

    function _pythPriceToWad(Price memory price) internal pure returns (uint256) {
        require(price.price > 0, "bad price");
        uint256 unsignedPrice = uint256(uint64(price.price));
        if (price.expo >= 0) {
            uint32 exp = uint32(uint32(price.expo));
            require(exp <= MAX_PRICE_EXP, "expo too large");
            uint256 scale = _pow10(exp);
            uint256 scaled = Math.mulDiv(unsignedPrice, scale, 1);
            return Math.mulDiv(scaled, WAD, 1);
        } else {
            uint32 exp = uint32(uint32(-price.expo));
            require(exp <= MAX_PRICE_EXP, "expo too large");
            uint256 scale = _pow10(exp);
            return Math.mulDiv(unsignedPrice, WAD, scale);
        }
    }

    function _pow10(uint32 exp) internal pure returns (uint256 result) {
        result = 1;
        for (uint32 i = 0; i < exp; ++i) {
            result *= 10;
        }
    }

    function _grossBaseToInt(uint256 value) internal pure returns (int256) {
        require(value <= uint256(type(int256).max), "Math overflow");
        return int256(value);
    }
}
