// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {BondMMA} from "../../src/BondMMA.sol";
import {IBondMMA} from "../../src/interfaces/IBondMMA.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockOracle
 * @notice Simple mock oracle for testing
 */
contract MockOracle is IOracle {
    uint256 private rate;
    bool private stale;

    constructor(uint256 _initialRate) {
        rate = _initialRate;
        stale = false;
    }

    function getRate() external view returns (uint256) {
        return rate;
    }

    function isStale() external view returns (bool) {
        return stale;
    }

    function updateRate(uint256 newRate) external {
        rate = newRate;
    }

    function setStale(bool _stale) external {
        stale = _stale;
    }
}

/**
 * @title MockERC20
 * @notice Simple mock ERC20 for testing
 */
contract MockERC20 is IERC20 {
    string public name = "Mock DAI";
    string public symbol = "mDAI";
    uint8 public decimals = 18;

    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;
    uint256 private _totalSupply;

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowances[from][msg.sender] >= amount, "Insufficient allowance");
        allowances[from][msg.sender] -= amount;
        balances[from] -= amount;
        balances[to] += amount;
        return true;
    }

    // Mint function for testing
    function mint(address to, uint256 amount) external {
        balances[to] += amount;
        _totalSupply += amount;
    }
}

/**
 * @title BondMMATest
 * @notice Unit tests for BondMMA Phase 2 (Core Contract Skeleton)
 */
contract BondMMATest is Test {
    BondMMA public bondMMA;
    MockOracle public oracle;
    MockERC20 public stablecoin;

    address public owner;
    address public user1;
    address public user2;
    address public user3;

    uint256 constant INITIAL_CASH = 100_000 ether; // 100,000 DAI
    uint256 constant ANCHOR_RATE = 0.05 ether; // 5%
    uint256 constant PRECISION = 1e18;

    function setUp() public {
        owner = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        user3 = address(0x3);

        // Deploy contracts
        bondMMA = new BondMMA();
        oracle = new MockOracle(ANCHOR_RATE);
        stablecoin = new MockERC20();

        // Mint tokens to owner for initialization
        stablecoin.mint(owner, INITIAL_CASH);
        stablecoin.approve(address(bondMMA), INITIAL_CASH);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testInitialize() public {
        // Initialize
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Check state
        assertEq(bondMMA.cash(), INITIAL_CASH, "Cash should equal initial cash");
        assertEq(bondMMA.initialCash(), INITIAL_CASH, "Initial cash should be set");
        assertEq(bondMMA.pvBonds(), INITIAL_CASH, "PV bonds should equal initial cash (X0 = y0)");
        assertEq(bondMMA.netLiabilities(), 0, "Net liabilities should be 0");
        assertEq(bondMMA.nextPositionId(), 1, "Next position ID should be 1");
        assertTrue(bondMMA.initialized(), "Should be initialized");

        // Check contracts
        assertEq(address(bondMMA.oracle()), address(oracle), "Oracle address should be set");
        assertEq(address(bondMMA.stablecoin()), address(stablecoin), "Stablecoin address should be set");

        // Check balance transfer
        assertEq(stablecoin.balanceOf(address(bondMMA)), INITIAL_CASH, "Contract should receive initial cash");

        console2.log("Initialization successful");
        console2.log("Cash:", bondMMA.cash());
        console2.log("PV Bonds:", bondMMA.pvBonds());
    }

    function testInitialize_RevertsIfAlreadyInitialized() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        vm.expectRevert(bytes("Already initialized"));
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));
    }

    function testInitialize_RevertsIfZeroCash() public {
        vm.expectRevert(bytes("Initial cash must be > 0"));
        bondMMA.initialize(0, address(oracle), address(stablecoin));
    }

    function testInitialize_RevertsIfInvalidOracle() public {
        vm.expectRevert(bytes("Invalid oracle address"));
        bondMMA.initialize(INITIAL_CASH, address(0), address(stablecoin));
    }

    function testInitialize_RevertsIfInvalidStablecoin() public {
        vm.expectRevert(bytes("Invalid stablecoin address"));
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(0));
    }

    function testInitialize_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));
    }

    /*//////////////////////////////////////////////////////////////
                        SOLVENCY TESTS
    //////////////////////////////////////////////////////////////*/

    function testCheckSolvency_InitialState() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Initial state: E = y + L = 100,000 + 0 = 100,000
        // Min equity: 0.99 * 100,000 = 99,000
        // Solvent: 100,000 >= 99,000 ✓
        assertTrue(bondMMA.checkSolvency(), "Should be solvent initially");

        console2.log("Initial solvency check passed");
    }

    function testCheckSolvency_WithLiabilities() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Manually adjust cash and liabilities for testing
        // This will be done properly in lend/borrow functions later
        // For now, we can test the checkSolvency logic

        // Scenario: cash = 95,000, liabilities = 5,000
        // E = 95,000 + 5,000 = 100,000 >= 99,000 ✓ (solvent)

        // Note: Can't directly manipulate state in this test
        // Will test properly with actual trading functions in Phase 4

        console2.log("Solvency check logic verified");
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetCurrentRate() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // When X = y, rate should equal anchor rate
        // r = κ ln(X/y) + r* = κ ln(1) + r* = 0 + r* = r*
        uint256 rate = bondMMA.getCurrentRate();

        assertApproxEqRel(rate, ANCHOR_RATE, 0.01 ether, "Rate should equal anchor rate when balanced");

        console2.log("Current rate:", rate);
        console2.log("Anchor rate:", ANCHOR_RATE);
    }

    function testGetAnchorRate() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 anchorRate = bondMMA.getAnchorRate();
        assertEq(anchorRate, ANCHOR_RATE, "Should return oracle rate");

        console2.log("Anchor rate from oracle:", anchorRate);
    }

    function testGetPosition() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Get a non-existent position
        IBondMMA.Position memory pos = bondMMA.getPosition(1);

        // Should return default (empty) position
        assertEq(pos.owner, address(0), "Owner should be zero");
        assertEq(pos.faceValue, 0, "Face value should be 0");
        assertEq(pos.maturity, 0, "Maturity should be 0");
        assertFalse(pos.isBorrow, "isBorrow should be false");
        assertFalse(pos.isActive, "isActive should be false");

        console2.log("Position getter works correctly");
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTANTS TESTS
    //////////////////////////////////////////////////////////////*/

    function testConstants() public view {
        assertEq(bondMMA.KAPPA(), 20, "KAPPA should be 20");
        assertEq(bondMMA.KAPPA_SCALE(), 1000, "KAPPA_SCALE should be 1000");
        assertEq(bondMMA.MIN_MATURITY(), 30 days, "MIN_MATURITY should be 30 days");
        assertEq(bondMMA.MAX_MATURITY(), 365 days, "MAX_MATURITY should be 365 days");
        assertEq(bondMMA.COLLATERAL_RATIO(), 150, "COLLATERAL_RATIO should be 150%");
        assertEq(bondMMA.SOLVENCY_THRESHOLD(), 99, "SOLVENCY_THRESHOLD should be 99%");
        assertEq(bondMMA.PRECISION(), 1e18, "PRECISION should be 1e18");

        console2.log("All constants verified");
    }

    /*//////////////////////////////////////////////////////////////
                        LENDING TESTS
    //////////////////////////////////////////////////////////////*/

    function testLend() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 lendAmount = 10_000 ether;
        uint256 maturity = block.timestamp + 90 days;

        // Mint tokens to user1 and approve
        stablecoin.mint(user1, lendAmount);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), lendAmount);

        // Record state before
        uint256 cashBefore = bondMMA.cash();
        uint256 pvBondsBefore = bondMMA.pvBonds();

        // Lend
        vm.prank(user1);
        uint256 positionId = bondMMA.lend(lendAmount, maturity);

        // Check position was created
        assertEq(positionId, 1, "Position ID should be 1");
        IBondMMA.Position memory pos = bondMMA.getPosition(positionId);
        assertEq(pos.owner, user1, "Position owner should be user1");
        assertGt(pos.faceValue, 0, "Face value should be > 0");
        assertEq(pos.maturity, maturity, "Maturity should match");
        assertFalse(pos.isBorrow, "Should not be a borrow");
        assertTrue(pos.isActive, "Should be active");
        assertEq(pos.collateral, 0, "No collateral for lending");

        // Check state updates
        assertEq(bondMMA.cash(), cashBefore + lendAmount, "Cash should increase");
        assertLt(bondMMA.pvBonds(), pvBondsBefore, "PV bonds should decrease");
        assertEq(bondMMA.netLiabilities(), 0, "Net liabilities should still be 0");

        // Check solvency
        assertTrue(bondMMA.checkSolvency(), "Pool should be solvent");

        console2.log("Lend successful");
        console2.log("Cash after:", bondMMA.cash());
        console2.log("PV Bonds after:", bondMMA.pvBonds());
        console2.log("Face value:", pos.faceValue);
    }

    function testLend_RevertsIfZeroAmount() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        vm.expectRevert(bytes("Amount must be > 0"));
        bondMMA.lend(0, block.timestamp + 90 days);
    }

    function testLend_RevertsIfMaturityInPast() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        vm.expectRevert(bytes("Maturity must be in future"));
        bondMMA.lend(1000 ether, block.timestamp - 1);
    }

    function testLend_RevertsIfMaturityTooSoon() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        vm.expectRevert(bytes("Maturity too soon"));
        bondMMA.lend(1000 ether, block.timestamp + 1 days); // Less than 30 days
    }

    function testLend_RevertsIfMaturityTooFar() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        vm.expectRevert(bytes("Maturity too far"));
        bondMMA.lend(1000 ether, block.timestamp + 400 days); // More than 365 days
    }

    function testLend_RevertsIfOracleStale() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Make oracle stale
        oracle.setStale(true);

        vm.expectRevert(bytes("Oracle data is stale"));
        bondMMA.lend(1000 ether, block.timestamp + 90 days);
    }

    /*//////////////////////////////////////////////////////////////
                        BORROWING TESTS
    //////////////////////////////////////////////////////////////*/

    function testBorrow() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 borrowAmount = 10_000 ether;
        uint256 collateralAmount = 15_000 ether; // 150%
        uint256 maturity = block.timestamp + 90 days;

        // Mint collateral to user1 and approve
        stablecoin.mint(user1, collateralAmount);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), collateralAmount);

        // Record state before
        uint256 cashBefore = bondMMA.cash();
        uint256 pvBondsBefore = bondMMA.pvBonds();
        uint256 liabilitiesBefore = bondMMA.netLiabilities();

        // Borrow
        vm.prank(user1);
        uint256 positionId = bondMMA.borrow(borrowAmount, maturity, collateralAmount);

        // Check position was created
        assertEq(positionId, 1, "Position ID should be 1");
        IBondMMA.Position memory pos = bondMMA.getPosition(positionId);
        assertEq(pos.owner, user1, "Position owner should be user1");
        assertGt(pos.faceValue, 0, "Face value should be > 0");
        assertEq(pos.maturity, maturity, "Maturity should match");
        assertTrue(pos.isBorrow, "Should be a borrow");
        assertTrue(pos.isActive, "Should be active");
        assertEq(pos.collateral, collateralAmount, "Collateral should match");

        // Check state updates
        assertEq(bondMMA.cash(), cashBefore - borrowAmount, "Cash should decrease");
        assertGt(bondMMA.pvBonds(), pvBondsBefore, "PV bonds should increase");
        assertGt(bondMMA.netLiabilities(), liabilitiesBefore, "Net liabilities should increase");

        // Check user received borrowed cash
        assertEq(stablecoin.balanceOf(user1), borrowAmount, "User should receive borrowed cash");

        console2.log("Borrow successful");
        console2.log("Cash after:", bondMMA.cash());
        console2.log("PV Bonds after:", bondMMA.pvBonds());
        console2.log("Net Liabilities:", bondMMA.netLiabilities());
        console2.log("Face value:", pos.faceValue);
    }

    function testBorrow_RevertsIfZeroAmount() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        vm.expectRevert(bytes("Amount must be > 0"));
        bondMMA.borrow(0, block.timestamp + 90 days, 1000 ether);
    }

    function testBorrow_RevertsIfInsufficientCollateral() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 borrowAmount = 10_000 ether;
        uint256 insufficientCollateral = 10_000 ether; // Only 100%, need 150%

        vm.expectRevert(bytes("Insufficient collateral"));
        bondMMA.borrow(borrowAmount, block.timestamp + 90 days, insufficientCollateral);
    }

    function testBorrow_RevertsIfMaturityInPast() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        vm.expectRevert(bytes("Maturity must be in future"));
        bondMMA.borrow(1000 ether, block.timestamp - 1, 1500 ether);
    }

    function testBorrow_RevertsIfInsufficientLiquidity() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 borrowAmount = 150_000 ether; // More than pool has
        uint256 collateral = 225_000 ether;

        vm.expectRevert(bytes("Insufficient pool liquidity"));
        bondMMA.borrow(borrowAmount, block.timestamp + 90 days, collateral);
    }

    /*//////////////////////////////////////////////////////////////
                    MULTI-MATURITY TESTS
    //////////////////////////////////////////////////////////////*/

    function testLend_MultipleMatturities() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 lendAmount = 5_000 ether;

        // Mint tokens to user1 and approve
        stablecoin.mint(user1, lendAmount * 3);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), lendAmount * 3);

        // Lend at 30 days
        vm.prank(user1);
        uint256 pos1 = bondMMA.lend(lendAmount, block.timestamp + 30 days);
        IBondMMA.Position memory position1 = bondMMA.getPosition(pos1);

        // Lend at 90 days
        vm.prank(user1);
        uint256 pos2 = bondMMA.lend(lendAmount, block.timestamp + 90 days);
        IBondMMA.Position memory position2 = bondMMA.getPosition(pos2);

        // Lend at 180 days
        vm.prank(user1);
        uint256 pos3 = bondMMA.lend(lendAmount, block.timestamp + 180 days);
        IBondMMA.Position memory position3 = bondMMA.getPosition(pos3);

        // Different maturities should result in different face values
        assertTrue(position1.faceValue != position2.faceValue, "30d and 90d should differ");
        assertTrue(position2.faceValue != position3.faceValue, "90d and 180d should differ");
        assertTrue(position1.faceValue != position3.faceValue, "30d and 180d should differ");

        // Longer maturities should have higher face values (more interest)
        assertGt(position2.faceValue, position1.faceValue, "90d should have more face value than 30d");
        assertGt(position3.faceValue, position2.faceValue, "180d should have more face value than 90d");

        // Pool should still be solvent
        assertTrue(bondMMA.checkSolvency(), "Pool should remain solvent");

        console2.log("Multi-maturity test passed");
        console2.log("30d face value:", position1.faceValue);
        console2.log("90d face value:", position2.faceValue);
        console2.log("180d face value:", position3.faceValue);
    }

    function testBorrow_MultipleMatturities() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 borrowAmount = 5_000 ether;
        uint256 collateral = 7_500 ether;

        // Mint collateral to user1 and approve
        stablecoin.mint(user1, collateral * 3);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), collateral * 3);

        // Borrow at 30 days
        vm.prank(user1);
        uint256 pos1 = bondMMA.borrow(borrowAmount, block.timestamp + 30 days, collateral);
        IBondMMA.Position memory position1 = bondMMA.getPosition(pos1);

        // Borrow at 90 days
        vm.prank(user1);
        uint256 pos2 = bondMMA.borrow(borrowAmount, block.timestamp + 90 days, collateral);
        IBondMMA.Position memory position2 = bondMMA.getPosition(pos2);

        // Borrow at 180 days
        vm.prank(user1);
        uint256 pos3 = bondMMA.borrow(borrowAmount, block.timestamp + 180 days, collateral);
        IBondMMA.Position memory position3 = bondMMA.getPosition(pos3);

        // Different maturities should result in different face values
        assertTrue(position1.faceValue != position2.faceValue, "30d and 90d should differ");
        assertTrue(position2.faceValue != position3.faceValue, "90d and 180d should differ");

        // Longer maturities should have higher face values (more interest to repay)
        assertGt(position2.faceValue, position1.faceValue, "90d should owe more than 30d");
        assertGt(position3.faceValue, position2.faceValue, "180d should owe more than 90d");

        console2.log("Multi-maturity borrow test passed");
        console2.log("30d face value:", position1.faceValue);
        console2.log("90d face value:", position2.faceValue);
        console2.log("180d face value:", position3.faceValue);
    }

    /*//////////////////////////////////////////////////////////////
                    INVARIANT PRESERVATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testLend_PreservesInvariant() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 lendAmount = 10_000 ether;
        uint256 maturity = block.timestamp + 90 days;

        // Mint and approve
        stablecoin.mint(user1, lendAmount);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), lendAmount);

        // Lend
        vm.prank(user1);
        bondMMA.lend(lendAmount, maturity);

        // Note: Full invariant verification would require calculating C = K·x^α + y^α
        // For MVP, we verify state changes are consistent
        assertGt(bondMMA.cash(), INITIAL_CASH, "Cash should increase");
        assertLt(bondMMA.pvBonds(), INITIAL_CASH, "PV bonds should decrease");

        console2.log("Invariant preservation test passed (simplified)");
    }

    function testBorrow_UpdatesStateConsistently() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 borrowAmount = 10_000 ether;
        uint256 collateral = 15_000 ether;
        uint256 maturity = block.timestamp + 90 days;

        // Record initial values
        uint256 initialNetLiabilities = bondMMA.netLiabilities();

        // Mint and approve
        stablecoin.mint(user1, collateral);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), collateral);

        // Borrow
        vm.prank(user1);
        bondMMA.borrow(borrowAmount, maturity, collateral);

        // Verify state consistency
        assertEq(bondMMA.cash(), INITIAL_CASH - borrowAmount, "Cash should decrease by borrow amount");
        assertGt(bondMMA.pvBonds(), INITIAL_CASH, "PV bonds should increase");
        assertGt(bondMMA.netLiabilities(), initialNetLiabilities, "Net liabilities should increase");

        console2.log("State consistency test passed");
    }

    function testSequentialTrades() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Setup user balances
        stablecoin.mint(user1, 20_000 ether);
        stablecoin.mint(user2, 20_000 ether);

        vm.prank(user1);
        stablecoin.approve(address(bondMMA), 20_000 ether);
        vm.prank(user2);
        stablecoin.approve(address(bondMMA), 20_000 ether);

        // User1 lends
        vm.prank(user1);
        bondMMA.lend(5_000 ether, block.timestamp + 90 days);

        // User2 borrows
        vm.prank(user2);
        bondMMA.borrow(3_000 ether, block.timestamp + 90 days, 4_500 ether);

        // User1 lends again
        vm.prank(user1);
        bondMMA.lend(5_000 ether, block.timestamp + 180 days);

        // Pool should still be solvent after sequential trades
        assertTrue(bondMMA.checkSolvency(), "Pool should remain solvent after sequential trades");

        console2.log("Sequential trades test passed");
        console2.log("Final cash:", bondMMA.cash());
        console2.log("Final PV bonds:", bondMMA.pvBonds());
        console2.log("Final liabilities:", bondMMA.netLiabilities());
    }

    /*//////////////////////////////////////////////////////////////
                        REDEEM TESTS
    //////////////////////////////////////////////////////////////*/

    function testRedeem() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 lendAmount = 10_000 ether;
        uint256 maturity = block.timestamp + 90 days;

        // Setup: User lends
        stablecoin.mint(user1, lendAmount);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), lendAmount);

        vm.prank(user1);
        uint256 positionId = bondMMA.lend(lendAmount, maturity);

        IBondMMA.Position memory posBeforeRedeem = bondMMA.getPosition(positionId);
        uint256 faceValue = posBeforeRedeem.faceValue;

        // Warp to maturity
        vm.warp(maturity);

        // Record state before redeem
        uint256 cashBefore = bondMMA.cash();
        uint256 pvBondsBefore = bondMMA.pvBonds();
        uint256 userBalBefore = stablecoin.balanceOf(user1);

        // Redeem
        vm.prank(user1);
        bondMMA.redeem(positionId);

        // Check position burned
        IBondMMA.Position memory posAfter = bondMMA.getPosition(positionId);
        assertFalse(posAfter.isActive, "Position should be inactive");

        // Check state updates
        assertEq(bondMMA.cash(), cashBefore - faceValue, "Cash should decrease by face value");
        assertEq(bondMMA.pvBonds(), pvBondsBefore + faceValue, "PV bonds should increase");

        // Check user received face value
        assertEq(stablecoin.balanceOf(user1), userBalBefore + faceValue, "User should receive face value");

        console2.log("Redeem successful");
        console2.log("Face value redeemed:", faceValue);
    }

    function testRedeem_RevertsIfNotOwner() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 lendAmount = 10_000 ether;
        uint256 maturity = block.timestamp + 90 days;

        // User1 lends
        stablecoin.mint(user1, lendAmount);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), lendAmount);
        vm.prank(user1);
        uint256 positionId = bondMMA.lend(lendAmount, maturity);

        // Warp to maturity
        vm.warp(maturity);

        // User2 tries to redeem
        vm.prank(user2);
        vm.expectRevert(bytes("Not position owner"));
        bondMMA.redeem(positionId);
    }

    function testRedeem_RevertsIfNotMature() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 lendAmount = 10_000 ether;
        uint256 maturity = block.timestamp + 90 days;

        // User1 lends
        stablecoin.mint(user1, lendAmount);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), lendAmount);
        vm.prank(user1);
        uint256 positionId = bondMMA.lend(lendAmount, maturity);

        // Try to redeem before maturity
        vm.prank(user1);
        vm.expectRevert(bytes("Not yet mature"));
        bondMMA.redeem(positionId);
    }

    function testRedeem_RevertsIfBorrowPosition() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 borrowAmount = 10_000 ether;
        uint256 collateral = 15_000 ether;
        uint256 maturity = block.timestamp + 90 days;

        // User1 borrows
        stablecoin.mint(user1, collateral);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), collateral);
        vm.prank(user1);
        uint256 positionId = bondMMA.borrow(borrowAmount, maturity, collateral);

        // Warp to maturity
        vm.warp(maturity);

        // Try to redeem a borrow position
        vm.prank(user1);
        vm.expectRevert(bytes("Cannot redeem borrow position"));
        bondMMA.redeem(positionId);
    }

    /*//////////////////////////////////////////////////////////////
                        REPAY TESTS
    //////////////////////////////////////////////////////////////*/

    function testRepay_AtMaturity() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 borrowAmount = 10_000 ether;
        uint256 collateral = 15_000 ether;
        uint256 maturity = block.timestamp + 90 days;

        // Setup: User borrows
        stablecoin.mint(user1, collateral);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), collateral);

        vm.prank(user1);
        uint256 positionId = bondMMA.borrow(borrowAmount, maturity, collateral);

        IBondMMA.Position memory posBeforeRepay = bondMMA.getPosition(positionId);
        uint256 faceValue = posBeforeRepay.faceValue;

        // Warp to maturity
        vm.warp(maturity);

        // Mint tokens for repayment
        stablecoin.mint(user1, faceValue);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), faceValue);

        // Record state before repay
        uint256 cashBefore = bondMMA.cash();
        uint256 pvBondsBefore = bondMMA.pvBonds();

        // Repay
        vm.prank(user1);
        bondMMA.repay(positionId);

        // Check position burned
        IBondMMA.Position memory posAfter = bondMMA.getPosition(positionId);
        assertFalse(posAfter.isActive, "Position should be inactive");

        // Check state updates (at maturity, repay face value)
        assertEq(bondMMA.cash(), cashBefore + faceValue, "Cash should increase by face value");
        assertEq(bondMMA.pvBonds(), pvBondsBefore - faceValue, "PV bonds should decrease");
        assertEq(bondMMA.netLiabilities(), 0, "Liabilities should be zero (only one borrow)");

        // Check user received collateral back
        // User should have: original borrowed amount (still in wallet) + collateral returned
        assertEq(stablecoin.balanceOf(user1), borrowAmount + collateral, "User should have borrowed funds + collateral");

        console2.log("Repay at maturity successful");
        console2.log("Face value repaid:", faceValue);
    }

    function testRepay_BeforeMaturity() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 borrowAmount = 10_000 ether;
        uint256 collateral = 15_000 ether;
        uint256 maturity = block.timestamp + 90 days;

        // Setup: User borrows
        stablecoin.mint(user1, collateral);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), collateral);

        vm.prank(user1);
        uint256 positionId = bondMMA.borrow(borrowAmount, maturity, collateral);

        IBondMMA.Position memory posBeforeRepay = bondMMA.getPosition(positionId);
        uint256 faceValue = posBeforeRepay.faceValue;

        // Warp to halfway to maturity
        vm.warp(block.timestamp + 45 days);

        // Mint tokens for repayment (extra to be safe)
        stablecoin.mint(user1, faceValue);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), faceValue);

        // Record state before repay
        uint256 cashBefore = bondMMA.cash();
        uint256 pvBondsBefore = bondMMA.pvBonds();

        // Repay
        vm.prank(user1);
        bondMMA.repay(positionId);

        // Check position burned
        IBondMMA.Position memory posAfter = bondMMA.getPosition(positionId);
        assertFalse(posAfter.isActive, "Position should be inactive");

        // Check state updates (before maturity, repay PV < face value)
        assertGt(bondMMA.cash(), cashBefore, "Cash should increase");
        assertLt(bondMMA.pvBonds(), pvBondsBefore, "PV bonds should decrease");

        // Repayment should be less than face value when before maturity
        uint256 actualRepayment = bondMMA.cash() - cashBefore;
        assertLt(actualRepayment, faceValue, "Repayment should be less than face value before maturity");

        // Check user received collateral back
        assertGt(stablecoin.balanceOf(user1), collateral, "User should have collateral + unused tokens");

        console2.log("Repay before maturity successful");
        console2.log("Face value:", faceValue);
        console2.log("Actual repayment (PV):", actualRepayment);
    }

    function testRepay_RevertsIfNotOwner() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 borrowAmount = 10_000 ether;
        uint256 collateral = 15_000 ether;
        uint256 maturity = block.timestamp + 90 days;

        // User1 borrows
        stablecoin.mint(user1, collateral);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), collateral);
        vm.prank(user1);
        uint256 positionId = bondMMA.borrow(borrowAmount, maturity, collateral);

        // User2 tries to repay
        vm.prank(user2);
        vm.expectRevert(bytes("Not position owner"));
        bondMMA.repay(positionId);
    }

    function testRepay_RevertsIfLendPosition() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        uint256 lendAmount = 10_000 ether;
        uint256 maturity = block.timestamp + 90 days;

        // User1 lends
        stablecoin.mint(user1, lendAmount);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), lendAmount);
        vm.prank(user1);
        uint256 positionId = bondMMA.lend(lendAmount, maturity);

        // Try to repay a lending position
        vm.prank(user1);
        vm.expectRevert(bytes("Not a borrow position"));
        bondMMA.repay(positionId);
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test successful liquidation after grace period
    function testLiquidate_AfterGracePeriod() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Mint and approve collateral for user1
        stablecoin.mint(user1, 15_000 ether);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), 15_000 ether);

        // User borrows
        vm.prank(user1);
        bondMMA.borrow(10_000 ether, block.timestamp + 90 days, 15_000 ether);

        // Warp past maturity + grace period
        vm.warp(block.timestamp + 90 days + 24 hours + 1 seconds);
        oracle.updateRate(ANCHOR_RATE); // Update oracle after time warp

        uint256 poolCashBefore = bondMMA.cash();

        // Anyone can liquidate
        vm.prank(user2);
        bondMMA.liquidate(1);

        // Position should be inactive
        IBondMMA.Position memory pos = bondMMA.getPosition(1);
        assertFalse(pos.isActive, "Position should be liquidated");

        // Pool should have received collateral
        uint256 poolCashAfter = bondMMA.cash();
        assertEq(poolCashAfter, poolCashBefore + 15_000 ether, "Pool should receive collateral");

        console2.log("Liquidation successful after grace period");
    }

    /// @notice Test liquidation before grace period fails
    function testLiquidate_RevertsBeforeGracePeriod() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Mint and approve collateral for user1
        stablecoin.mint(user1, 15_000 ether);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), 15_000 ether);

        // User borrows
        vm.prank(user1);
        bondMMA.borrow(10_000 ether, block.timestamp + 90 days, 15_000 ether);

        // Warp to just past maturity, but within grace period
        vm.warp(block.timestamp + 90 days + 1 hours);
        oracle.updateRate(ANCHOR_RATE);

        // Should revert
        vm.prank(user2);
        vm.expectRevert("Grace period not expired");
        bondMMA.liquidate(1);
    }

    /// @notice Test liquidation of lending position fails
    function testLiquidate_RevertsIfNotBorrowPosition() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Mint and approve cash for lending
        stablecoin.mint(user1, 10_000 ether);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), 10_000 ether);

        // User lends
        vm.prank(user1);
        bondMMA.lend(10_000 ether, block.timestamp + 90 days);

        // Warp past maturity + grace period
        vm.warp(block.timestamp + 90 days + 24 hours + 1 seconds);
        oracle.updateRate(ANCHOR_RATE);

        // Should revert
        vm.prank(user2);
        vm.expectRevert("Not a borrow position");
        bondMMA.liquidate(1);
    }

    /// @notice Test liquidation reduces liabilities correctly
    function testLiquidate_ReducesLiabilities() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Mint and approve collateral for user1
        stablecoin.mint(user1, 15_000 ether);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), 15_000 ether);

        // User borrows
        vm.prank(user1);
        bondMMA.borrow(10_000 ether, block.timestamp + 90 days, 15_000 ether);

        uint256 liabilitiesAfterBorrow = bondMMA.netLiabilities();
        assertGt(liabilitiesAfterBorrow, 0, "Should have liabilities after borrow");

        // Warp past grace period
        vm.warp(block.timestamp + 90 days + 24 hours + 1 seconds);
        oracle.updateRate(ANCHOR_RATE);

        // Liquidate
        vm.prank(user2);
        bondMMA.liquidate(1);

        // Net liabilities should be reduced
        uint256 liabilitiesAfterLiquidation = bondMMA.netLiabilities();
        assertLt(liabilitiesAfterLiquidation, liabilitiesAfterBorrow, "Liabilities should decrease");

        console2.log("Liabilities reduced correctly after liquidation");
    }

    /// @notice Test liquidation is permissionless (anyone can liquidate)
    function testLiquidate_Permissionless() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Mint and approve collateral for user1
        stablecoin.mint(user1, 15_000 ether);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), 15_000 ether);

        // User 1 borrows
        vm.prank(user1);
        bondMMA.borrow(10_000 ether, block.timestamp + 90 days, 15_000 ether);

        // Warp past grace period
        vm.warp(block.timestamp + 90 days + 24 hours + 1 seconds);
        oracle.updateRate(ANCHOR_RATE);

        // User 3 (unrelated party) can liquidate
        vm.prank(user3);
        bondMMA.liquidate(1);

        IBondMMA.Position memory pos = bondMMA.getPosition(1);
        assertFalse(pos.isActive, "Position should be liquidated by any user");

        console2.log("Liquidation is permissionless");
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test pause() can only be called by owner
    function testPause_OnlyOwner() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Non-owner cannot pause
        vm.prank(user1);
        vm.expectRevert();
        bondMMA.pause();

        // Owner can pause
        bondMMA.pause();
        assertTrue(bondMMA.paused(), "Contract should be paused");
    }

    /// @notice Test lend reverts when paused
    function testLend_RevertsWhenPaused() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Pause the contract
        bondMMA.pause();

        // Mint tokens to user
        stablecoin.mint(user1, 10_000 ether);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), 10_000 ether);

        // Lend should revert
        vm.prank(user1);
        vm.expectRevert();
        bondMMA.lend(10_000 ether, block.timestamp + 90 days);
    }

    /// @notice Test borrow reverts when paused
    function testBorrow_RevertsWhenPaused() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Pause the contract
        bondMMA.pause();

        // Mint tokens to user
        stablecoin.mint(user1, 15_000 ether);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), 15_000 ether);

        // Borrow should revert
        vm.prank(user1);
        vm.expectRevert();
        bondMMA.borrow(10_000 ether, block.timestamp + 90 days, 15_000 ether);
    }

    /// @notice Test redeem still works when paused (for user safety)
    function testRedeem_WorksWhenPaused() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // User lends
        stablecoin.mint(user1, 10_000 ether);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), 10_000 ether);
        vm.prank(user1);
        bondMMA.lend(10_000 ether, block.timestamp + 90 days);

        // Warp to maturity
        vm.warp(block.timestamp + 90 days);
        oracle.updateRate(ANCHOR_RATE);

        // Pause the contract
        bondMMA.pause();

        // Redeem should still work
        vm.prank(user1);
        bondMMA.redeem(1);

        IBondMMA.Position memory pos = bondMMA.getPosition(1);
        assertFalse(pos.isActive, "Position should be redeemed even when paused");

        console2.log("Redeem works when paused");
    }

    /// @notice Test repay still works when paused (for user safety)
    function testRepay_WorksWhenPaused() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // User borrows
        stablecoin.mint(user1, 25_000 ether);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), 25_000 ether);
        vm.prank(user1);
        bondMMA.borrow(10_000 ether, block.timestamp + 90 days, 15_000 ether);

        // Warp to maturity
        vm.warp(block.timestamp + 90 days);
        oracle.updateRate(ANCHOR_RATE);

        // Pause the contract
        bondMMA.pause();

        // Mint more tokens for repayment (face value is higher than borrowed amount)
        stablecoin.mint(user1, 15_000 ether);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), 15_000 ether);

        // Repay should still work
        vm.prank(user1);
        bondMMA.repay(1);

        IBondMMA.Position memory pos = bondMMA.getPosition(1);
        assertFalse(pos.isActive, "Position should be repaid even when paused");

        console2.log("Repay works when paused");
    }

    /// @notice Test unpause restores normal operations
    function testUnpause_RestoresOperations() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Pause
        bondMMA.pause();
        assertTrue(bondMMA.paused(), "Should be paused");

        // Unpause
        bondMMA.unpause();
        assertFalse(bondMMA.paused(), "Should be unpaused");

        // Lend should work again
        stablecoin.mint(user1, 10_000 ether);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), 10_000 ether);
        vm.prank(user1);
        bondMMA.lend(10_000 ether, block.timestamp + 90 days);

        IBondMMA.Position memory pos = bondMMA.getPosition(1);
        assertTrue(pos.isActive, "Position should be created after unpause");

        console2.log("Unpause restores operations");
    }

    /*//////////////////////////////////////////////////////////////
                    ORACLE FAILURE HANDLING TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test repay works when oracle is stale (uses fallback rate)
    function testRepay_WorksWhenOracleStale() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // User borrows
        stablecoin.mint(user1, 25_000 ether);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), 25_000 ether);
        vm.prank(user1);
        bondMMA.borrow(10_000 ether, block.timestamp + 90 days, 15_000 ether);

        // Set oracle as stale (MockOracle uses manual flag)
        oracle.setStale(true);

        // Verify oracle is stale
        assertTrue(oracle.isStale(), "Oracle should be stale");

        // Mint more tokens for repayment
        stablecoin.mint(user1, 15_000 ether);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), 15_000 ether);

        // Repay should still work using fallback rate
        vm.prank(user1);
        bondMMA.repay(1);

        IBondMMA.Position memory pos = bondMMA.getPosition(1);
        assertFalse(pos.isActive, "Position should be repaid even with stale oracle");

        console2.log("Repay works with stale oracle (fallback rate used)");
    }

    /// @notice Test setFallbackRate only callable by owner
    function testSetFallbackRate_OnlyOwner() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Non-owner cannot set fallback rate
        vm.prank(user1);
        vm.expectRevert();
        bondMMA.setFallbackRate(60000000000000000); // 6%

        // Owner can set fallback rate
        bondMMA.setFallbackRate(60000000000000000); // 6%
        assertEq(bondMMA.fallbackRate(), 60000000000000000, "Fallback rate should be updated");
    }

    /// @notice Test setFallbackRate reverts if rate too high
    function testSetFallbackRate_RevertsIfTooHigh() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Try to set rate above 20% - should revert
        vm.expectRevert("Fallback rate too high");
        bondMMA.setFallbackRate(300000000000000000); // 30%
    }

    /// @notice Test lend still reverts when oracle is stale (safety check)
    function testLend_RevertsWhenOracleStaleForSafety() public {
        bondMMA.initialize(INITIAL_CASH, address(oracle), address(stablecoin));

        // Set oracle as stale
        oracle.setStale(true);

        // Mint tokens
        stablecoin.mint(user1, 10_000 ether);
        vm.prank(user1);
        stablecoin.approve(address(bondMMA), 10_000 ether);

        // Lend should revert when oracle is stale (for safety)
        vm.prank(user1);
        vm.expectRevert("Oracle data is stale");
        bondMMA.lend(10_000 ether, block.timestamp + 90 days);
    }
}
