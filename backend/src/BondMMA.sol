// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UD60x18, ud, intoUint256} from "@prb/math/src/UD60x18.sol";

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
contract BondMMA is IBondMMA, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;
    using {intoUint256} for UD60x18;

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

    /// @notice Last time liabilities were updated (for decay calculation)
    uint256 public lastUpdateTime;

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

    /// @notice Tracks last trade block for flash loan protection
    mapping(address => uint256) public lastTradeBlock;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Rate sensitivity parameter κ = 0.02 (scaled) - Fixed, not configurable
    uint256 public constant KAPPA = 20;
    uint256 public constant KAPPA_SCALE = 1000;

    /// @notice Precision scale - Fixed
    uint256 public constant PRECISION = 1e18;

    /// @notice Absolute bounds for configurable parameters
    uint256 public constant ABSOLUTE_MIN_MATURITY = 1 days;
    uint256 public constant ABSOLUTE_MAX_MATURITY = 730 days; // 2 years max
    uint256 public constant MIN_COLLATERAL_RATIO = 100; // 100% minimum
    uint256 public constant MAX_COLLATERAL_RATIO = 300; // 300% maximum
    uint256 public constant MIN_SOLVENCY_THRESHOLD = 90; // 90% minimum
    uint256 public constant MAX_SOLVENCY_THRESHOLD = 100; // 100% maximum
    uint256 public constant MIN_GRACE_PERIOD = 1 hours;
    uint256 public constant MAX_GRACE_PERIOD = 7 days;
    uint256 public constant MAX_LIQUIDATION_PENALTY = 20; // 20% max penalty

    /*//////////////////////////////////////////////////////////////
                        CONFIGURABLE PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Minimum maturity (configurable, default: 30 days)
    uint256 public minMaturity = 30 days;

    /// @notice Maximum maturity (configurable, default: 365 days)
    uint256 public maxMaturity = 365 days;

    /// @notice Collateral ratio in percent (configurable, default: 150%)
    uint256 public collateralRatio = 150;

    /// @notice Solvency threshold in percent (configurable, default: 99%)
    uint256 public solvencyThreshold = 99;

    /// @notice Grace period after maturity before liquidation (configurable, default: 24 hours)
    uint256 public gracePeriod = 24 hours;

    /// @notice Liquidation penalty in percent (configurable, default: 5%)
    uint256 public liquidationPenalty = 5;

    /// @notice Fallback rate when oracle is stale (5% = 0.05e18)
    uint256 public fallbackRate = 50000000000000000;

    /// @notice Event emitted when fallback rate is used
    event FallbackRateUsed(uint256 fallbackRate, uint256 timestamp);

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
        lastUpdateTime = block.timestamp; // Initialize liability decay tracking
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
        uint256 minEquity = (initialCash * solvencyThreshold) / 100;

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

    /**
     * @notice Modifier to prevent flash loan attacks
     * @dev Prevents users from trading twice in the same block
     */
    modifier noFlashLoan() {
        require(lastTradeBlock[msg.sender] < block.number, "Flash loan detected");
        lastTradeBlock[msg.sender] = block.number;
        _;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update netLiabilities based on time elapsed
     * @dev Implements liability decay: L(t+Δt) = L(t) · e^(r·Δt)
     *      This ensures liabilities grow with interest over time
     *
     * Formula from paper (Section III):
     *   d ln L = r dt
     *   => L(t+Δt) = L(t) · e^(r·Δt)
     *
     * @custom:security Called before any operation that checks solvency or modifies state
     */
    function updateLiabilities() internal {
        // Skip if no liabilities or no time passed
        if (netLiabilities == 0 || block.timestamp == lastUpdateTime) {
            return;
        }

        // Skip if oracle is stale (fallback to avoid reverting entire transaction)
        // This is safe because lend/borrow will check oracle staleness separately
        if (oracle.isStale()) {
            lastUpdateTime = block.timestamp; // Update timestamp to prevent perpetual staleness
            return;
        }

        // Calculate time elapsed (in years, for rate calculation)
        uint256 timeElapsed = block.timestamp - lastUpdateTime;

        // Get current rate
        uint256 anchorRate = oracle.getRate();
        uint256 currentRate = BondMMMath.calculateRate(pvBonds, cash, anchorRate);

        // Calculate growth factor: e^(r·Δt)
        // Convert timeElapsed to annualized: Δt_years = Δt / SECONDS_PER_YEAR
        // exponent = r · Δt_years = r · (Δt / SECONDS_PER_YEAR)
        uint256 exponent = (currentRate * timeElapsed) / BondMMMath.SECONDS_PER_YEAR;

        // Calculate e^exponent using PRBMath
        UD60x18 growthFactor = ud(exponent).exp();

        // Update liabilities: L_new = L_old · e^(r·Δt)
        netLiabilities = (netLiabilities * growthFactor.intoUint256()) / PRECISION;

        // Update timestamp
        lastUpdateTime = block.timestamp;
    }

    /**
     * @notice Get anchor rate safely, using fallback if oracle is stale
     * @dev For use in functions that should not revert due to oracle issues (like repay)
     * @return rate The anchor rate (from oracle or fallback)
     */
    function getSafeRate() internal returns (uint256) {
        if (oracle.isStale()) {
            emit FallbackRateUsed(fallbackRate, block.timestamp);
            return fallbackRate;
        }
        return oracle.getRate();
    }

    /**
     * @notice Set the fallback rate used when oracle is stale
     * @dev Only owner can update the fallback rate
     * @param _fallbackRate New fallback rate (scaled by 1e18)
     */
    function setFallbackRate(uint256 _fallbackRate) external onlyOwner {
        require(_fallbackRate <= 200000000000000000, "Fallback rate too high"); // Max 20%
        fallbackRate = _fallbackRate;
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
        whenNotPaused
        noFlashLoan
        requireSolvency
        returns (uint256 positionId)
    {
        // Update liabilities with time decay before any state changes
        updateLiabilities();

        // Validate inputs
        require(amount > 0, "Amount must be > 0");
        require(maturity > block.timestamp, "Maturity must be in future");

        // Calculate time to maturity
        uint256 timeToMaturity = maturity - block.timestamp;
        require(timeToMaturity >= minMaturity, "Maturity too soon");
        require(timeToMaturity <= maxMaturity, "Maturity too far");

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
            initialPV: DeltaPV, // Store initial present value
            createdAt: block.timestamp, // Track creation time for liability decay
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
        whenNotPaused
        noFlashLoan
        returns (uint256 positionId)
    {
        // Update liabilities with time decay before any state changes
        updateLiabilities();

        // Validate inputs
        require(amount > 0, "Amount must be > 0");
        require(maturity > block.timestamp, "Maturity must be in future");

        // Step 1: Require collateral upfront (150% of borrowed amount)
        uint256 requiredCollateral = (amount * collateralRatio) / 100;
        require(collateral >= requiredCollateral, "Insufficient collateral");

        // Calculate time to maturity
        uint256 timeToMaturity = maturity - block.timestamp;
        require(timeToMaturity >= minMaturity, "Maturity too soon");
        require(timeToMaturity <= maxMaturity, "Maturity too far");

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
            initialPV: DeltaPV, // Store initial present value
            createdAt: block.timestamp, // Track creation time for liability decay
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
        // Update liabilities with time decay before any state changes
        updateLiabilities();

        // Get position
        IBondMMA.Position storage position = positions[positionId];

        // Validate position
        require(position.isActive, "Position not active");
        require(position.owner == msg.sender, "Not position owner");
        require(!position.isBorrow, "Cannot redeem borrow position");
        require(block.timestamp >= position.maturity, "Not yet mature");

        // At maturity: 1 bond = 1 cash (price = 1.0)
        uint256 cashAmount = position.faceValue;

        // Update pool state
        cash -= cashAmount; // Pool pays out face value

        // Calculate PV to add back to pvBonds (we're removing the liability)
        // At maturity, price = 1, so PV = faceValue
        pvBonds += position.faceValue;

        // Burn position
        position.isActive = false;

        // Transfer cash to lender
        stablecoin.safeTransfer(msg.sender, cashAmount);

        emit Redeem(positionId, msg.sender, cashAmount);
    }

    /**
     * @notice Repay a borrow position
     * @param positionId ID of the position to repay
     */
    function repay(uint256 positionId) external nonReentrant onlyInitialized {
        // Update liabilities with time decay before any state changes
        updateLiabilities();

        // Get position
        IBondMMA.Position storage position = positions[positionId];

        // Validate position
        require(position.isActive, "Position not active");
        require(position.owner == msg.sender, "Not position owner");
        require(position.isBorrow, "Not a borrow position");

        uint256 repayAmount;
        uint256 timeToMaturity;
        uint256 currentPV;

        if (block.timestamp >= position.maturity) {
            // At maturity: repay face value (1:1)
            repayAmount = position.faceValue;
            currentPV = position.faceValue; // price = 1 at maturity
        } else {
            // Before maturity: repay present value
            timeToMaturity = position.maturity - block.timestamp;

            // Calculate current rate and price (use safe rate for oracle failure handling)
            uint256 anchorRate = getSafeRate();
            uint256 currentRate = BondMMMath.calculateRate(pvBonds, cash, anchorRate);
            uint256 price = BondMMMath.calculatePrice(timeToMaturity, currentRate);

            // Calculate repayment amount (present value)
            repayAmount = (position.faceValue * price) / PRECISION;
            currentPV = repayAmount;
        }

        // Calculate grown liability value to subtract from netLiabilities
        // Liability has grown since creation: currentLiability = initialPV * e^(r·Δt)
        uint256 timeElapsed = block.timestamp - position.createdAt;
        uint256 currentAnchorRate = getSafeRate();
        uint256 avgRate = BondMMMath.calculateRate(pvBonds, cash, currentAnchorRate);
        uint256 exponent = (avgRate * timeElapsed) / BondMMMath.SECONDS_PER_YEAR;
        UD60x18 growthFactor = ud(exponent).exp();
        uint256 grownLiability = (position.initialPV * growthFactor.intoUint256()) / PRECISION;

        // Update pool state
        cash += repayAmount; // Pool receives repayment
        pvBonds -= currentPV; // Remove bond claim from pool
        netLiabilities -= grownLiability; // Reduce by grown value of liability

        // Burn position
        position.isActive = false;

        // Transfer repayment from borrower to pool
        stablecoin.safeTransferFrom(msg.sender, address(this), repayAmount);

        // Return collateral to borrower
        stablecoin.safeTransfer(msg.sender, position.collateral);

        emit Repay(positionId, msg.sender, repayAmount, position.collateral);
    }

    /**
     * @notice Liquidate a defaulted borrow position
     * @dev Can be called by anyone after maturity + grace period
     * @param positionId ID of the position to liquidate
     *
     * Requirements:
     * - Position must be active borrow position
     * - Must be past maturity + grace period
     *
     * Process:
     * 1. Calculate total debt (face value + 5% penalty)
     * 2. Seize collateral
     * 3. Add collateral to pool cash
     * 4. Reduce netLiabilities by grown liability value
     * 5. Burn position
     * 6. Emit Liquidated event
     */
    function liquidate(uint256 positionId) external nonReentrant onlyInitialized whenNotPaused {
        // Update liabilities with time decay before any state changes
        updateLiabilities();

        // Get position
        IBondMMA.Position storage position = positions[positionId];

        // Validate position
        require(position.isActive, "Position not active");
        require(position.isBorrow, "Not a borrow position");
        require(
            block.timestamp > position.maturity + gracePeriod,
            "Grace period not expired"
        );

        // Calculate debt owed: face value + 5% penalty
        uint256 debt = position.faceValue;
        uint256 penalty = (debt * liquidationPenalty) / 100;
        uint256 totalOwed = debt + penalty;

        // Seize all collateral
        uint256 collateralSeized = position.collateral;

        // Calculate grown liability value to subtract from netLiabilities
        // Same calculation as in repay() - use safe rate for oracle failure handling
        uint256 timeElapsed = block.timestamp - position.createdAt;
        uint256 currentAnchorRate = getSafeRate();
        uint256 avgRate = BondMMMath.calculateRate(pvBonds, cash, currentAnchorRate);
        uint256 exponent = (avgRate * timeElapsed) / BondMMMath.SECONDS_PER_YEAR;
        UD60x18 growthFactor = ud(exponent).exp();
        uint256 grownLiability = (position.initialPV * growthFactor.intoUint256()) / PRECISION;

        // Update pool state
        cash += collateralSeized; // Pool receives seized collateral
        pvBonds -= position.faceValue; // Remove bond claim (face value since at/past maturity)
        netLiabilities -= grownLiability; // Reduce by grown value of liability

        // Burn position
        position.isActive = false;

        emit Liquidated(
            positionId,
            position.owner,
            msg.sender,
            totalOwed,
            collateralSeized,
            penalty
        );
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY PAUSE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pause the contract - stops new lend, borrow, and liquidate operations
     * @dev Only owner can pause. Redeem and repay still work to allow position exits.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract - resume normal operations
     * @dev Only owner can unpause
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN CONTROL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set minimum maturity for positions
     * @dev Only owner can change. Must be within absolute bounds.
     * @param _minMaturity New minimum maturity in seconds
     */
    function setMinMaturity(uint256 _minMaturity) external onlyOwner {
        require(_minMaturity >= ABSOLUTE_MIN_MATURITY, "Below absolute minimum");
        require(_minMaturity < maxMaturity, "Min must be < max");
        minMaturity = _minMaturity;
        emit MinMaturityUpdated(_minMaturity);
    }

    /**
     * @notice Set maximum maturity for positions
     * @dev Only owner can change. Must be within absolute bounds.
     * @param _maxMaturity New maximum maturity in seconds
     */
    function setMaxMaturity(uint256 _maxMaturity) external onlyOwner {
        require(_maxMaturity <= ABSOLUTE_MAX_MATURITY, "Above absolute maximum");
        require(_maxMaturity > minMaturity, "Max must be > min");
        maxMaturity = _maxMaturity;
        emit MaxMaturityUpdated(_maxMaturity);
    }

    /**
     * @notice Set collateral ratio for borrows
     * @dev Only owner can change. Must be within bounds (100-300%).
     * @param _collateralRatio New collateral ratio in percent (e.g., 150 = 150%)
     */
    function setCollateralRatio(uint256 _collateralRatio) external onlyOwner {
        require(_collateralRatio >= MIN_COLLATERAL_RATIO, "Below minimum ratio");
        require(_collateralRatio <= MAX_COLLATERAL_RATIO, "Above maximum ratio");
        collateralRatio = _collateralRatio;
        emit CollateralRatioUpdated(_collateralRatio);
    }

    /**
     * @notice Set solvency threshold
     * @dev Only owner can change. Must be within bounds (90-100%).
     * @param _solvencyThreshold New solvency threshold in percent (e.g., 99 = 99%)
     */
    function setSolvencyThreshold(uint256 _solvencyThreshold) external onlyOwner {
        require(_solvencyThreshold >= MIN_SOLVENCY_THRESHOLD, "Below minimum threshold");
        require(_solvencyThreshold <= MAX_SOLVENCY_THRESHOLD, "Above maximum threshold");
        solvencyThreshold = _solvencyThreshold;
        emit SolvencyThresholdUpdated(_solvencyThreshold);
    }

    /**
     * @notice Set grace period before liquidation
     * @dev Only owner can change. Must be within bounds (1 hour - 7 days).
     * @param _gracePeriod New grace period in seconds
     */
    function setGracePeriod(uint256 _gracePeriod) external onlyOwner {
        require(_gracePeriod >= MIN_GRACE_PERIOD, "Below minimum grace period");
        require(_gracePeriod <= MAX_GRACE_PERIOD, "Above maximum grace period");
        gracePeriod = _gracePeriod;
        emit GracePeriodUpdated(_gracePeriod);
    }

    /**
     * @notice Set liquidation penalty
     * @dev Only owner can change. Must not exceed 20%.
     * @param _liquidationPenalty New liquidation penalty in percent (e.g., 5 = 5%)
     */
    function setLiquidationPenalty(uint256 _liquidationPenalty) external onlyOwner {
        require(_liquidationPenalty <= MAX_LIQUIDATION_PENALTY, "Penalty too high");
        liquidationPenalty = _liquidationPenalty;
        emit LiquidationPenaltyUpdated(_liquidationPenalty);
    }

    /**
     * @notice Set oracle contract address
     * @dev Only owner can change. Cannot be zero address.
     * @param _oracle New oracle contract address
     */
    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Invalid oracle address");
        oracle = IOracle(_oracle);
        emit OracleUpdated(_oracle);
    }
}
