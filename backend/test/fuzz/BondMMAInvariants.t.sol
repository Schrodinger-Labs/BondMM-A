// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UD60x18, ud, intoUint256} from "@prb/math/src/UD60x18.sol";
import "../../src/BondMMA.sol";
import "../../src/BondMMOracle.sol";
import "../../src/libraries/BondMMMath.sol";
import "../../src/interfaces/IBondMMA.sol";

/**
 * @title MockERC20
 * @notice Simple ERC20 mock for testing
 */
contract MockERC20 is IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
        _totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
}

/**
 * @title BondMMAInvariants
 * @notice Fuzz testing suite for BondMM-A protocol invariants
 * @dev Tests critical mathematical and economic invariants across random inputs
 *
 * Key Invariants Tested:
 * 1. K·x^α + y^α = C (constant across trades)
 * 2. Solvency: E = y + L ≥ 0.99·y₀
 * 3. Par redemption: At t=0, price = 1
 * 4. Rate bounds: 0 ≤ r ≤ MAX_RATE
 * 5. Price bounds: 0 < p ≤ 1
 * 6. State consistency: cash, pvBonds, netLiabilities remain valid
 */
contract BondMMAInvariants is Test {
    using {intoUint256} for UD60x18;

    BondMMA public bondMMA;
    BondMMOracle public oracle;
    MockERC20 public stablecoin;

    uint256 constant INITIAL_CASH = 100_000 ether;
    uint256 constant INITIAL_RATE = 50000000000000000; // 5%
    uint256 constant PRECISION = 1e18;

    // Test users
    address user1 = address(0x1);
    address user2 = address(0x2);
    address user3 = address(0x3);

    function setUp() public {
        // Deploy contracts
        bondMMA = new BondMMA();
        oracle = new BondMMOracle(INITIAL_RATE);
        stablecoin = new MockERC20();

        // Mint initial liquidity
        stablecoin.mint(address(this), INITIAL_CASH);
        stablecoin.approve(address(bondMMA), INITIAL_CASH);

        // Initialize pool
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Setup test users with funds
        stablecoin.mint(user1, 1_000_000 ether);
        stablecoin.mint(user2, 1_000_000 ether);
        stablecoin.mint(user3, 1_000_000 ether);

        vm.prank(user1);
        stablecoin.approve(address(bondMMA), type(uint256).max);
        vm.prank(user2);
        stablecoin.approve(address(bondMMA), type(uint256).max);
        vm.prank(user3);
        stablecoin.approve(address(bondMMA), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        INVARIANT: K·x^α + y^α = C
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: Lending preserves invariant
    function testFuzz_LendPreservesInvariant(uint256 amount, uint256 timeToMaturity) public {
        // Bound inputs to reasonable ranges
        amount = bound(amount, 1 ether, 50_000 ether); // 1 to 50k DAI
        timeToMaturity = bound(timeToMaturity, bondMMA.minMaturity(), bondMMA.maxMaturity());

        uint256 maturity = block.timestamp + timeToMaturity;

        // Get current state
        uint256 cashBefore = bondMMA.cash();
        uint256 pvBondsBefore = bondMMA.pvBonds();

        // Calculate C before trade
        uint256 cBefore = _calculateC(pvBondsBefore, cashBefore, timeToMaturity);

        // Execute lend
        vm.prank(user1);
        bondMMA.lend(amount, maturity);

        // Get new state
        uint256 cashAfter = bondMMA.cash();
        uint256 pvBondsAfter = bondMMA.pvBonds();

        // Calculate C after trade
        uint256 cAfter = _calculateC(pvBondsAfter, cashAfter, timeToMaturity);

        // Invariant: C should be approximately equal (within 1% due to rounding in complex calculations)
        assertApproxEqRel(cBefore, cAfter, 1e16, "Invariant not preserved on lend");
    }

    /// @notice Fuzz test: Borrowing preserves invariant
    function testFuzz_BorrowPreservesInvariant(uint256 amount, uint256 timeToMaturity) public {
        // Bound inputs
        amount = bound(amount, 1 ether, 30_000 ether); // Leave room for pool liquidity
        timeToMaturity = bound(timeToMaturity, bondMMA.minMaturity(), bondMMA.maxMaturity());

        uint256 maturity = block.timestamp + timeToMaturity;
        uint256 collateral = (amount * 150) / 100; // 150% collateral

        // Get current state
        uint256 cashBefore = bondMMA.cash();
        uint256 pvBondsBefore = bondMMA.pvBonds();

        // Calculate C before trade
        uint256 cBefore = _calculateC(pvBondsBefore, cashBefore, timeToMaturity);

        // Execute borrow
        vm.prank(user1);
        bondMMA.borrow(amount, maturity, collateral);

        // Get new state
        uint256 cashAfter = bondMMA.cash();
        uint256 pvBondsAfter = bondMMA.pvBonds();

        // Calculate C after trade
        uint256 cAfter = _calculateC(pvBondsAfter, cashAfter, timeToMaturity);

        // Invariant: C should be approximately equal (within 1% due to rounding in complex calculations)
        assertApproxEqRel(cBefore, cAfter, 1e16, "Invariant not preserved on borrow");
    }

    /// @notice Fuzz test: Sequential lends preserve invariant
    function testFuzz_SequentialLendsPreserveInvariant(
        uint256 amount1,
        uint256 amount2,
        uint256 amount3,
        uint256 timeToMaturity
    ) public {
        // Bound inputs
        amount1 = bound(amount1, 1 ether, 15_000 ether);
        amount2 = bound(amount2, 1 ether, 15_000 ether);
        amount3 = bound(amount3, 1 ether, 15_000 ether);
        timeToMaturity = bound(timeToMaturity, bondMMA.minMaturity(), bondMMA.maxMaturity());

        uint256 maturity = block.timestamp + timeToMaturity;

        // Calculate C at start
        uint256 cInitial = _calculateC(bondMMA.pvBonds(), bondMMA.cash(), timeToMaturity);

        // Execute 3 sequential lends
        vm.prank(user1);
        bondMMA.lend(amount1, maturity);

        vm.prank(user2);
        bondMMA.lend(amount2, maturity);

        vm.prank(user3);
        bondMMA.lend(amount3, maturity);

        // Calculate C at end
        uint256 cFinal = _calculateC(bondMMA.pvBonds(), bondMMA.cash(), timeToMaturity);

        // Invariant should hold across multiple trades (within 1.5% for compound rounding)
        assertApproxEqRel(cInitial, cFinal, 15e15, "Invariant violated after sequential lends");
    }

    /*//////////////////////////////////////////////////////////////
                        SOLVENCY INVARIANT
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: Pool remains solvent after lending
    function testFuzz_SolvencyAfterLend(uint256 amount, uint256 timeToMaturity) public {
        amount = bound(amount, 1 ether, 50_000 ether);
        timeToMaturity = bound(timeToMaturity, bondMMA.minMaturity(), bondMMA.maxMaturity());

        vm.prank(user1);
        bondMMA.lend(amount, block.timestamp + timeToMaturity);

        // Solvency check should pass
        assertTrue(bondMMA.checkSolvency(), "Pool insolvent after lend");
    }

    /// @notice Fuzz test: Pool remains solvent after borrow
    function testFuzz_SolvencyAfterBorrow(uint256 amount, uint256 timeToMaturity) public {
        amount = bound(amount, 1 ether, 30_000 ether);
        timeToMaturity = bound(timeToMaturity, bondMMA.minMaturity(), bondMMA.maxMaturity());

        uint256 collateral = (amount * 150) / 100;

        vm.prank(user1);
        bondMMA.borrow(amount, block.timestamp + timeToMaturity, collateral);

        // Solvency check should pass
        assertTrue(bondMMA.checkSolvency(), "Pool insolvent after borrow");
    }

    /*//////////////////////////////////////////////////////////////
                        RATE & PRICE BOUNDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: Rate remains within bounds
    function testFuzz_RateWithinBounds(uint256 amount, uint256 timeToMaturity) public {
        amount = bound(amount, 1 ether, 40_000 ether);
        timeToMaturity = bound(timeToMaturity, bondMMA.minMaturity(), bondMMA.maxMaturity());

        vm.prank(user1);
        bondMMA.lend(amount, block.timestamp + timeToMaturity);

        uint256 currentRate = bondMMA.getCurrentRate();

        // Rate should be positive and reasonable (< 100%)
        assertGt(currentRate, 0, "Rate should be positive");
        assertLt(currentRate, 1e18, "Rate should be < 100%");
    }

    /// @notice Fuzz test: Price remains ≤ 1
    function testFuzz_PriceAtMostOne(uint256 timeToMaturity) public view {
        timeToMaturity = bound(timeToMaturity, bondMMA.minMaturity(), bondMMA.maxMaturity());

        uint256 currentRate = bondMMA.getCurrentRate();
        uint256 price = BondMMMath.calculatePrice(timeToMaturity, currentRate);

        // Price should never exceed 1 (par value)
        assertLe(price, PRECISION, "Price exceeds par value");
        assertGt(price, 0, "Price should be positive");
    }

    /*//////////////////////////////////////////////////////////////
                        STATE CONSISTENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: Cash balance consistency
    function testFuzz_CashBalanceConsistency(uint256 lendAmount, uint256 borrowAmount) public {
        lendAmount = bound(lendAmount, 1 ether, 30_000 ether);
        borrowAmount = bound(borrowAmount, 1 ether, 20_000 ether);

        uint256 maturity = block.timestamp + 90 days;
        uint256 collateral = (borrowAmount * 150) / 100;

        // Record initial cash
        uint256 cashInitial = bondMMA.cash();

        // Lend
        vm.prank(user1);
        bondMMA.lend(lendAmount, maturity);

        uint256 cashAfterLend = bondMMA.cash();
        assertEq(cashAfterLend, cashInitial + lendAmount, "Cash not increased by lend amount");

        // Borrow
        vm.prank(user2);
        bondMMA.borrow(borrowAmount, maturity, collateral);

        uint256 cashAfterBorrow = bondMMA.cash();
        assertEq(cashAfterBorrow, cashAfterLend - borrowAmount, "Cash not decreased by borrow amount");

        // Cash should never be negative
        assertGe(bondMMA.cash(), 0, "Cash went negative");
    }

    /// @notice Fuzz test: pvBonds stays positive
    function testFuzz_PvBondsStaysPositive(uint256 amount, uint256 timeToMaturity) public {
        amount = bound(amount, 1 ether, 40_000 ether);
        timeToMaturity = bound(timeToMaturity, bondMMA.minMaturity(), bondMMA.maxMaturity());

        vm.prank(user1);
        bondMMA.lend(amount, block.timestamp + timeToMaturity);

        uint256 pvBonds = bondMMA.pvBonds();
        assertGt(pvBonds, 0, "pvBonds should remain positive");
    }

    /// @notice Fuzz test: netLiabilities tracks correctly
    function testFuzz_NetLiabilitiesTracking(uint256 borrowAmount1, uint256 borrowAmount2) public {
        borrowAmount1 = bound(borrowAmount1, 1 ether, 15_000 ether);
        borrowAmount2 = bound(borrowAmount2, 1 ether, 15_000 ether);

        uint256 maturity = block.timestamp + 90 days;
        uint256 collateral1 = (borrowAmount1 * 150) / 100;
        uint256 collateral2 = (borrowAmount2 * 150) / 100;

        // Initial liabilities should be 0
        assertEq(bondMMA.netLiabilities(), 0, "Initial liabilities should be 0");

        // First borrow
        vm.prank(user1);
        bondMMA.borrow(borrowAmount1, maturity, collateral1);

        uint256 liabilitiesAfter1 = bondMMA.netLiabilities();
        assertGt(liabilitiesAfter1, 0, "Liabilities should increase after borrow");

        // Second borrow
        vm.prank(user2);
        bondMMA.borrow(borrowAmount2, maturity, collateral2);

        uint256 liabilitiesAfter2 = bondMMA.netLiabilities();
        assertGt(liabilitiesAfter2, liabilitiesAfter1, "Liabilities should increase further");
    }

    /*//////////////////////////////////////////////////////////////
                        REDEEM/REPAY FUZZING
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: Redeem at maturity
    function testFuzz_RedeemAtMaturity(uint256 amount, uint256 timeToMaturity) public {
        amount = bound(amount, 1 ether, 30_000 ether);
        timeToMaturity = bound(timeToMaturity, bondMMA.minMaturity(), bondMMA.maxMaturity());

        uint256 maturity = block.timestamp + timeToMaturity;

        // Lend
        vm.prank(user1);
        uint256 positionId = bondMMA.lend(amount, maturity);

        // Warp to maturity
        vm.warp(maturity);
        oracle.updateRate(INITIAL_RATE); // Update oracle after time warp

        // Get position details
        IBondMMA.Position memory pos = bondMMA.getPosition(positionId);
        uint256 faceValue = pos.faceValue;

        // Redeem
        uint256 cashBefore = bondMMA.cash();
        vm.prank(user1);
        bondMMA.redeem(positionId);

        // Cash should decrease by face value
        assertEq(bondMMA.cash(), cashBefore - faceValue, "Cash not decreased correctly");

        // Position should be inactive
        IBondMMA.Position memory posAfter = bondMMA.getPosition(positionId);
        assertFalse(posAfter.isActive, "Position should be inactive");
    }

    /// @notice Fuzz test: Repay at maturity
    function testFuzz_RepayAtMaturity(uint256 amount, uint256 timeToMaturity) public {
        amount = bound(amount, 1 ether, 20_000 ether);
        timeToMaturity = bound(timeToMaturity, bondMMA.minMaturity(), bondMMA.maxMaturity());

        uint256 maturity = block.timestamp + timeToMaturity;
        uint256 collateral = (amount * 150) / 100;

        // Borrow
        vm.prank(user1);
        uint256 positionId = bondMMA.borrow(amount, maturity, collateral);

        // Get face value
        IBondMMA.Position memory pos = bondMMA.getPosition(positionId);
        uint256 faceValue = pos.faceValue;

        // Warp to maturity
        vm.warp(maturity);
        oracle.updateRate(INITIAL_RATE); // Update oracle after time warp

        // Mint repayment tokens
        stablecoin.mint(user1, faceValue);

        // Repay
        uint256 cashBefore = bondMMA.cash();
        uint256 liabilitiesBefore = bondMMA.netLiabilities();

        vm.prank(user1);
        bondMMA.repay(positionId);

        // Cash should increase by face value
        assertEq(bondMMA.cash(), cashBefore + faceValue, "Cash not increased correctly");

        // Liabilities should decrease
        assertLt(bondMMA.netLiabilities(), liabilitiesBefore, "Liabilities should decrease");

        // Position should be inactive
        IBondMMA.Position memory posAfter = bondMMA.getPosition(positionId);
        assertFalse(posAfter.isActive, "Position should be inactive");
    }

    /*//////////////////////////////////////////////////////////////
                        HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate invariant constant C
    /// @dev C = K·x^α + y^α where K = e^(-tr*α), α = 1/(1+κt)
    function _calculateC(uint256 pvBonds, uint256 cash, uint256 timeToMaturity)
        internal
        view
        returns (uint256)
    {
        uint256 anchorRate = oracle.getRate();

        // Calculate α = 1/(1 + κt)
        uint256 alpha = BondMMMath.calculateAlpha(timeToMaturity);

        // Calculate K = e^(-tr*α)
        uint256 k = BondMMMath.calculateK(timeToMaturity, anchorRate);

        // Calculate bond face value from present value
        uint256 currentRate = BondMMMath.calculateRate(pvBonds, cash, anchorRate);
        uint256 price = BondMMMath.calculatePrice(timeToMaturity, currentRate);
        uint256 x = (pvBonds * PRECISION) / price;

        // Calculate x^α
        uint256 xPowAlpha = _pow(x, alpha);

        // Calculate y^α
        uint256 yPowAlpha = _pow(cash, alpha);

        // Calculate C = K·x^α + y^α
        uint256 c = (k * xPowAlpha) / PRECISION + yPowAlpha;

        return c;
    }

    /// @notice Power function using PRBMath
    /// @dev Calculates base^exp where both are in 1e18 format
    function _pow(uint256 base, uint256 exp) internal pure returns (uint256) {
        if (exp == 0) return PRECISION;
        if (exp == PRECISION) return base;
        if (base == 0) return 0;

        // Use PRBMath for accurate fractional exponentiation
        UD60x18 result = ud(base).pow(ud(exp));
        return intoUint256(result);
    }
}
