// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BondMMMath} from "./libraries/BondMMMath.sol";
import {IBondMMA} from "./interfaces/IBondMMA.sol";
import {IOracle} from "./interfaces/IOracle.sol";

/**
 * @title BondMMA
 * @notice Decentralized fixed-income AMM for arbitrary maturities
 * @dev Implements the BondMM-A protocol with invariant K·x^α + y^α = C
 *
 * Core state variables:
 * - cash (y): Cash in pool
 * - pvBonds (X): Present value of bonds
 * - netLiabilities (L): Present value of borrows
 *
 * Solvency invariant: E = y + L ≥ 0.99·y₀
 */
contract BondMMA is IBondMMA, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Cash in pool (y)
    uint256 public cash;

    /// @notice Present value of bonds (X)
    uint256 public pvBonds;

    /// @notice Present value of net liabilities (L)
    uint256 public netLiabilities;

    /// @notice Initial cash deposited (y₀) - used for solvency check
    uint256 public initialCash;

    /// @notice Counter for position IDs
    uint256 public nextPositionId;

    /// @notice Mapping of position ID to Position struct
    mapping(uint256 => IBondMMA.Position) public positions;

    /// @notice Oracle contract providing anchor rate r*
    IOracle public oracle;

    /// @notice Stablecoin used for cash (DAI/USDC)
    IERC20 public stablecoin;

    /// @notice Flag to ensure initialize is called only once
    bool public initialized;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Rate sensitivity parameter κ = 0.02 (scaled)
    uint256 public constant KAPPA = 20;
    uint256 public constant KAPPA_SCALE = 1000;

    /// @notice Minimum maturity: 30 days
    uint256 public constant MIN_MATURITY = 30 days;

    /// @notice Maximum maturity: 365 days
    uint256 public constant MAX_MATURITY = 365 days;

    /// @notice Collateral ratio: 150%
    uint256 public constant COLLATERAL_RATIO = 150;

    /// @notice Solvency threshold: 99% of initial cash
    uint256 public constant SOLVENCY_THRESHOLD = 99;

    /// @notice Precision scale
    uint256 public constant PRECISION = 1e18;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() Ownable(msg.sender) {}

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the pool (one-time only)
     * @dev Sets initial state: cash = pvBonds = initialCash, netLiabilities = 0
     * @param _initialCash Initial cash to deposit (e.g., 100,000 DAI)
     * @param _oracle Address of the oracle contract
     * @param _stablecoin Address of the stablecoin (DAI/USDC)
     */
    function initialize(uint256 _initialCash, address _oracle, address _stablecoin) external onlyOwner {
        require(!initialized, "Already initialized");
        require(_initialCash > 0, "Initial cash must be > 0");
        require(_oracle != address(0), "Invalid oracle address");
        require(_stablecoin != address(0), "Invalid stablecoin address");

        // Set initial state
        cash = _initialCash;
        initialCash = _initialCash;
        pvBonds = _initialCash; // X₀ = y₀
        netLiabilities = 0;
        nextPositionId = 1; // Start IDs from 1

        // Set contracts
        oracle = IOracle(_oracle);
        stablecoin = IERC20(_stablecoin);

        // Mark as initialized
        initialized = true;

        // Transfer initial cash from owner
        stablecoin.safeTransferFrom(msg.sender, address(this), _initialCash);

        emit Initialized(_initialCash, _oracle, _stablecoin);
    }

    /*//////////////////////////////////////////////////////////////
                           SOLVENCY CHECKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Check if pool is solvent
     * @dev Solvency condition: E = y + L ≥ 0.99·y₀
     * @return True if pool is solvent
     */
    function checkSolvency() public view returns (bool) {
        // Calculate equity: E = y + L
        uint256 equity = cash + netLiabilities;

        // Calculate minimum required equity: 0.99·y₀
        uint256 minEquity = (initialCash * SOLVENCY_THRESHOLD) / 100;

        return equity >= minEquity;
    }

    /**
     * @notice Modifier to ensure solvency after function execution
     * @dev Executes function first, then checks solvency
     */
    modifier requireSolvency() {
        _;
        require(checkSolvency(), "Pool insolvent");
    }

    /**
     * @notice Modifier to ensure pool is initialized
     */
    modifier onlyInitialized() {
        require(initialized, "Not initialized");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get current interest rate r = κ ln(X/y) + r*
     * @return Current rate (scaled by 1e18)
     */
    function getCurrentRate() external view returns (uint256) {
        uint256 anchorRate = oracle.getRate();
        return BondMMMath.calculateRate(pvBonds, cash, anchorRate);
    }

    /**
     * @notice Get anchor rate from oracle
     * @return Anchor rate r* (scaled by 1e18)
     */
    function getAnchorRate() external view returns (uint256) {
        return oracle.getRate();
    }

    /**
     * @notice Get a position by ID
     * @param positionId ID of the position
     * @return position Position struct
     */
    function getPosition(uint256 positionId) external view returns (IBondMMA.Position memory position) {
        return positions[positionId];
    }

    /*//////////////////////////////////////////////////////////////
                        CORE TRADING FUNCTIONS
                        (To be implemented in Phase 4)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Lend cash to the pool and receive bonds
     * @param amount Amount of cash to lend
     * @param maturity Timestamp when bonds mature
     * @return positionId ID of the created position
     */
    function lend(uint256 amount, uint256 maturity)
        external
        nonReentrant
        onlyInitialized
        requireSolvency
        returns (uint256 positionId)
    {
        // Validate inputs
        require(amount > 0, "Amount must be > 0");
        require(maturity > block.timestamp, "Maturity must be in future");

        // Calculate time to maturity
        uint256 timeToMaturity = maturity - block.timestamp;
        require(timeToMaturity >= MIN_MATURITY, "Maturity too soon");
        require(timeToMaturity <= MAX_MATURITY, "Maturity too far");

        // Get current rate from oracle
        uint256 anchorRate = oracle.getRate();
        require(!oracle.isStale(), "Oracle data is stale");

        // Step 1: Calculate bond face value from cash amount
        // When lending, user gives cash and receives bonds (isPositive = true)
        uint256 deltaX = BondMMMath.calculateDeltaX(pvBonds, cash, amount, timeToMaturity, anchorRate, true);

        // Step 2: Calculate current bond price p = e^(-rt)
        uint256 currentRate = BondMMMath.calculateRate(pvBonds, cash, anchorRate);
        uint256 price = BondMMMath.calculatePrice(timeToMaturity, currentRate);

        // Step 3: Update pool state
        // Pool receives cash from lender
        cash += amount;

        // Pool's bond position decreases (negative lending = liability to pay bonds)
        // pvBonds is stored in present value terms
        uint256 DeltaPV = (deltaX * price) / PRECISION;
        pvBonds -= DeltaPV;

        // Step 4: Transfer cash from user to pool
        stablecoin.safeTransferFrom(msg.sender, address(this), amount);

        // Step 5: Mint position for user
        positionId = nextPositionId++;
        positions[positionId] = IBondMMA.Position({
            owner: msg.sender,
            faceValue: deltaX,
            maturity: maturity,
            collateral: 0, // No collateral for lending positions
            isBorrow: false,
            isActive: true
        });

        emit Lend(msg.sender, positionId, amount, deltaX, maturity);

        // requireSolvency modifier will check solvency after this function executes
    }

    /**
     * @notice Borrow cash from the pool with collateral
     * @param amount Amount of cash to borrow
     * @param maturity Timestamp when loan matures
     * @param collateral Amount of collateral to deposit
     * @return positionId ID of the created position
     */
    function borrow(uint256 amount, uint256 maturity, uint256 collateral)
        external
        nonReentrant
        onlyInitialized
        returns (uint256 positionId)
    {
        // Validate inputs
        require(amount > 0, "Amount must be > 0");
        require(maturity > block.timestamp, "Maturity must be in future");

        // Step 1: Require collateral upfront (150% of borrowed amount)
        uint256 requiredCollateral = (amount * COLLATERAL_RATIO) / 100;
        require(collateral >= requiredCollateral, "Insufficient collateral");

        // Calculate time to maturity
        uint256 timeToMaturity = maturity - block.timestamp;
        require(timeToMaturity >= MIN_MATURITY, "Maturity too soon");
        require(timeToMaturity <= MAX_MATURITY, "Maturity too far");

        // Get current rate from oracle
        uint256 anchorRate = oracle.getRate();
        require(!oracle.isStale(), "Oracle data is stale");

        // Check pool has enough cash to lend
        require(cash >= amount, "Insufficient pool liquidity");

        // Step 2: Calculate bond face value from cash amount
        // When borrowing, user takes cash and owes bonds (isPositive = false)
        uint256 deltaX = BondMMMath.calculateDeltaX(pvBonds, cash, amount, timeToMaturity, anchorRate, false);

        // Step 3: Calculate current bond price p = e^(-rt)
        uint256 currentRate = BondMMMath.calculateRate(pvBonds, cash, anchorRate);
        uint256 price = BondMMMath.calculatePrice(timeToMaturity, currentRate);

        // Step 4: Update pool state
        // Pool gives cash to borrower
        cash -= amount;

        // Pool's bond position increases (borrower owes pool)
        // pvBonds and netLiabilities stored in present value terms
        uint256 DeltaPV = (deltaX * price) / PRECISION;
        pvBonds += DeltaPV;
        netLiabilities += DeltaPV;

        // Step 5: Transfer collateral from user to pool
        stablecoin.safeTransferFrom(msg.sender, address(this), collateral);

        // Step 6: Transfer borrowed cash from pool to user
        stablecoin.safeTransfer(msg.sender, amount);

        // Step 7: Mint position for user
        positionId = nextPositionId++;
        positions[positionId] = IBondMMA.Position({
            owner: msg.sender,
            faceValue: deltaX,
            maturity: maturity,
            collateral: collateral,
            isBorrow: true,
            isActive: true
        });

        emit Borrow(msg.sender, positionId, amount, deltaX, maturity, collateral);
    }

    /**
     * @notice Redeem a lending position at maturity
     * @param positionId ID of the position to redeem
     */
    function redeem(uint256 positionId) external nonReentrant onlyInitialized {
        positionId; // Silence unused variable warning
        // To be implemented in Phase 5
        revert("Not yet implemented");
    }

    /**
     * @notice Repay a borrow position
     * @param positionId ID of the position to repay
     */
    function repay(uint256 positionId) external nonReentrant onlyInitialized {
        positionId; // Silence unused variable warning
        // To be implemented in Phase 5
        revert("Not yet implemented");
    }
}
