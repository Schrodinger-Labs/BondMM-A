// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOracle} from "./interfaces/IOracle.sol";

/**
 * @title BondMMOracle
 * @notice Simple TWAP-based oracle for BondMM-A protocol
 * @dev Provides anchor rate (r*) using time-weighted average price
 *
 * MVP Implementation:
 * - Stores last 24 rate observations
 * - Calculates simple average (TWAP)
 * - Marks data as stale after 1 hour
 * - Owner-controlled updates (manual for MVP)
 *
 * Production Notes:
 * - Should integrate with Chainlink or similar
 * - Should use more sophisticated TWAP calculation
 * - Should have multiple data sources
 */
contract BondMMOracle is IOracle, Ownable {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Array of historical rates
    uint256[] public rateHistory;

    /// @notice Array of timestamps for each rate
    uint256[] public timestamps;

    /// @notice Address authorized to update rates
    address public updater;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum number of historical observations to store
    uint256 public constant MAX_HISTORY = 24;

    /// @notice Time threshold for staleness (1 hour)
    uint256 public constant STALE_THRESHOLD = 1 hours;

    /// @notice Minimum rate (1% = 0.01)
    uint256 public constant MIN_RATE = 0.01 ether;

    /// @notice Maximum rate (50% = 0.50)
    uint256 public constant MAX_RATE = 0.50 ether;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event RateUpdated(uint256 indexed newRate, uint256 timestamp, address indexed updater);
    event UpdaterChanged(address indexed oldUpdater, address indexed newUpdater);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize oracle with initial rate
     * @param initialRate Initial anchor rate (scaled by 1e18)
     */
    constructor(uint256 initialRate) Ownable(msg.sender) {
        require(initialRate >= MIN_RATE && initialRate <= MAX_RATE, "Rate out of bounds");

        // Set initial rate
        rateHistory.push(initialRate);
        timestamps.push(block.timestamp);

        // Owner is initial updater
        updater = msg.sender;

        emit RateUpdated(initialRate, block.timestamp, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update the authorized updater address
     * @param newUpdater New updater address
     */
    function setUpdater(address newUpdater) external onlyOwner {
        require(newUpdater != address(0), "Invalid updater address");
        address oldUpdater = updater;
        updater = newUpdater;
        emit UpdaterChanged(oldUpdater, newUpdater);
    }

    /**
     * @notice Modifier to restrict access to updater
     */
    modifier onlyUpdater() {
        require(msg.sender == updater || msg.sender == owner(), "Not authorized");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            RATE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update the anchor rate
     * @dev Adds new rate to history and removes oldest if at capacity
     * @param newRate New anchor rate (scaled by 1e18)
     */
    function updateRate(uint256 newRate) external onlyUpdater {
        require(newRate >= MIN_RATE && newRate <= MAX_RATE, "Rate out of bounds");

        // Add new observation
        rateHistory.push(newRate);
        timestamps.push(block.timestamp);

        // Remove oldest observation if exceeding max history
        if (rateHistory.length > MAX_HISTORY) {
            // Shift arrays by removing first element
            // This is gas-intensive but acceptable for MVP with 24 observations
            for (uint256 i = 0; i < rateHistory.length - 1; i++) {
                rateHistory[i] = rateHistory[i + 1];
                timestamps[i] = timestamps[i + 1];
            }
            rateHistory.pop();
            timestamps.pop();
        }

        emit RateUpdated(newRate, block.timestamp, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the current TWAP rate
     * @dev Calculates simple average of all stored rates
     * @return rate The TWAP anchor rate (scaled by 1e18)
     */
    function getRate() external view returns (uint256 rate) {
        require(!isStale(), "Oracle data is stale");
        require(rateHistory.length > 0, "No rate data available");

        // Calculate simple average
        uint256 sum = 0;
        for (uint256 i = 0; i < rateHistory.length; i++) {
            sum += rateHistory[i];
        }

        rate = sum / rateHistory.length;
    }

    /**
     * @notice Check if oracle data is stale
     * @dev Data is stale if last update was > STALE_THRESHOLD ago
     * @return True if data is stale
     */
    function isStale() public view returns (bool) {
        if (timestamps.length == 0) {
            return true;
        }

        uint256 lastUpdate = timestamps[timestamps.length - 1];
        return block.timestamp - lastUpdate > STALE_THRESHOLD;
    }

    /**
     * @notice Get the latest rate without staleness check
     * @dev Useful for off-chain monitoring
     * @return Latest rate in history
     */
    function getLatestRate() external view returns (uint256) {
        require(rateHistory.length > 0, "No rate data");
        return rateHistory[rateHistory.length - 1];
    }

    /**
     * @notice Get the timestamp of last update
     * @return Timestamp of last rate update
     */
    function getLastUpdateTime() external view returns (uint256) {
        require(timestamps.length > 0, "No timestamp data");
        return timestamps[timestamps.length - 1];
    }

    /**
     * @notice Get number of observations in history
     * @return Number of stored observations
     */
    function getHistoryLength() external view returns (uint256) {
        return rateHistory.length;
    }

    /**
     * @notice Get time until data becomes stale
     * @return Seconds until stale (0 if already stale)
     */
    function getTimeUntilStale() external view returns (uint256) {
        if (timestamps.length == 0) {
            return 0;
        }

        uint256 lastUpdate = timestamps[timestamps.length - 1];
        uint256 timeSinceUpdate = block.timestamp - lastUpdate;

        if (timeSinceUpdate >= STALE_THRESHOLD) {
            return 0;
        }

        return STALE_THRESHOLD - timeSinceUpdate;
    }

    /**
     * @notice Get all rate history (for debugging/monitoring)
     * @return rates Array of historical rates
     * @return times Array of timestamps
     */
    function getHistory() external view returns (uint256[] memory rates, uint256[] memory times) {
        return (rateHistory, timestamps);
    }
}
