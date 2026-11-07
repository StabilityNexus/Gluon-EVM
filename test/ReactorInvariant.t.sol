// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IOracle} from "../src/interfaces/IOracle.sol";
import {StableCoinFactory} from "../src/StableCoinFactory.sol";
import {StableCoinReactor} from "../src/StableCoin.sol";
import {Tokeon} from "../src/tokens/Tokeon.sol";
import {MockDecimalERC20} from "./GluonIntegration.t.sol";

uint256 constant WAD = 1e18;

// Oracle whose price can move, become zero or revert.
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

// Calls reactor actions in random order and records the first broken per-call property by name.
contract ReactorHandler is Test {
    // README: adjustPeg() moves the peg factor by 1% per call. Kept as the spec, not read from the reactor.
    uint256 private constant PEG_DOWN_WAD = 99e16;
    uint256 private constant PEG_UP_WAD = 101e16;

    struct Snapshot {
        uint256 reserve;
        uint256 neutronSupply;
        uint256 protonSupply;
        uint256 devBalance;
        uint256 actorNeutron;
        uint256 actorProton;
        uint256 recipientBase;
        uint256 recipientNeutron;
        uint256 recipientProton;
        uint256 basePrice;
        uint256 ratio;
    }

    struct Trade {
        address actor;
        address recipient;
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

    // Base that entered the reactor (seed and fission) and base that left it, in native units.
    uint256 public ghostBaseIn;
    uint256 public ghostBaseOut;
    // Volume counters and time after the last successful transmutation.
    uint256 private ghostVolumePlus;
    uint256 private ghostVolumeMinus;
    uint256 private ghostVolumeTime;
    string public violation;
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
        // The reactor starts its volume ledger in this block.
        ghostVolumeTime = block.timestamp;

        actors.push(makeAddr("invariant actor 1"));
        actors.push(makeAddr("invariant actor 2"));
        actors.push(makeAddr("invariant actor 3"));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function fission(uint256 actorSeed, uint256 recipientSeed, uint256 amountRaw) external {
        address actor = _actor(actorSeed);
        address recipient = _actor(recipientSeed);
        uint256 amount = _bound(amountRaw, 1, 1_000_000 * unit);
        base.mint(actor, amount);
        Snapshot memory before = _snapshot(actor, recipient);

        vm.startPrank(actor);
        base.approve(address(reactor), amount);
        vm.recordLogs();
        try reactor.fission(amount, recipient) {
            uint256 devPaid = base.balanceOf(devFeeReceiver) - before.devBalance;
            ghostBaseIn += amount;
            ghostBaseOut += devPaid;
            uint256 devFee = reactor.devFee();
            uint256 net = Math.mulDiv(amount, WAD - reactor.FISSION_FEE() - devFee, WAD);
            uint256 neutronOut = Math.mulDiv(net, before.neutronSupply, before.reserve);
            uint256 protonOut = Math.mulDiv(net, before.protonSupply, before.reserve);
            _check(_inRange(before.ratio), "fission succeeded out of range");
            _check(devPaid == Math.mulDiv(amount, devFee, WAD), "fission dev fee");
            _check(
                neutron.totalSupply() - before.neutronSupply == neutronOut
                    && proton.totalSupply() - before.protonSupply == protonOut
                    && neutron.balanceOf(recipient) - before.recipientNeutron == neutronOut
                    && proton.balanceOf(recipient) - before.recipientProton == protonOut,
                "fission mint"
            );
            (bool found, bytes memory data) = _reactorEvent(StableCoinReactor.Fission.selector, actor, recipient);
            _check(
                found
                    && keccak256(data)
                        == keccak256(abi.encode(amount, neutronOut, protonOut, amount - net - devPaid, devPaid)),
                "fission event"
            );
        } catch (bytes memory reason) {
            _checkRangeRevert(reason, before, bytes4(0));
        }
        vm.stopPrank();
    }

    function fusion(uint256 actorSeed, uint256 recipientSeed, uint256 amountRaw) external {
        address actor = _actor(actorSeed);
        address recipient = _actor(recipientSeed);
        uint256 reserve = reactor.reserve();
        // Largest withdrawal whose rounded-up burns the actor can pay.
        uint256 maxOut = Math.min(
            Math.mulDiv(neutron.balanceOf(actor), reserve, neutron.totalSupply()),
            Math.mulDiv(proton.balanceOf(actor), reserve, proton.totalSupply())
        );
        if (maxOut == 0) return;
        uint256 amount = _bound(amountRaw, 1, maxOut);
        Snapshot memory before = _snapshot(actor, recipient);

        vm.startPrank(actor);
        vm.recordLogs();
        try reactor.fusion(amount, recipient) {
            uint256 userPaid = base.balanceOf(recipient) - before.recipientBase;
            uint256 devPaid = base.balanceOf(devFeeReceiver) - before.devBalance;
            ghostBaseOut += userPaid + devPaid;
            uint256 devFee = reactor.devFee();
            uint256 neutronBurn = Math.mulDiv(amount, before.neutronSupply, before.reserve, Math.Rounding.Ceil);
            uint256 protonBurn = Math.mulDiv(amount, before.protonSupply, before.reserve, Math.Rounding.Ceil);
            _check(_inRange(before.ratio), "fusion succeeded out of range");
            _check(devPaid == Math.mulDiv(amount, devFee, WAD), "fusion dev fee");
            _check(userPaid == Math.mulDiv(amount, WAD - reactor.FUSION_FEE() - devFee, WAD), "fusion payout");
            _check(
                before.neutronSupply - neutron.totalSupply() == neutronBurn
                    && before.protonSupply - proton.totalSupply() == protonBurn
                    && before.actorNeutron - neutron.balanceOf(actor) == neutronBurn
                    && before.actorProton - proton.balanceOf(actor) == protonBurn,
                "fusion burn"
            );
            (bool found, bytes memory data) = _reactorEvent(StableCoinReactor.Fusion.selector, actor, recipient);
            _check(
                found
                    && keccak256(data)
                        == keccak256(
                            abi.encode(neutronBurn, protonBurn, userPaid, amount - userPaid - devPaid, devPaid)
                        ),
                "fusion event"
            );
        } catch (bytes memory reason) {
            _checkRangeRevert(reason, before, bytes4(0));
        }
        vm.stopPrank();
    }

    function transmuteProtonToNeutron(uint256 actorSeed, uint256 recipientSeed, uint256 amountRaw) external {
        address actor = _actor(actorSeed);
        uint256 balance = proton.balanceOf(actor);
        if (balance == 0) return;
        Trade memory trade = _trade(actor, _actor(recipientSeed), true, _bound(amountRaw, 1, balance));
        Snapshot memory before = _snapshot(actor, trade.recipient);

        vm.recordLogs();
        vm.startPrank(actor);
        try reactor.transmuteProtonToNeutron(trade.amountIn, 0, trade.recipient) returns (
            uint256 neutronOut, uint256 feeWad
        ) {
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
            _checkTransmutationRevert(
                reason, before, trade, StableCoinReactor.ResultingReserveRatioBelowCritical.selector
            );
        }
        vm.stopPrank();
    }

    function transmuteNeutronToProton(uint256 actorSeed, uint256 recipientSeed, uint256 amountRaw) external {
        address actor = _actor(actorSeed);
        uint256 balance = neutron.balanceOf(actor);
        if (balance == 0) return;
        Trade memory trade = _trade(actor, _actor(recipientSeed), false, _bound(amountRaw, 1, balance));
        Snapshot memory before = _snapshot(actor, trade.recipient);

        vm.recordLogs();
        vm.startPrank(actor);
        try reactor.transmuteNeutronToProton(trade.amountIn, 0, trade.recipient) returns (
            uint256 protonOut, uint256 feeWad
        ) {
            trade.amountOut = protonOut;
            trade.feeWad = feeWad;
            _checkTransmutation(before, trade, "beta minus");
        } catch (bytes memory reason) {
            _checkTransmutationRevert(reason, before, trade, bytes4(0));
        }
        vm.stopPrank();
    }

    // A zero amount must revert with AmountZero in every operation.
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

    // Up to 20 keeper calls. Each must step 1% the right way, or refuse only inside the range.
    function adjustPeg(uint256 stepsRaw) external {
        uint256 steps = _bound(stepsRaw, 1, 20);
        for (uint256 i; i < steps; ++i) {
            uint256 ratio = reactor.reserveRatioPeggedAsset();
            uint256 basePrice = reactor.getBasePriceInPeggedAsset();
            uint256 factor = reactor.pegFactor();
            vm.recordLogs();
            try reactor.adjustPeg() {
                uint256 expected = factor;
                if (basePrice != 0) {
                    _check(!_inRange(ratio), "peg adjusted inside range");
                    expected = ratio < reactor.CRITICAL_RESERVE_RATIO()
                        ? Math.max(1, Math.mulDiv(factor, PEG_DOWN_WAD, WAD))
                        : Math.mulDiv(factor, PEG_UP_WAD, WAD, Math.Rounding.Ceil);
                }
                _check(reactor.pegFactor() == expected, "peg step");
                (bool found, bytes memory data) =
                    _reactorEvent(StableCoinReactor.PegAdjusted.selector, address(0), address(0));
                _check(
                    basePrice == 0
                        ? !found
                        : found && keccak256(data) == keccak256(abi.encode(factor, expected, ratio)),
                    "peg event"
                );
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

    // Sets a price for a 110% to 210% ratio. Rarely sets 0, 1 wei or uint128 max, or a price that puts
    // the ratio on or just above the 120% or 200% boundary (no effect on views while the oracle reverts).
    function setOraclePrice(uint256 ratioRaw) external {
        uint256 pick = ratioRaw % 20;
        if (pick < 3) {
            oracle.setValue(pick == 0 ? 0 : pick == 1 ? 1 : type(uint128).max);
            return;
        }
        if (pick < 5) {
            _setPriceAtRatio(pick == 3 ? reactor.CRITICAL_RESERVE_RATIO() : reactor.UPPER_RESERVE_RATIO());
            return;
        }
        oracle.setValue(_priceForRatio(_bound(ratioRaw, 11e17, 21e17), Math.Rounding.Floor));
    }

    function setOracleReverting(bool reverting) external {
        oracle.setReverting(reverting);
    }

    function warp(uint256 secondsRaw) external {
        vm.warp(block.timestamp + _bound(secondsRaw, 1, 1 days));
    }

    function _trade(address actor, address recipient, bool plus, uint256 amountIn)
        private
        view
        returns (Trade memory trade)
    {
        trade.actor = actor;
        trade.recipient = recipient;
        trade.plus = plus;
        trade.amountIn = amountIn;
        (trade.priceIn, trade.priceOut) = plus
            ? (reactor.protonPriceInBase(), reactor.neutronPriceInBase())
            : (reactor.neutronPriceInBase(), reactor.protonPriceInBase());
    }

    // reserve ratio = reserve * price * PEG_FACTOR_SCALE / (neutron supply * pegFactor)
    function _priceForRatio(uint256 ratio, Math.Rounding rounding) private view returns (uint256) {
        uint256 price = Math.mulDiv(
            Math.mulDiv(ratio, neutron.totalSupply(), _normalize(reactor.reserve()), rounding),
            reactor.pegFactor(),
            reactor.PEG_FACTOR_SCALE(),
            rounding
        );
        return Math.max(price, 1);
    }

    // The ratio rises with the price, so step up from a rounded-up estimate until it reaches the bound.
    function _setPriceAtRatio(uint256 target) private {
        uint256 price = _priceForRatio(target, Math.Rounding.Ceil);
        for (uint256 i; i < 4; ++i) {
            oracle.setValue(price + i);
            if (reactor.reserveRatioPeggedAsset() >= target) return;
        }
    }

    // Checks a transmutation against the pre-trade views and its event. A zero price means a no-op.
    function _checkTransmutation(Snapshot memory before, Trade memory trade, string memory label) private {
        uint256 devPaid = base.balanceOf(devFeeReceiver) - before.devBalance;
        ghostBaseOut += devPaid;
        _check(before.reserve - reactor.reserve() == devPaid, string.concat(label, " moved reserve"));

        (uint256 inSupply, uint256 outSupply, uint256 actorIn, uint256 recipientOut) = trade.plus
            ? (before.protonSupply, before.neutronSupply, before.actorProton, before.recipientNeutron)
            : (before.neutronSupply, before.protonSupply, before.actorNeutron, before.recipientProton);
        (Tokeon tokenIn, Tokeon tokenOut) = trade.plus ? (proton, neutron) : (neutron, proton);

        if (trade.priceIn == 0 || trade.priceOut == 0) {
            (bool emitted,) = _reactorEvent(_transmutationTopic(trade.plus), address(0), address(0));
            _check(
                trade.amountOut == 0 && trade.feeWad == 0 && devPaid == 0 && !emitted
                    && tokenIn.totalSupply() == inSupply && tokenOut.totalSupply() == outSupply
                    && tokenIn.balanceOf(trade.actor) == actorIn && tokenOut.balanceOf(trade.recipient) == recipientOut,
                string.concat(label, " no-op")
            );
            return;
        }
        _check(
            inSupply - tokenIn.totalSupply() == trade.amountIn
                && actorIn - tokenIn.balanceOf(trade.actor) == trade.amountIn
                && tokenOut.totalSupply() - outSupply == trade.amountOut
                && tokenOut.balanceOf(trade.recipient) - recipientOut == trade.amountOut,
            string.concat(label, " burn and mint")
        );
        _check(_inRange(before.ratio), string.concat(label, " succeeded out of range"));

        uint256 grossBase = Math.mulDiv(trade.amountIn, trade.priceIn, WAD);
        uint256 devFee = reactor.devFee();
        _check(devPaid == Math.mulDiv(Math.mulDiv(grossBase, devFee, WAD), unit, WAD), string.concat(label, " dev fee"));
        _checkBetaFee(before, trade, grossBase, devPaid, label);
        uint256 netBase = Math.mulDiv(grossBase, WAD - trade.feeWad - devFee, WAD);
        _check(_productAtLeast(netBase, WAD, trade.amountOut, trade.priceOut), string.concat(label, " overpaid output"));
        // The reactor mints floor(net * WAD / ceil price). While basePrice * WAD fits in uint256, in-range
        // liabilities sit on the target branch, so ceil and floor liabilities differ by at most 1 and the
        // prices by at most ceil(WAD / supply) + 1. Larger prices take a coarser path, so skip the bound.
        if (before.basePrice <= type(uint256).max / WAD) {
            _check(
                !_productAtLeast(netBase, WAD, trade.amountOut + 1, trade.priceOut + Math.ceilDiv(WAD, outSupply) + 1),
                string.concat(label, " underpaid output")
            );
        }
    }

    // The ledger and fee must match counters the handler decays itself, not values read from the reactor.
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
        // The fee uses the counters before this trade is added.
        _check(
            trade.feeWad == _expectedBetaFee(trade.plus, _normalize(before.reserve), decayedPlus, decayedMinus),
            string.concat(label, " beta fee")
        );
        (ghostVolumePlus, ghostVolumeMinus, ghostVolumeTime) =
        (decayedPlus + (trade.plus ? grossBase : 0), decayedMinus + (trade.plus ? 0 : grossBase), block.timestamp);
    }

    // The counters as the reactor decays them at this timestamp.
    function _decayedVolumes() private view returns (uint256 decayedPlus, uint256 decayedMinus) {
        uint256 decay = reactor.decayPerSecondWad();
        uint256 elapsed = block.timestamp - ghostVolumeTime;
        if (elapsed == 0 || decay == WAD) return (ghostVolumePlus, ghostVolumeMinus);
        uint256 factor = _rpow(decay, elapsed);
        return (Math.mulDiv(ghostVolumePlus, factor, WAD), Math.mulDiv(ghostVolumeMinus, factor, WAD));
    }

    // betaPhi0 + betaPhi1 * net volume in this direction / reserve, rounded up, capped at 100%.
    function _expectedBetaFee(bool plus, uint256 normalizedReserve, uint256 decayedPlus, uint256 decayedMinus)
        private
        view
        returns (uint256)
    {
        (uint256 own, uint256 other) = plus ? (decayedPlus, decayedMinus) : (decayedMinus, decayedPlus);
        uint256 boundedVolume = Math.min(own > other ? own - other : 0, Math.saturatingMul(normalizedReserve, WAD));
        uint256 volumeFee = normalizedReserve == 0
            ? 0
            : Math.mulDiv(reactor.betaPhi1(), boundedVolume, normalizedReserve, Math.Rounding.Ceil);
        return Math.min(reactor.betaPhi0() + volumeFee, WAD);
    }

    // The beta fee a trade would pay now, from the handler's own ledger.
    function _currentBetaFee(Snapshot memory before, bool plus) private view returns (uint256) {
        (uint256 decayedPlus, uint256 decayedMinus) = _decayedVolumes();
        return _expectedBetaFee(plus, _normalize(before.reserve), decayedPlus, decayedMinus);
    }

    // Could the refused trade breach critical? Uses the most Neutrons it could mint and a rounded-down ratio.
    function _betaPlusCanBreachCritical(Snapshot memory before, Trade memory trade) private view returns (bool) {
        uint256 devFee = reactor.devFee();
        uint256 fee = _currentBetaFee(before, true);
        // Both cases stop the trade before this revert, so they mean the handler and reactor disagree.
        if (trade.priceOut == 0 || fee + devFee > WAD) return false;
        uint256 grossBase = Math.mulDiv(trade.amountIn, trade.priceIn, WAD);
        uint256 maxNeutronOut = Math.mulDiv(Math.mulDiv(grossBase, WAD - fee - devFee, WAD), WAD, trade.priceOut);
        uint256 devPaid = Math.mulDiv(Math.mulDiv(grossBase, devFee, WAD), unit, WAD);
        uint256 ratioAfter = Math.mulDiv(
            Math.mulDiv(_normalize(before.reserve - devPaid), before.basePrice, before.neutronSupply + maxNeutronOut),
            reactor.PEG_FACTOR_SCALE(),
            reactor.pegFactor()
        );
        return ratioAfter < reactor.CRITICAL_RESERVE_RATIO();
    }

    // A transmutation may also revert with Panic(0x11) when the beta fee plus the dev fee is above 100%
    // (README: combined rates above 100% revert), but only for a trade that would otherwise run.
    function _checkTransmutationRevert(
        bytes memory reason,
        Snapshot memory before,
        Trade memory trade,
        bytes4 resultReverts
    ) private {
        if (keccak256(reason) == keccak256(abi.encodeWithSignature("Panic(uint256)", 0x11))) {
            _check(
                before.basePrice != 0 && _inRange(before.ratio) && trade.priceIn != 0 && trade.priceOut != 0
                    && _currentBetaFee(before, trade.plus) + reactor.devFee() > WAD,
                "fee overflow revert without full fee"
            );
            return;
        }
        _checkRangeRevert(reason, before, resultReverts);
    }

    // Same rounding as the reactor's _rpow.
    function _rpow(uint256 x, uint256 n) private pure returns (uint256 z) {
        // slither-disable-next-line weak-prng
        z = (n % 2 != 0) ? x : WAD;
        for (n /= 2; n != 0; n /= 2) {
            x = Math.mulDiv(x, x, WAD);
            // slither-disable-next-line weak-prng
            if (n % 2 != 0) z = Math.mulDiv(z, x, WAD);
        }
    }

    function _transmutationTopic(bool plus) private pure returns (bytes32) {
        return plus ? StableCoinReactor.TransmutePlus.selector : StableCoinReactor.TransmuteMinus.selector;
    }

    // Returns whether the trade's event matches it, and the volume counters it reports.
    function _transmutationEvent(Trade memory trade, uint256 devPaid)
        private
        returns (bool found, uint256 volumePlus, uint256 volumeMinus)
    {
        bytes memory data;
        (found, data) = _reactorEvent(_transmutationTopic(trade.plus), trade.actor, trade.recipient);
        if (!found) return (false, 0, 0);
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeWad;
        uint256 devFeeAmount;
        (amountIn, amountOut, feeWad, volumePlus, volumeMinus, devFeeAmount) =
            abi.decode(data, (uint256, uint256, uint256, uint256, uint256, uint256));
        found = amountIn == trade.amountIn && amountOut == trade.amountOut && feeWad == trade.feeWad
            && devFeeAmount == devPaid;
    }

    // Data of the reactor's last recorded event with this topic. When `from` is set, the indexed
    // from and to addresses must match.
    function _reactorEvent(bytes32 topic, address from, address to) private returns (bool found, bytes memory data) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(reactor) || logs[i].topics[0] != topic) continue;
            found = from == address(0)
                || (logs[i].topics[1] == bytes32(uint256(uint160(from)))
                    && logs[i].topics[2] == bytes32(uint256(uint160(to))));
            data = logs[i].data;
        }
    }

    // ReserveRatioOutOfRange must report the ratio seen, and it must be out of range.
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

    function _normalize(uint256 amount) private view returns (uint256) {
        return Math.mulDiv(amount, WAD, unit);
    }

    // a * b >= c * d without overflow.
    function _productAtLeast(uint256 a, uint256 b, uint256 c, uint256 d) private pure returns (bool) {
        (uint256 leftHigh, uint256 leftLow) = Math.mul512(a, b);
        (uint256 rightHigh, uint256 rightLow) = Math.mul512(c, d);
        return leftHigh > rightHigh || (leftHigh == rightHigh && leftLow >= rightLow);
    }

    function _snapshot(address actor, address recipient) private view returns (Snapshot memory) {
        return Snapshot({
            reserve: reactor.reserve(),
            neutronSupply: neutron.totalSupply(),
            protonSupply: proton.totalSupply(),
            devBalance: base.balanceOf(devFeeReceiver),
            actorNeutron: neutron.balanceOf(actor),
            actorProton: proton.balanceOf(actor),
            recipientBase: base.balanceOf(recipient),
            recipientNeutron: neutron.balanceOf(recipient),
            recipientProton: proton.balanceOf(recipient),
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
        // The first four bytes are the custom error selector.
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes4(reason);
    }

    // The uint256 argument after the selector.
    function _revertArgument(bytes memory reason) private pure returns (uint256 value) {
        assembly ("memory-safe") {
            value := mload(add(reason, 36))
        }
    }
}

// Invariants for a factory-deployed reactor. Subcontracts pick decimals and fees.
abstract contract ReactorInvariantBase is Test {
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

    // Base only enters by fission and only leaves as payouts and dev fees.
    function invariant_reserveMatchesTrackedFlows() public view {
        assertEq(base.balanceOf(address(reactor)), handler.ghostBaseIn() - handler.ghostBaseOut());
    }

    function invariant_initialAllocationStaysLocked() public view {
        assertEq(reactor.NEUTRON_TOKEN().balanceOf(address(reactor)), lockedNeutron);
        assertEq(reactor.PROTON_TOKEN().balanceOf(address(reactor)), lockedProton);
    }

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

    function invariant_claimsNeverExceedReserve() public view {
        uint256 claims = reactor.neutronPriceInBase() * reactor.NEUTRON_TOKEN().totalSupply()
            + reactor.protonPriceInBase() * reactor.PROTON_TOKEN().totalSupply();
        assertLe(claims, reactor.reserve() * WAD / unit * WAD);
    }

    // Views must stay consistent for oracle prices up to uint128 max. A zero price is never cached.
    function invariant_pegFactorAndViewsStayUsable() public view {
        assertGt(reactor.pegFactor(), 0);
        assertGt(reactor.lastSuccessfulBasePrice(), 0);
        uint256 ratio = reactor.reserveRatioPeggedAsset();
        assertEq(reactor.qWad(), ratio == 0 ? WAD : Math.min(Math.mulDiv(WAD, WAD, ratio), WAD));
        uint256 basePrice = reactor.getBasePriceInPeggedAsset();
        assertEq(reactor.neutronPriceInPeggedAsset(), Math.mulDiv(reactor.neutronPriceInBase(), basePrice, WAD));
        assertEq(reactor.protonPriceInPeggedAsset(), Math.mulDiv(reactor.protonPriceInBase(), basePrice, WAD));
    }

    function invariant_handlerPropertiesHold() public view {
        assertEq(handler.violation(), "");
        assertEq(handler.unexpectedRevert(), "");
    }
}

// 18 decimals with Gluon's 0.1% dev fee, unequal fission and fusion fees and a fixed beta fee.
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

// 6 decimals, no dev, fission or fusion fees and a beta fee without decay that reaches 100% (zero output).
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract ReactorInvariant6DecimalTest is ReactorInvariantBase {
    function _config() internal pure override returns (Config memory) {
        return Config({
            decimals: 6, devFee: 0, fissionFee: 0, fusionFee: 0, betaPhi0: 5e17, betaPhi1: 1e18, decayPerSecondWad: WAD
        });
    }
}

// 8 decimals with Gluon's dev fee and a high, slowly decaying beta fee that reaches the 100% cap.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract ReactorInvariant8DecimalTest is ReactorInvariantBase {
    function _config() internal pure override returns (Config memory) {
        return Config({
            decimals: 8,
            devFee: 1e15,
            fissionFee: 0,
            fusionFee: 0,
            betaPhi0: 9e17,
            betaPhi1: 1e18,
            decayPerSecondWad: 9999e14
        });
    }
}
