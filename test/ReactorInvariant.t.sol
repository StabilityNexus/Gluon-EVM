// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IOracle} from "../src/interfaces/IOracle.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {Tokeon} from "../src/tokens/Tokeon.sol";
import {MockDecimalERC20} from "./GluonIntegration.t.sol";

/// @dev Oracle whose price can move, become zero, or start reverting during an invariant run.
contract InvariantOracle is IOracle {
    error OracleDown();

    uint256 private value;
    bool public reverting;

    constructor(uint256 valueParam) {
        value = valueParam;
    }

    function setValue(uint256 valueParam) external {
        value = valueParam;
    }

    function setReverting(bool revertingParam) external {
        reverting = revertingParam;
    }

    function readValue() public view returns (uint256) {
        if (reverting) revert OracleDown();
        return value;
    }

    function readValueInterval() external view returns (uint256, uint256) {
        uint256 current = readValue();
        return (current, current);
    }

    function lastUpdated() external view returns (uint256) {
        return block.timestamp;
    }

    function description() external pure returns (string memory) {
        return "Invariant Oracle";
    }
}

/// @dev Drives random sequences of user operations, oracle changes and time.
/// Per-call properties are recorded instead of asserted here and checked by
/// invariant_handlerPropertiesHold, so a failure names the property that broke.
contract ReactorHandler is Test {
    uint256 private constant WAD = 1e18;
    /// README: adjustPeg() moves the peg factor by 1% per call.
    uint256 private constant PEG_DOWN_WAD = 99e16;
    uint256 private constant PEG_UP_WAD = 101e16;

    struct Snapshot {
        uint256 reserve;
        uint256 neutronSupply;
        uint256 protonSupply;
        uint256 devBalance;
        uint256 actorBase;
        uint256 actorNeutron;
        uint256 actorProton;
        uint256 basePrice;
        uint256 ratio;
    }

    struct Trade {
        address actor;
        bool plus;
        uint256 amountIn;
        uint256 priceIn;
        uint256 amountOut;
        uint256 priceOut;
        uint256 feeWad;
    }

    StableCoinReactor public immutable reactor;
    MockDecimalERC20 public immutable base;
    InvariantOracle public immutable oracle;
    Tokeon public immutable neutron;
    Tokeon public immutable proton;
    address public immutable devFeeReceiver;
    uint256 private immutable unit;

    address[] public actors;

    /// Native base units that entered the reactor through fission, starting from the seed.
    uint256 public ghostBaseIn;
    /// Native base units that left the reactor, measured at the recipients.
    uint256 public ghostBaseOut;
    /// Transmutation volume counters after the last successful trade, and when that trade ran.
    uint256 private ghostVolumePlus;
    uint256 private ghostVolumeMinus;
    uint256 private ghostVolumeTime;
    /// First per-call property that did not hold, empty while all hold.
    string public violation;
    /// Revert data of the first revert that the reactor does not document for that call.
    bytes public unexpectedRevert;

    constructor(StableCoinReactor reactorParam, MockDecimalERC20 baseParam, InvariantOracle oracleParam) {
        reactor = reactorParam;
        base = baseParam;
        oracle = oracleParam;
        neutron = reactorParam.NEUTRON_TOKEN();
        proton = reactorParam.PROTON_TOKEN();
        devFeeReceiver = reactorParam.devFeeReceiver();
        unit = 10 ** uint256(baseParam.decimals());
        ghostBaseIn = reactorParam.reserve();
        // The reactor starts its volume ledger in the same block as this handler.
        ghostVolumeTime = block.timestamp;

        actors.push(makeAddr("invariant actor 1"));
        actors.push(makeAddr("invariant actor 2"));
        actors.push(makeAddr("invariant actor 3"));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function fission(uint256 actorSeed, uint256 amountRaw) external {
        address actor = _actor(actorSeed);
        uint256 amount = _bound(amountRaw, 1, 1_000_000 * unit);
        base.mint(actor, amount);
        Snapshot memory before = _snapshot(actor);

        vm.startPrank(actor);
        base.approve(address(reactor), amount);
        try reactor.fission(amount, actor) {
            uint256 devPaid = base.balanceOf(devFeeReceiver) - before.devBalance;
            ghostBaseIn += amount;
            ghostBaseOut += devPaid;
            uint256 devFee = reactor.devFee();
            uint256 net = Math.mulDiv(amount, WAD - reactor.FISSION_FEE() - devFee, WAD);
            _check(_inRange(before.ratio), "fission succeeded out of range");
            _check(devPaid == Math.mulDiv(amount, devFee, WAD), "fission dev fee");
            // Claims are minted in proportion to the existing supplies, rounded down.
            _check(
                neutron.totalSupply() - before.neutronSupply == Math.mulDiv(net, before.neutronSupply, before.reserve)
                    && proton.totalSupply() - before.protonSupply
                        == Math.mulDiv(net, before.protonSupply, before.reserve),
                "fission mint"
            );
            _checkClaimsNotDiluted(before, "fission diluted claims");
        } catch (bytes memory reason) {
            _checkRangeRevert(reason, before, bytes4(0));
        }
        vm.stopPrank();
    }

    function fusion(uint256 actorSeed, uint256 amountRaw) external {
        address actor = _actor(actorSeed);
        uint256 reserve = reactor.reserve();
        // Largest withdrawal whose rounded-up burns the actor can cover.
        uint256 maxOut = Math.min(
            Math.mulDiv(neutron.balanceOf(actor), reserve, neutron.totalSupply()),
            Math.mulDiv(proton.balanceOf(actor), reserve, proton.totalSupply())
        );
        if (maxOut == 0) return;
        uint256 amount = _bound(amountRaw, 1, maxOut);
        Snapshot memory before = _snapshot(actor);

        vm.startPrank(actor);
        try reactor.fusion(amount, actor) {
            uint256 userPaid = base.balanceOf(actor) - before.actorBase;
            uint256 devPaid = base.balanceOf(devFeeReceiver) - before.devBalance;
            ghostBaseOut += userPaid + devPaid;
            uint256 devFee = reactor.devFee();
            _check(_inRange(before.ratio), "fusion succeeded out of range");
            _check(devPaid == Math.mulDiv(amount, devFee, WAD), "fusion dev fee");
            _check(userPaid == Math.mulDiv(amount, WAD - reactor.FUSION_FEE() - devFee, WAD), "fusion payout");
            // Claims are burned in proportion to the existing supplies, rounded up.
            _check(
                before.neutronSupply - neutron.totalSupply()
                        == Math.mulDiv(amount, before.neutronSupply, before.reserve, Math.Rounding.Ceil)
                    && before.protonSupply - proton.totalSupply()
                        == Math.mulDiv(amount, before.protonSupply, before.reserve, Math.Rounding.Ceil),
                "fusion burn"
            );
            _checkClaimsNotDiluted(before, "fusion diluted claims");
        } catch (bytes memory reason) {
            _checkRangeRevert(reason, before, bytes4(0));
        }
        vm.stopPrank();
    }

    function transmuteProtonToNeutron(uint256 actorSeed, uint256 amountRaw) external {
        address actor = _actor(actorSeed);
        uint256 balance = proton.balanceOf(actor);
        if (balance == 0) return;
        Trade memory trade;
        trade.actor = actor;
        trade.plus = true;
        trade.amountIn = _bound(amountRaw, 1, balance);
        trade.priceIn = reactor.protonPriceInBase();
        trade.priceOut = reactor.neutronPriceInBase();
        Snapshot memory before = _snapshot(actor);

        vm.recordLogs();
        vm.startPrank(actor);
        try reactor.transmuteProtonToNeutron(trade.amountIn, 0, actor) returns (uint256 neutronOut, uint256 feeWad) {
            trade.amountOut = neutronOut;
            trade.feeWad = feeWad;
            _checkTransmutation(before, trade, "beta plus");
            if (before.basePrice != 0) {
                _check(
                    reactor.reserveRatioPeggedAsset() >= reactor.CRITICAL_RESERVE_RATIO(), "beta plus below critical"
                );
            }
        } catch (bytes memory reason) {
            if (
                reason.length == 4 && _selector(reason) == StableCoinReactor.ResultingReserveRatioBelowCritical.selector
            ) {
                _check(_betaPlusCanBreachCritical(before, trade), "beta plus refused a safe trade");
            }
            _checkRangeRevert(reason, before, StableCoinReactor.ResultingReserveRatioBelowCritical.selector);
        }
        vm.stopPrank();
    }

    function transmuteNeutronToProton(uint256 actorSeed, uint256 amountRaw) external {
        address actor = _actor(actorSeed);
        uint256 balance = neutron.balanceOf(actor);
        if (balance == 0) return;
        Trade memory trade;
        trade.actor = actor;
        trade.amountIn = _bound(amountRaw, 1, balance);
        trade.priceIn = reactor.neutronPriceInBase();
        trade.priceOut = reactor.protonPriceInBase();
        Snapshot memory before = _snapshot(actor);

        vm.recordLogs();
        vm.startPrank(actor);
        try reactor.transmuteNeutronToProton(trade.amountIn, 0, actor) returns (uint256 protonOut, uint256 feeWad) {
            trade.amountOut = protonOut;
            trade.feeWad = feeWad;
            _checkTransmutation(before, trade, "beta minus");
        } catch (bytes memory reason) {
            _checkRangeRevert(reason, before, bytes4(0));
        }
        vm.stopPrank();
    }

    /// A zero amount must revert with AmountZero in every operation, whatever the reactor state.
    function zeroAmount(uint256 actorSeed, uint256 operation) external {
        address actor = _actor(actorSeed);
        bytes memory data;
        if (operation % 4 == 0) data = abi.encodeCall(StableCoinReactor.fission, (0, actor));
        else if (operation % 4 == 1) data = abi.encodeCall(StableCoinReactor.fusion, (0, actor));
        else if (operation % 4 == 2) data = abi.encodeCall(StableCoinReactor.transmuteProtonToNeutron, (0, 0, actor));
        else data = abi.encodeCall(StableCoinReactor.transmuteNeutronToProton, (0, 0, actor));

        vm.prank(actor);
        (bool success, bytes memory reason) = address(reactor).call(data);
        _check(
            !success && reason.length == 4 && _selector(reason) == StableCoinReactor.AmountZero.selector,
            "zero amount not rejected"
        );
    }

    /// Calls adjustPeg() up to 20 times, like a keeper moving the ratio back into range. Each call
    /// must step the peg factor by 1% in the right direction, or refuse only inside the range.
    function adjustPeg(uint256 stepsRaw) external {
        uint256 steps = _bound(stepsRaw, 1, 20);
        for (uint256 i; i < steps; ++i) {
            uint256 ratio = reactor.reserveRatioPeggedAsset();
            uint256 basePrice = reactor.getBasePriceInPeggedAsset();
            uint256 factor = reactor.pegFactor();
            try reactor.adjustPeg() {
                uint256 expected = factor;
                if (basePrice != 0) {
                    _check(!_inRange(ratio), "peg adjusted inside range");
                    expected = ratio < reactor.CRITICAL_RESERVE_RATIO()
                        ? Math.max(1, Math.mulDiv(factor, PEG_DOWN_WAD, WAD))
                        : Math.mulDiv(factor, PEG_UP_WAD, WAD, Math.Rounding.Ceil);
                }
                _check(reactor.pegFactor() == expected, "peg step");
            } catch (bytes memory reason) {
                if (reason.length == 4 && _selector(reason) == StableCoinReactor.PegAdjustmentNotNeeded.selector) {
                    _check(basePrice != 0 && _inRange(ratio), "peg refused out of range");
                } else {
                    _recordUnexpected(reason);
                }
                return;
            }
        }
    }

    /// Sets the price that moves the reserve ratio to between 110% and 210%, crossing both the
    /// 120% critical and the 200% upper boundary. Occasionally sets a zero, 1 wei or uint128 max price.
    function setOraclePrice(uint256 ratioRaw) external {
        uint256 extreme = ratioRaw % 20;
        if (extreme < 3) {
            oracle.setValue(extreme == 0 ? 0 : extreme == 1 ? 1 : type(uint128).max);
            return;
        }
        uint256 ratio = _bound(ratioRaw, 11e17, 21e17);
        uint256 normalizedReserve = Math.mulDiv(reactor.reserve(), WAD, unit);
        // reserve ratio = reserve * price * PEG_FACTOR_SCALE / (neutron supply * pegFactor)
        uint256 price = Math.mulDiv(
            Math.mulDiv(ratio, neutron.totalSupply(), normalizedReserve),
            reactor.pegFactor(),
            reactor.PEG_FACTOR_SCALE()
        );
        oracle.setValue(Math.max(price, 1));
    }

    function setOracleReverting(bool reverting) external {
        oracle.setReverting(reverting);
    }

    function warp(uint256 secondsRaw) external {
        vm.warp(block.timestamp + _bound(secondsRaw, 1, 1 days));
    }

    /// Checks a transmutation against values computed from the pre-trade views and the trade's event.
    /// A zero base price or a zero floor price makes the trade a no-op. Otherwise the trade must run
    /// inside the range, charge the beta fee given by the decayed volume ledger, pay a dev fee of
    /// floor(floor(gross * devFee) in native units), move no other base out of the reserve, and mint
    /// no more than the net value at the minted token's floor price.
    function _checkTransmutation(Snapshot memory before, Trade memory trade, string memory label) private {
        uint256 devPaid = base.balanceOf(devFeeReceiver) - before.devBalance;
        ghostBaseOut += devPaid;
        _check(before.reserve - reactor.reserve() == devPaid, string.concat(label, " moved reserve"));

        (uint256 inSupply, uint256 outSupply, uint256 actorIn, uint256 actorOut) = trade.plus
            ? (before.protonSupply, before.neutronSupply, before.actorProton, before.actorNeutron)
            : (before.neutronSupply, before.protonSupply, before.actorNeutron, before.actorProton);
        (Tokeon tokenIn, Tokeon tokenOut) = trade.plus ? (proton, neutron) : (neutron, proton);

        if (trade.priceIn == 0 || trade.priceOut == 0) {
            _check(
                trade.amountOut == 0 && trade.feeWad == 0 && devPaid == 0 && tokenIn.totalSupply() == inSupply
                    && tokenOut.totalSupply() == outSupply && tokenIn.balanceOf(trade.actor) == actorIn
                    && tokenOut.balanceOf(trade.actor) == actorOut,
                string.concat(label, " no-op")
            );
            return;
        }
        // The actor's input is burned and the output is minted to the actor, nothing else.
        _check(
            inSupply - tokenIn.totalSupply() == trade.amountIn
                && actorIn - tokenIn.balanceOf(trade.actor) == trade.amountIn
                && tokenOut.totalSupply() - outSupply == trade.amountOut
                && tokenOut.balanceOf(trade.actor) - actorOut == trade.amountOut,
            string.concat(label, " burn and mint")
        );
        _check(_inRange(before.ratio), string.concat(label, " succeeded out of range"));

        uint256 grossBase = Math.mulDiv(trade.amountIn, trade.priceIn, WAD);
        uint256 devFee = reactor.devFee();
        _check(devPaid == Math.mulDiv(Math.mulDiv(grossBase, devFee, WAD), unit, WAD), string.concat(label, " dev fee"));
        _checkBetaFee(before, trade, grossBase, devPaid, label);
        uint256 netBase = Math.mulDiv(grossBase, WAD - trade.feeWad - devFee, WAD);
        _check(_productAtLeast(netBase, WAD, trade.amountOut, trade.priceOut), string.concat(label, " overpaid output"));
    }

    /// The ledger decays both counters from the last trade's values, then adds this trade's gross value
    /// to its own direction. The event must report exactly that, and the fee must follow from the
    /// decayed counters.
    function _checkBetaFee(
        Snapshot memory before,
        Trade memory trade,
        uint256 grossBase,
        uint256 devPaid,
        string memory label
    ) private {
        (uint256 decayedPlus, uint256 decayedMinus) = _decayedVolumes();
        (bool found, uint256 volumePlus, uint256 volumeMinus) = _transmutationEvent(trade, devPaid);
        _check(found, string.concat(label, " event"));
        _check(
            volumePlus == decayedPlus + (trade.plus ? grossBase : 0)
                && volumeMinus == decayedMinus + (trade.plus ? 0 : grossBase),
            string.concat(label, " ledger")
        );
        // The fee is charged on the decayed counters before this trade is added.
        _check(
            trade.feeWad == _expectedBetaFee(trade.plus, Math.mulDiv(before.reserve, WAD, unit)),
            string.concat(label, " beta fee")
        );
        (ghostVolumePlus, ghostVolumeMinus, ghostVolumeTime) =
        (decayedPlus + (trade.plus ? grossBase : 0), decayedMinus + (trade.plus ? 0 : grossBase), block.timestamp);
    }

    /// The volume counters as the reactor decays them before a trade at the current timestamp.
    function _decayedVolumes() private view returns (uint256 decayedPlus, uint256 decayedMinus) {
        uint256 decay = reactor.decayPerSecondWad();
        uint256 elapsed = block.timestamp - ghostVolumeTime;
        if (elapsed == 0 || decay == WAD) return (ghostVolumePlus, ghostVolumeMinus);
        uint256 factor = _rpow(decay, elapsed);
        return (Math.mulDiv(ghostVolumePlus, factor, WAD), Math.mulDiv(ghostVolumeMinus, factor, WAD));
    }

    /// The beta fee for a trade in one direction: betaPhi0 plus betaPhi1 times the positive net
    /// volume in that direction over the reserve, rounded up and capped at 100%.
    function _expectedBetaFee(bool plus, uint256 normalizedReserve) private view returns (uint256) {
        (uint256 decayedPlus, uint256 decayedMinus) = _decayedVolumes();
        (uint256 own, uint256 other) = plus ? (decayedPlus, decayedMinus) : (decayedMinus, decayedPlus);
        uint256 boundedVolume = Math.min(own > other ? own - other : 0, Math.saturatingMul(normalizedReserve, WAD));
        uint256 volumeFee = normalizedReserve == 0
            ? 0
            : Math.mulDiv(reactor.betaPhi1(), boundedVolume, normalizedReserve, Math.Rounding.Ceil);
        return Math.min(reactor.betaPhi0() + volumeFee, WAD);
    }

    /// Whether a refused beta plus trade could have left the ratio below critical. It uses the most
    /// Neutrons the trade could mint (net value at the floor price), and a ratio rounded down, so it
    /// never calls a real breach safe.
    function _betaPlusCanBreachCritical(Snapshot memory before, Trade memory trade) private view returns (bool) {
        uint256 devFee = reactor.devFee();
        uint256 normalizedReserve = Math.mulDiv(before.reserve, WAD, unit);
        uint256 fee = _expectedBetaFee(true, normalizedReserve);
        if (trade.priceOut == 0 || fee + devFee > WAD) return true;
        uint256 grossBase = Math.mulDiv(trade.amountIn, trade.priceIn, WAD);
        uint256 maxNeutronOut = Math.mulDiv(Math.mulDiv(grossBase, WAD - fee - devFee, WAD), WAD, trade.priceOut);
        uint256 devPaid = Math.mulDiv(Math.mulDiv(grossBase, devFee, WAD), unit, WAD);
        uint256 reserveAfter = Math.mulDiv(before.reserve - devPaid, WAD, unit);
        uint256 ratioAfter = Math.mulDiv(
            Math.mulDiv(reserveAfter, before.basePrice, before.neutronSupply + maxNeutronOut),
            reactor.PEG_FACTOR_SCALE(),
            reactor.pegFactor()
        );
        return ratioAfter < reactor.CRITICAL_RESERVE_RATIO();
    }

    /// The reactor's binary exponentiation of a WAD value, rounding down at every step.
    function _rpow(uint256 x, uint256 n) private pure returns (uint256 z) {
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

    /// Finds the trade's TransmutePlus or TransmuteMinus event, reports whether it matches the trade,
    /// and returns the volume counters it reports.
    function _transmutationEvent(Trade memory trade, uint256 devPaid)
        private
        returns (bool found, uint256 volumePlus, uint256 volumeMinus)
    {
        bytes32 topic =
            trade.plus ? StableCoinReactor.TransmutePlus.selector : StableCoinReactor.TransmuteMinus.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(reactor) || logs[i].topics[0] != topic) continue;
            uint256 amountIn;
            uint256 amountOut;
            uint256 feeWad;
            uint256 devFeeAmount;
            (amountIn, amountOut, feeWad, volumePlus, volumeMinus, devFeeAmount) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
            found = amountIn == trade.amountIn && amountOut == trade.amountOut && feeWad == trade.feeWad
                && devFeeAmount == devPaid;
        }
    }

    /// Fission mints rounded down and fusion burns rounded up, and their protocol fees stay in the
    /// reserve, so neither may lower the reserve backing each Neutron or each Proton.
    function _checkClaimsNotDiluted(Snapshot memory before, string memory label) private {
        uint256 reserve = reactor.reserve();
        _check(
            _productAtLeast(reserve, before.neutronSupply, before.reserve, neutron.totalSupply())
                && _productAtLeast(reserve, before.protonSupply, before.reserve, proton.totalSupply()),
            label
        );
    }

    /// A user operation may only revert with ReserveRatioOutOfRange when the ratio it saw, which it
    /// reports, was outside the range. `resultReverts` is a revert allowed only inside the range.
    function _checkRangeRevert(bytes memory reason, Snapshot memory before, bytes4 resultReverts) private {
        bytes4 selector = reason.length >= 4 ? _selector(reason) : bytes4(0);
        if (reason.length == 36 && selector == StableCoinReactor.ReserveRatioOutOfRange.selector) {
            _check(!_inRange(before.ratio) && _revertArgument(reason) == before.ratio, "range revert inside range");
        } else if (resultReverts != bytes4(0) && reason.length == 4 && selector == resultReverts) {
            _check(before.basePrice != 0 && _inRange(before.ratio), "result revert out of range");
        } else {
            _recordUnexpected(reason);
        }
    }

    function _inRange(uint256 ratio) private view returns (bool) {
        return ratio >= reactor.CRITICAL_RESERVE_RATIO() && ratio <= reactor.UPPER_RESERVE_RATIO();
    }

    /// a * b >= c * d, compared as 512-bit products so large supplies cannot overflow the check.
    function _productAtLeast(uint256 a, uint256 b, uint256 c, uint256 d) private pure returns (bool) {
        (uint256 leftHigh, uint256 leftLow) = Math.mul512(a, b);
        (uint256 rightHigh, uint256 rightLow) = Math.mul512(c, d);
        return leftHigh > rightHigh || (leftHigh == rightHigh && leftLow >= rightLow);
    }

    function _snapshot(address actor) private view returns (Snapshot memory) {
        return Snapshot({
            reserve: reactor.reserve(),
            neutronSupply: neutron.totalSupply(),
            protonSupply: proton.totalSupply(),
            devBalance: base.balanceOf(devFeeReceiver),
            actorBase: base.balanceOf(actor),
            actorNeutron: neutron.balanceOf(actor),
            actorProton: proton.balanceOf(actor),
            basePrice: reactor.getBasePriceInPeggedAsset(),
            ratio: reactor.reserveRatioPeggedAsset()
        });
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _check(bool holds, string memory label) private {
        if (!holds && bytes(violation).length == 0) violation = label;
    }

    function _recordUnexpected(bytes memory reason) private {
        if (unexpectedRevert.length == 0) unexpectedRevert = reason.length == 0 ? bytes("empty") : reason;
    }

    function _selector(bytes memory reason) private pure returns (bytes4) {
        // Truncating to the first four bytes is intended: they are the custom error selector.
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes4(reason);
    }

    /// The single uint256 argument of a custom error, stored after the 4-byte selector.
    function _revertArgument(bytes memory reason) private pure returns (uint256 value) {
        assembly ("memory-safe") {
            value := mload(add(reason, 36))
        }
    }
}

/// @dev Stateful invariants for a factory-deployed reactor. Subcontracts choose decimals and fees.
abstract contract ReactorInvariantBase is Test {
    uint256 internal constant WAD = 1e18;

    struct Config {
        uint8 decimals;
        uint256 devFee;
        uint256 fissionFee;
        uint256 fusionFee;
        uint256 betaPhi0;
        uint256 betaPhi1;
        uint256 decayPerSecondWad;
    }

    StableCoinReactor internal reactor;
    MockDecimalERC20 internal base;
    ReactorHandler internal handler;
    uint256 internal unit;
    uint256 internal lockedNeutron;
    uint256 internal lockedProton;

    function _config() internal pure virtual returns (Config memory);

    function setUp() public {
        Config memory config = _config();
        unit = 10 ** uint256(config.decimals);
        base = new MockDecimalERC20("Base", "BASE", config.decimals);
        InvariantOracle oracle = new InvariantOracle(2e18);
        StableCoinFactory factory = new StableCoinFactory(makeAddr("dev"), config.devFee);

        uint256 seed = 1_000 * unit;
        base.mint(address(this), seed);
        base.approve(address(factory), seed);
        reactor = StableCoinReactor(
            factory.deployReactor(
                "Invariant Vault",
                "Base",
                "BASE",
                "Pegged",
                "PEG",
                address(base),
                address(oracle),
                "Proton",
                "PRO",
                config.fissionFee,
                config.fusionFee,
                12e17,
                15e17,
                seed,
                config.betaPhi0,
                config.betaPhi1,
                config.decayPerSecondWad
            )
        );
        lockedNeutron = reactor.NEUTRON_TOKEN().balanceOf(address(reactor));
        lockedProton = reactor.PROTON_TOKEN().balanceOf(address(reactor));

        handler = new ReactorHandler(reactor, base, oracle);
        targetContract(address(handler));
    }

    /// Base tokens only enter through fission and only leave as payouts and dev fees.
    function invariant_reserveMatchesTrackedFlows() public view {
        assertEq(base.balanceOf(address(reactor)), handler.ghostBaseIn() - handler.ghostBaseOut());
    }

    /// The initial Neutron and Proton allocation minted to the reactor stays locked.
    function invariant_initialAllocationStaysLocked() public view {
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(address(reactor)), lockedNeutron);
        assertEq(reactor.PROTON_TOKEN().balanceOf(address(reactor)), lockedProton);
    }

    /// Every Neutron and Proton is held by the reactor's locked allocation or by an actor.
    function invariant_suppliesAreFullyHeld() public view {
        uint256 neutronHeld = lockedNeutron;
        uint256 protonHeld = lockedProton;
        for (uint256 i; i < handler.actorCount(); ++i) {
            neutronHeld += reactor.NEUTRON_TOKEN().balanceOf(handler.actors(i));
            protonHeld += reactor.PROTON_TOKEN().balanceOf(handler.actors(i));
        }
        assertEq(reactor.NEUTRON_TOKEN().totalSupply(), neutronHeld);
        assertEq(reactor.PROTON_TOKEN().totalSupply(), protonHeld);
    }

    /// The reported Neutron and Proton prices never value all claims above the reserve.
    function invariant_claimsNeverExceedReserve() public view {
        uint256 claims = reactor.neutronPriceInBase() * reactor.NEUTRON_TOKEN().totalSupply()
            + reactor.protonPriceInBase() * reactor.PROTON_TOKEN().totalSupply();
        assertLe(claims, reactor.reserve() * WAD / unit * WAD);
    }

    /// The peg factor and the cached fallback price stay positive (a zero price is never cached), and
    /// the remaining public views stay callable for oracle prices up to the uint128 max the handler uses.
    function invariant_pegFactorAndViewsStayUsable() public view {
        assertGt(reactor.pegFactor(), 0);
        assertGt(reactor.lastSuccessfulBasePrice(), 0);
        reactor.reserveRatioPeggedAsset();
        reactor.qWad();
        reactor.neutronPriceInPeggedAsset();
        reactor.protonPriceInPeggedAsset();
    }

    /// Every per-call property recorded by the handler held, and every revert was documented.
    function invariant_handlerPropertiesHold() public view {
        assertEq(handler.violation(), "");
        assertEq(handler.unexpectedRevert(), "");
    }
}

/// @dev 18-decimal reserve with Gluon's 0.1% dev fee, different fission and fusion fees and a fixed
/// beta fee.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract ReactorInvariant18DecimalTest is ReactorInvariantBase {
    function _config() internal pure override returns (Config memory) {
        return Config({
            decimals: 18,
            devFee: 1e15,
            fissionFee: 3e15,
            fusionFee: 5e15,
            betaPhi0: 3e15,
            betaPhi1: 0,
            decayPerSecondWad: WAD
        });
    }
}

/// @dev 6-decimal reserve without fixed fees, so rounding alone decides each result, and a
/// volume-dependent beta fee that decays over time. The dev fee is zero here because a beta fee capped
/// at 100% plus a dev fee reverts (README: combined rates above 100% revert; the arithmetic panic is
/// covered by testFullBetaFeeWithDevFeeRevertsWithoutPaying). The 18-decimal configuration covers the
/// dev fee.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract ReactorInvariant6DecimalTest is ReactorInvariantBase {
    function _config() internal pure override returns (Config memory) {
        return Config({
            decimals: 6, devFee: 0, fissionFee: 0, fusionFee: 0, betaPhi0: 0, betaPhi1: 5e17, decayPerSecondWad: 999e15
        });
    }
}
