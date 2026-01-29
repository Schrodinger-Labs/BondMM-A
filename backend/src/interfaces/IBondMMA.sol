// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IBondMMA
 * @notice Interface for BondMM-A protocol
 * @dev Defines all external functions, events, and data structures for the AMM
 */
interface IBondMMA {
    // Force language server refresh
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Represents a lending or borrowing position
     * @param owner Address that owns this position
     * @param faceValue Bond face value (amount to be repaid/received at maturity)
     * @param maturity Timestamp when position matures
     * @param collateral Amount of collateral deposited (only for borrow positions)
     * @param initialPV Initial present value when position was created (for tracking)
     * @param createdAt Timestamp when position was created (for liability decay calculation)
     * @param isBorrow True if this is a borrow position, false if lending
     * @param isActive True if position is still active, false if closed
     */
    struct Position {
        address owner;
        uint256 faceValue;
        uint256 maturity;
        uint256 collateral;
        uint256 initialPV;
        uint256 createdAt;
        bool isBorrow;
        bool isActive;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when pool is initialized
     * @param initialCash Amount of initial cash deposited
     * @param oracle Address of the oracle contract
     * @param stablecoin Address of the stablecoin used
     */
    event Initialized(uint256 initialCash, address indexed oracle, address indexed stablecoin);

    /**
     * @notice Emitted when a user lends (buys bonds)
     * @param user Address of the lender
     * @param positionId ID of the created position
     * @param cashAmount Amount of cash deposited
     * @param bondAmount Face value of bonds received
     * @param maturity Maturity timestamp
     */
    event Lend(
        address indexed user,
        uint256 indexed positionId,
        uint256 cashAmount,
        uint256 bondAmount,
        uint256 maturity
    );

    /**
     * @notice Emitted when a user borrows
     * @param user Address of the borrower
     * @param positionId ID of the created position
     * @param cashAmount Amount of cash borrowed
     * @param bondAmount Face value of bonds owed
     * @param maturity Maturity timestamp
     * @param collateral Amount of collateral deposited
     */
    event Borrow(
        address indexed user,
        uint256 indexed positionId,
        uint256 cashAmount,
        uint256 bondAmount,
        uint256 maturity,
        uint256 collateral
    );

    /**
     * @notice Emitted when a lending position is redeemed
     * @param positionId ID of the position
     * @param owner Address of the position owner
     * @param amount Amount of cash redeemed
     */
    event Redeem(uint256 indexed positionId, address indexed owner, uint256 amount);

    /**
     * @notice Emitted when a borrow position is repaid
     * @param positionId ID of the position
     * @param owner Address of the position owner
     * @param repayAmount Amount of cash repaid
     * @param collateralReturned Amount of collateral returned
     */
    event Repay(uint256 indexed positionId, address indexed owner, uint256 repayAmount, uint256 collateralReturned);

    /**
     * @notice Emitted when a borrow position is liquidated
     * @param positionId ID of the liquidated position
     * @param borrower Address of the borrower
     * @param liquidator Address that triggered liquidation
     * @param debtOwed Total debt owed (face value + penalty)
     * @param collateralSeized Amount of collateral seized
     * @param penaltyCharged Penalty amount charged (5% of debt)
     */
    event Liquidated(
        uint256 indexed positionId,
        address indexed borrower,
        address indexed liquidator,
        uint256 debtOwed,
        uint256 collateralSeized,
        uint256 penaltyCharged
    );

    /*//////////////////////////////////////////////////////////////
                        ADMIN CONTROL EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when minimum maturity is updated
    event MinMaturityUpdated(uint256 newMinMaturity);

    /// @notice Emitted when maximum maturity is updated
    event MaxMaturityUpdated(uint256 newMaxMaturity);

    /// @notice Emitted when collateral ratio is updated
    event CollateralRatioUpdated(uint256 newCollateralRatio);

    /// @notice Emitted when solvency threshold is updated
    event SolvencyThresholdUpdated(uint256 newSolvencyThreshold);

    /// @notice Emitted when grace period is updated
    event GracePeriodUpdated(uint256 newGracePeriod);

    /// @notice Emitted when liquidation penalty is updated
    event LiquidationPenaltyUpdated(uint256 newLiquidationPenalty);

    /// @notice Emitted when oracle is updated
    event OracleUpdated(address newOracle);

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get current cash in pool
     * @return Current cash balance (y)
     */
    function cash() external view returns (uint256);

    /**
     * @notice Get present value of bonds
     * @return Present value of bonds (X)
     */
    function pvBonds() external view returns (uint256);

    /**
     * @notice Get net liabilities
     * @return Present value of all borrows (L)
     */
    function netLiabilities() external view returns (uint256);

    /**
     * @notice Get initial cash amount
     * @return Initial cash (y₀)
     */
    function initialCash() external view returns (uint256);

    /**
     * @notice Get a position by ID
     * @param positionId ID of the position
     * @return position Position struct
     */
    function getPosition(uint256 positionId) external view returns (Position memory position);

    /**
     * @notice Check if pool is solvent
     * @return True if E = y + L ≥ 0.99·y₀
     */
    function checkSolvency() external view returns (bool);

    /**
     * @notice Get current interest rate
     * @return Current rate r
     */
    function getCurrentRate() external view returns (uint256);

    /**
     * @notice Get anchor rate from oracle
     * @return Anchor rate r*
     */
    function getAnchorRate() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                        STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the pool (one-time only)
     * @param _initialCash Initial cash to deposit
     * @param _oracle Address of the oracle contract
     * @param _stablecoin Address of the stablecoin (DAI/USDC)
     */
    function initialize(uint256 _initialCash, address _oracle, address _stablecoin) external;

    /**
     * @notice Lend cash to the pool and receive bonds
     * @param amount Amount of cash to lend
     * @param maturity Timestamp when bonds mature
     * @return positionId ID of the created position
     */
    function lend(uint256 amount, uint256 maturity) external returns (uint256 positionId);

    /**
     * @notice Borrow cash from the pool with collateral
     * @param amount Amount of cash to borrow
     * @param maturity Timestamp when loan matures
     * @param collateral Amount of collateral to deposit (150% of borrow)
     * @return positionId ID of the created position
     */
    function borrow(uint256 amount, uint256 maturity, uint256 collateral) external returns (uint256 positionId);

    /**
     * @notice Redeem a lending position at maturity
     * @param positionId ID of the position to redeem
     */
    function redeem(uint256 positionId) external;

    /**
     * @notice Repay a borrow position
     * @param positionId ID of the position to repay
     */
    function repay(uint256 positionId) external;
}
