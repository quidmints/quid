// SPDX-License-Identifier: MIT
pragma solidity >=0.8.4 <0.9.0;

/// @title Contains 512-bit math functions
library FullMath {
    uint256 constant FIXED_1 = 0x080000000000000000000000000000000;
    uint256 constant FIXED_2 = 0x100000000000000000000000000000000;
    uint256 constant LOG_E_2 = 6931471806;
    uint256 constant BASE = 1e10;
   
    /// @notice Calculates ceil(a×b÷denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result
    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            result = mulDiv(a, b, denominator);
            if (mulmod(a, b, denominator) != 0) {
                require(++result > 0);
            }
        }
    }
    /// @notice Facilitates multiplication and division that can have overflow of an intermediate value without any loss of precision
    /// calculates floor(a×b÷denominator) with full precision. Throws if result overflows a uint256 or denominator == 0
    /// @param a The multiplicand
    /// @param b The multiplier
    /// @param denominator The divisor
    /// @return result The 256-bit result
    /// @dev Credit to Remco Bloemen under MIT license https://xn--2-umb.com/21/muldiv
    // Handles "phantom overflow" i.e., allows multiplication and division where an intermediate value overflows 256 bits
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            // Compute the product mod 2**256 and mod 2**256 - 1
            // then use the Chinese Remainder Theorem to reconstruct
            // the 512 bit result. The result is stored in two 256
            // variables such that product = prod1 * 2**256 + prod0
            uint256 prod0 = a * b; // Least significant 256 bits of the product
            uint256 prod1; // Most significant 256 bits of the product
            assembly {
                let mm := mulmod(a, b, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Make sure the result is less than 2**256.
            // Also prevents denominator == 0
            require(denominator > prod1);

            // Handle non-overflow cases, 256 by 256 division
            if (prod1 == 0) {
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [prod1 prod0]
            // Compute remainder using mulmod
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
            }
            // Subtract 256 bit number from 512 bit number
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator
            // Compute largest power of two divisor of denominator.
            // Always >= 1.
            uint256 twos = (0 - denominator) & denominator;
            // Divide denominator by power of two
            assembly {
                denominator := div(denominator, twos)
            }

            // Divide [prod1 prod0] by the factors of two
            assembly {
                prod0 := div(prod0, twos)
            }
            // Shift in bits from prod1 into prod0. For this we need
            // to flip `twos` such that it is 2**256 / twos.
            // If twos is zero, then it becomes one
            assembly {
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert denominator mod 2**256
            // Now that denominator is an odd number, it has an inverse
            // modulo 2**256 such that denominator * inv = 1 mod 2**256.
            // Compute the inverse by starting with a seed that is correct
            // correct for four bits. That is, denominator * inv = 1 mod 2**4
            uint256 inv = (3 * denominator) ^ 2;
            // Now use Newton-Raphson iteration to improve the precision.
            // Thanks to Hensel's lifting lemma, this also works in modular
            // arithmetic, doubling the correct bits in each step.
            inv *= 2 - denominator * inv; // inverse mod 2**8
            inv *= 2 - denominator * inv; // inverse mod 2**16
            inv *= 2 - denominator * inv; // inverse mod 2**32
            inv *= 2 - denominator * inv; // inverse mod 2**64
            inv *= 2 - denominator * inv; // inverse mod 2**128
            inv *= 2 - denominator * inv; // inverse mod 2**256

            // Because the division is now exact we can divide by multiplying
            // with the modular inverse of denominator. This will give us the
            // correct result modulo 2**256. Since the preconditions guarantee
            // that the outcome is less than 2**256, this is the final result.
            // We don't need to compute the high bits of the result and prod1
            // is no longer required.
            result = prod0 * inv;
            return result;
        }
    }

    /// @dev Credit to Paul Razvan Berg https://github.com/hifi-finance/prb-math/blob/main/contracts/PRBMath.sol
    function sqrt(uint256 x) internal 
        pure returns (uint256 result) {
        if (x == 0) { return 0; }

        // Set the initial guess to the closest 
        // power of two that is higher than x.
        uint256 xAux = uint256(x); result = 1;
        
        if (xAux >= 0x100000000000000000000000000000000) {
            xAux >>= 128; result <<= 64;
        }
        if (xAux >= 0x10000000000000000) {
            xAux >>= 64; result <<= 32;
        }
        if (xAux >= 0x100000000) {
            xAux >>= 32; result <<= 16;
        }
        if (xAux >= 0x10000) {
            xAux >>= 16; result <<= 8;
        }
        if (xAux >= 0x100) {
            xAux >>= 8; result <<= 4;
        }
        if (xAux >= 0x10) {
            xAux >>= 4; result <<= 2;
        }
        if (xAux >= 0x8) {
            result <<= 1;
        }
        // The operations can never overflow 
        // because the result is max 2^127
        // when it enters this block...
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1;
        result = (result + x / result) >> 1; 
        // Seven iterations should be enough

        uint256 roundedDownResult = x / result;
        
        return result >= roundedDownResult ? 
                         roundedDownResult : result;
    }

    function floorLog2(uint256 _n) 
        internal pure returns (uint8) {
        uint8 res = 0;
        if (_n < 256) {
            // At most 8 iterations
            while (_n > 1) {
                _n >>= 1;
                res += 1;
            }
        } else {
            // Exactly 8 iterations
            for (uint8 s = 128; s > 0; s >>= 1) {
                if (_n >= (uint256(1) << s)) {
                    _n >>= s;
                    res |= s;
                }
            }
        }

        return res;
    }

    /// @dev credit github.com/ribbon-finance/rvol/blob/master/contracts/libraries/Math.sol

    function ln(uint256 x) internal 
        pure returns (uint256) {
        uint256 res = 0;

        // If x >= 2, then we compute the integer part 
        // of log2(x), which is larger than 0.
        if (x >= FIXED_2) {
            uint8 count = floorLog2(x / FIXED_1);
            x >>= count; // now x < 2
            res = count * FIXED_1;
        }
        // If x > 1, then we compute the fraction part 
        // of log2(x), which is larger than 0.
        if (x > FIXED_1) {
            for (uint8 i = 127; i > 0; --i) {
                x = (x * x) / FIXED_1; // now 1 < x < 4
                if (x >= FIXED_2) {
                    x >>= 1; // now 1 < x < 2
                    res += uint256(1) << (i - 1);
                }
            }
        }
        return (res * LOG_E_2) / BASE;
    }

    function max(uint _a, uint _b) internal
        pure returns (uint) { return (_a > _b) ?
                                      _a : _b;
    }
    function min(uint _a, uint _b) internal
        pure returns (uint) { return (_a < _b) ?
                                      _a : _b;
    }   
}
