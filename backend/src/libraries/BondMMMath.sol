// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UD60x18, ud, intoUint256} from "@prb/math/src/UD60x18.sol";

/**
 * @title BondMMMath
 * @notice Mathematical library for BondMM-A protocol calculations
 * @dev All calculations use 18-decimal fixed-point arithmetic via PRBMath's UD60x18
 *
 * Core equations:
 * 1. α = 1/(1 + κt)
 * 2. K = e^(-t·r*·α)
 * 3. p = e^(-rt)
 * 4. r = κ ln(X/y) + r*
 * 5. C = y^α · (X/y + 1)
 * 6. Δy = [C - K(x+Δx)^α]^(1/α) - y
 * 7. Δx = e^(r*t)·y·[(X/y+1-(Δy/y+1)^α)^(1/α)-(X/y)^(1/α)]
 *
 * All inputs/outputs are scaled by 1e18
 */
library BondMMMath {
    using {intoUint256} for UD60x18;

    /// @notice Rate sensitivity parameter: κ = 0.02
    uint256 public constant KAPPA = 20; // Scaled: actual value = 20/1000 = 0.02
    uint256 public constant KAPPA_SCALE = 1000;

    /// @notice One year in seconds
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Minimum time to maturity (prevent division by zero)
    uint256 public constant MIN_TIME = 1 hours;

    /**
     * @notice Calculate α = 1/(1 + κt)
     * @dev α controls the curvature of the bonding curve
     * @param timeToMaturity Time to maturity in seconds
     * @return alpha The calculated alpha value (scaled by 1e18)
     */
    function calculateAlpha(uint256 timeToMaturity) internal pure returns (uint256) {
        require(timeToMaturity >= MIN_TIME, "Time too small");

        // Convert κt to annualized: κ * (t / SECONDS_PER_YEAR)
        // κ = 20/1000 = 0.02
        UD60x18 kappa = ud(KAPPA * 1e18 / KAPPA_SCALE); // 0.02e18

        // Annualized time: t_years = t / SECONDS_PER_YEAR
        UD60x18 tAnnualized = ud(timeToMaturity * 1e18 / SECONDS_PER_YEAR);

        // κt = kappa * tAnnualized
        UD60x18 kappaTimes = kappa.mul(tAnnualized);

        // 1 + κt
        UD60x18 onePlusKappaT = ud(1e18).add(kappaTimes);

        // α = 1 / (1 + κt)
        UD60x18 alpha = ud(1e18).div(onePlusKappaT);

        return alpha.intoUint256();
    }

    /**
     * @notice Calculate K = e^(-t·r*·α)
     * @dev K is a scaling factor in the invariant equation
     * @param timeToMaturity Time to maturity in seconds
     * @param anchorRate The anchor rate r* (scaled by 1e18)
     * @return k The calculated K value (scaled by 1e18)
     */
    function calculateK(uint256 timeToMaturity, uint256 anchorRate) internal pure returns (uint256) {
        require(timeToMaturity >= MIN_TIME, "Time too small");

        // Get α
        uint256 alphaValue = calculateAlpha(timeToMaturity);
        UD60x18 alpha = ud(alphaValue);

        // Annualized time
        UD60x18 tAnnualized = ud(timeToMaturity * 1e18 / SECONDS_PER_YEAR);

        // r* (already in 1e18)
        UD60x18 rStar = ud(anchorRate);

        // Calculate exponent: -t·r*·α
        // exponent = -tAnnualized * rStar * alpha
        UD60x18 exponent = tAnnualized.mul(rStar).mul(alpha);

        // K = e^(-exponent)
        // Since we need negative exponent, we compute 1/e^(exponent)
        UD60x18 expPositive = exponent.exp();
        UD60x18 k = ud(1e18).div(expPositive);

        return k.intoUint256();
    }

    /**
     * @notice Calculate bond price p = e^(-rt)
     * @dev Price represents the discount factor for a bond
     * @param timeToMaturity Time to maturity in seconds
     * @param rate The current interest rate r (scaled by 1e18)
     * @return price The bond price (scaled by 1e18)
     *
     * Note: At maturity (t=0), price = 1.0 (par redemption)
     */
    function calculatePrice(uint256 timeToMaturity, uint256 rate) internal pure returns (uint256) {
        // At maturity, price is exactly 1.0
        if (timeToMaturity == 0) {
            return 1e18;
        }

        require(timeToMaturity >= MIN_TIME, "Time too small");

        // Annualized time
        UD60x18 tAnnualized = ud(timeToMaturity * 1e18 / SECONDS_PER_YEAR);

        // r (already in 1e18)
        UD60x18 r = ud(rate);

        // Calculate exponent: r·t
        UD60x18 exponent = r.mul(tAnnualized);

        // p = e^(-rt) = 1/e^(rt)
        UD60x18 expPositive = exponent.exp();
        UD60x18 price = ud(1e18).div(expPositive);

        return price.intoUint256();
    }

    /**
     * @notice Calculate current interest rate r = κ ln(X/y) + r*
     * @dev Rate function that depends on the ratio of present value bonds to cash
     * @param pvBonds Present value of bonds X (scaled by 1e18)
     * @param cash Cash in pool y (scaled by 1e18)
     * @param anchorRate Anchor rate r* (scaled by 1e18)
     * @return rate The calculated interest rate (scaled by 1e18)
     */
    function calculateRate(uint256 pvBonds, uint256 cash, uint256 anchorRate) internal pure returns (uint256) {
        require(cash > 0, "Cash cannot be zero");
        require(pvBonds > 0, "PV bonds cannot be zero");

        // X/y ratio
        UD60x18 ratio = ud(pvBonds).div(ud(cash));

        // ln(X/y) - PRBMath requires input >= 1e18 for ln()
        // If ratio < 1, ln will be negative, but we need to handle it carefully
        UD60x18 lnRatio;
        bool isNegative = false;

        if (ratio.gte(ud(1e18))) {
            // ratio >= 1: ln(ratio) >= 0
            lnRatio = ratio.ln();
        } else {
            // ratio < 1: ln(ratio) < 0
            // ln(X/y) = -ln(y/X) when X < y
            UD60x18 inverseRatio = ud(cash).div(ud(pvBonds));
            lnRatio = inverseRatio.ln();
            isNegative = true;
        }

        // κ = 0.02
        UD60x18 kappa = ud(KAPPA * 1e18 / KAPPA_SCALE);

        // κ ln(X/y)
        UD60x18 kappaLn = kappa.mul(lnRatio);

        // r* (already in 1e18)
        UD60x18 rStar = ud(anchorRate);

        // r = κ ln(X/y) + r*
        // If ln was negative, subtract instead of add
        UD60x18 rate = isNegative ? rStar.sub(kappaLn) : rStar.add(kappaLn);

        return rate.intoUint256();
    }

    /**
     * @notice Calculate invariant constant C = y^α · (X/y + 1)
     * @dev The constant C must remain unchanged after trades (invariant preservation)
     * @param x Bond face value in pool (scaled by 1e18)
     * @param y Cash in pool (scaled by 1e18)
     * @param timeToMaturity Time to maturity in seconds
     * @param anchorRate Anchor rate r* (scaled by 1e18)
     * @return c The invariant constant C (scaled by 1e18)
     */
    function calculateC(uint256 x, uint256 y, uint256 timeToMaturity, uint256 anchorRate)
        internal
        pure
        returns (uint256)
    {
        require(y > 0, "Cash cannot be zero");
        require(timeToMaturity >= MIN_TIME, "Time too small");

        // Get α
        uint256 alphaValue = calculateAlpha(timeToMaturity);
        UD60x18 alpha = ud(alphaValue);

        // Calculate current price to get X from x
        // For this we need current rate
        // X = x * p = x * e^(-rt)
        uint256 rate = calculateRate(x, y, anchorRate); // Approximation: use x as proxy for X initially
        uint256 price = calculatePrice(timeToMaturity, rate);

        uint256 X = (x * price) / 1e18;

        // X/y ratio
        UD60x18 ratio = ud(X).div(ud(y));

        // X/y + 1
        UD60x18 ratioPlusOne = ratio.add(ud(1e18));

        // y^α
        UD60x18 yPowAlpha = ud(y).pow(alpha);

        // C = y^α · (X/y + 1)
        UD60x18 c = yPowAlpha.mul(ratioPlusOne);

        return c.intoUint256();
    }

    /**
     * @notice Calculate Δy given Δx (cash needed for bond purchase)
     * @dev Implements: Δy = [C - K(x+Δx)^α]^(1/α) - y
     *      Using invariant: K·x^α + y^α = C
     * @param x Current bond face value in pool (scaled by 1e18)
     * @param y Current cash in pool (scaled by 1e18)
     * @param deltaX Change in bond face value (scaled by 1e18)
     * @param timeToMaturity Time to maturity in seconds
     * @param anchorRate Anchor rate r* (scaled by 1e18)
     * @param isPositive True if buying bonds (positive Δx), false if selling
     * @return deltaY The change in cash (scaled by 1e18)
     */
    function calculateDeltaY(
        uint256 x,
        uint256 y,
        uint256 deltaX,
        uint256 timeToMaturity,
        uint256 anchorRate,
        bool isPositive
    ) internal pure returns (uint256) {
        require(y > 0, "Cash cannot be zero");
        require(x > 0, "Bonds cannot be zero");
        require(timeToMaturity >= MIN_TIME, "Time too small");

        // Get α and K
        uint256 alphaValue = calculateAlpha(timeToMaturity);
        uint256 kValue = calculateK(timeToMaturity, anchorRate);

        UD60x18 alpha = ud(alphaValue);
        UD60x18 K = ud(kValue);

        // Calculate invariant C = K·x^α + y^α
        UD60x18 xPowAlpha = ud(x).pow(alpha);
        UD60x18 yPowAlpha = ud(y).pow(alpha);
        UD60x18 C = K.mul(xPowAlpha).add(yPowAlpha);

        // Calculate new x
        uint256 xNew = isPositive ? x + deltaX : (x > deltaX ? x - deltaX : 0);
        require(xNew > 0, "New bond amount must be positive");

        // (xNew)^α
        UD60x18 xNewPowAlpha = ud(xNew).pow(alpha);

        // C - K·(xNew)^α
        UD60x18 kTimesXNew = K.mul(xNewPowAlpha);
        UD60x18 diff = C.gt(kTimesXNew) ? C.sub(kTimesXNew) : kTimesXNew.sub(C);

        // [C - K·(xNew)^α]^(1/α)
        UD60x18 oneOverAlpha = ud(1e18).div(alpha);
        UD60x18 yNew = diff.pow(oneOverAlpha);

        // Δy = yNew - y
        if (yNew.gt(ud(y))) {
            return yNew.sub(ud(y)).intoUint256();
        } else {
            return ud(y).sub(yNew).intoUint256();
        }
    }

    /**
     * @notice Calculate Δx given Δy (bonds received for cash deposited)
     * @dev Implements using invariant: K·x^α + y^α = C
     *      Solves for x given new y
     * @param x Current bond face value in pool (scaled by 1e18)
     * @param y Current cash in pool (scaled by 1e18)
     * @param deltaY Change in cash (scaled by 1e18)
     * @param timeToMaturity Time to maturity in seconds
     * @param anchorRate Anchor rate r* (scaled by 1e18)
     * @param isPositive True if adding cash (lending), false if removing cash
     * @return deltaX The change in bond face value (scaled by 1e18)
     */
    function calculateDeltaX(
        uint256 x,
        uint256 y,
        uint256 deltaY,
        uint256 timeToMaturity,
        uint256 anchorRate,
        bool isPositive
    ) internal pure returns (uint256) {
        require(y > 0, "Cash cannot be zero");
        require(x > 0, "Bonds cannot be zero");
        require(timeToMaturity >= MIN_TIME, "Time too small");

        // Get α and K
        uint256 alphaValue = calculateAlpha(timeToMaturity);
        uint256 kValue = calculateK(timeToMaturity, anchorRate);

        UD60x18 alpha = ud(alphaValue);
        UD60x18 K = ud(kValue);

        // Calculate invariant C = K·x^α + y^α
        UD60x18 xPowAlpha = ud(x).pow(alpha);
        UD60x18 yPowAlpha = ud(y).pow(alpha);
        UD60x18 C = K.mul(xPowAlpha).add(yPowAlpha);

        // Calculate new y
        uint256 yNew = isPositive ? y + deltaY : (y > deltaY ? y - deltaY : 0);
        require(yNew > 0, "New cash amount must be positive");

        // (yNew)^α
        UD60x18 yNewPowAlpha = ud(yNew).pow(alpha);

        // C - (yNew)^α
        UD60x18 diff = C.gt(yNewPowAlpha) ? C.sub(yNewPowAlpha) : yNewPowAlpha.sub(C);

        // [C - (yNew)^α] / K
        UD60x18 quotient = diff.div(K);

        // xNew = [(C - (yNew)^α) / K]^(1/α)
        UD60x18 oneOverAlpha = ud(1e18).div(alpha);
        UD60x18 xNew = quotient.pow(oneOverAlpha);

        // Δx = xNew - x
        if (xNew.gt(ud(x))) {
            return xNew.sub(ud(x)).intoUint256();
        } else {
            return ud(x).sub(xNew).intoUint256();
        }
    }
}
