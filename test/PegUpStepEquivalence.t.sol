// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProtocolConstants} from "../src/config/ProtocolConstants.sol";

/// Old and new upward adjustPeg formulas, as external calls so reverts can be compared.
contract PegUpStepFormulas {
    uint256 internal constant WAD = ProtocolConstants.WAD;
    uint256 internal constant UPPER_RESERVE_RATIO = ProtocolConstants.UPPER_RESERVE_RATIO;
    uint256 internal constant PEG_UP_FACTOR_WAD = ProtocolConstants.PEG_UP_FACTOR_WAD;

    function oldUp(uint256 previousPegFactor, uint256 reserveRatio) external pure returns (uint256 pegFactor) {
        pegFactor = Math.mulDiv(previousPegFactor, PEG_UP_FACTOR_WAD, WAD, Math.Rounding.Ceil);
        if (reserveRatio < 2 * UPPER_RESERVE_RATIO) {
            unchecked {
                pegFactor = Math.min(
                    pegFactor,
                    Math.mulDiv(previousPegFactor, reserveRatio + 1, UPPER_RESERVE_RATIO, Math.Rounding.Floor)
                );
            }
        }
    }

    function newUp(uint256 previousPegFactor, uint256 reserveRatio) external pure returns (uint256 pegFactor) {
        pegFactor = previousPegFactor + Math.ceilDiv(previousPegFactor, WAD / (PEG_UP_FACTOR_WAD - WAD));
        if (reserveRatio < 2 * UPPER_RESERVE_RATIO) {
            unchecked {
                pegFactor = Math.min(
                    pegFactor,
                    Math.mulDiv(previousPegFactor, reserveRatio + 1, UPPER_RESERVE_RATIO, Math.Rounding.Floor)
                );
            }
        }
    }
}

contract PegUpStepEquivalenceTest is Test {
    PegUpStepFormulas internal f;

    function setUp() public {
        f = new PegUpStepFormulas();
    }

    function _assertSame(uint256 previousPegFactor, uint256 reserveRatio) internal view {
        (bool okOld, bytes memory outOld) =
            address(f).staticcall(abi.encodeCall(PegUpStepFormulas.oldUp, (previousPegFactor, reserveRatio)));
        (bool okNew, bytes memory outNew) =
            address(f).staticcall(abi.encodeCall(PegUpStepFormulas.newUp, (previousPegFactor, reserveRatio)));
        assertEq(okOld, okNew, "revert mismatch");
        assertEq(outOld, outNew, "result or revert data mismatch");
    }

    /// Any peg and any ratio above 200% (the only inputs the upward branch sees).
    function testFuzz_SameAsOld(uint256 previousPegFactor, uint256 reserveRatio) public view {
        reserveRatio = bound(reserveRatio, UPPER_RESERVE_RATIO_PLUS_ONE, type(uint256).max);
        _assertSame(previousPegFactor, reserveRatio);
    }

    /// Ratios where the 200% cap can bind, with realistic and small pegs.
    function testFuzz_SameAsOldCapRange(uint256 previousPegFactor, uint256 reserveRatio) public view {
        reserveRatio = bound(reserveRatio, UPPER_RESERVE_RATIO_PLUS_ONE, 4e18 + 1);
        previousPegFactor = bound(previousPegFactor, 1, 1e40);
        _assertSame(previousPegFactor, reserveRatio);
    }

    /// Pegs next to the overflow edge, where the step reverts.
    function testFuzz_SameAsOldNearOverflow(uint256 offset, uint256 reserveRatio) public view {
        uint256 edge = type(uint256).max / 101 * 100;
        uint256 previousPegFactor = edge - 1000 + bound(offset, 0, 2000);
        reserveRatio = bound(reserveRatio, UPPER_RESERVE_RATIO_PLUS_ONE, type(uint256).max);
        _assertSame(previousPegFactor, reserveRatio);
    }

    function test_SameAsOldEdges() public view {
        uint256[8] memory pegs = [uint256(0), 1, 99, 100, 101, 1e36, type(uint256).max / 2, type(uint256).max];
        uint256[6] memory ratios = [uint256(2e18 + 1), 202e16 - 1, 202e16, 4e18 - 1, 4e18, type(uint256).max];
        for (uint256 i; i < pegs.length; ++i) {
            for (uint256 j; j < ratios.length; ++j) {
                _assertSame(pegs[i], ratios[j]);
            }
        }
    }

    uint256 internal constant UPPER_RESERVE_RATIO_PLUS_ONE = ProtocolConstants.UPPER_RESERVE_RATIO + 1;
}
