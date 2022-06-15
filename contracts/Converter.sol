// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./Staking.sol";
import "./EnergyStorage.sol";
import "./helpers/IConverter.sol";
import "./helpers/IStaking.sol";
import "./helpers/TimeConstants.sol";
import "./helpers/Util.sol";
import "./helpers/PermissionControl.sol";
import "./interfaces/ILiquidityBootstrapAuction.sol";

/**
 * @dev ASM Genome Mining - Converter Logic contract
 *
 * This contracts provides functionality for ASTO Energy calculation and conversion.
 * Energy is calculated based on the token staking history from staking contract and multipliers pre-defined for ASTO and LP tokens.
 * Eenrgy can be consumed on multiple purposes.
 */
contract Converter is IConverter, IStaking, Util, PermissionControl, Pausable {
    using SafeMath for uint256;

    bool private _initialized = false;

    uint256 public periodIdCounter = 0;
    // PeriodId start from 1
    mapping(uint256 => Period) public periods;

    Staking public stakingLogic_;
    ILiquidityBootstrapAuction public lba_;
    EnergyStorage public energyStorage_;
    EnergyStorage public lbaEnergyStorage_;

    uint256 public constant ASTO_TOKEN_ID = 0;
    uint256 public constant LP_TOKEN_ID = 1;

    event EnergyUsed(address addr, uint256 amount);
    event LBAEnergyUsed(address addr, uint256 amount);
    event PeriodAdded(uint256 time, uint256 periodId, Period period);
    event PeriodUpdated(uint256 time, uint256 periodId, Period period);

    constructor(
        address controller,
        address lba,
        Period[] memory _periods
    ) {
        if (!_isContract(controller)) revert ContractError(INVALID_CONTROLLER);
        if (!_isContract(lba)) revert ContractError(INVALID_LBA_CONTRACT);
        lba_ = ILiquidityBootstrapAuction(lba);
        _setupRole(CONTROLLER_ROLE, controller);
        _setupRole(DAO_ROLE, controller);
        _setupRole(MULTISIG_ROLE, controller);
        _setupRole(CONSUMER_ROLE, controller);
        _addPeriods(_periods);
        _pause();
    }

    /** ----------------------------------
     * ! Business logic
     * ----------------------------------- */

    /**
     * @dev Get consumed energy amount for address `addr`
     *
     * @param addr The wallet address to get consumed energy for
     * @return Consumed energy amount
     */
    function getConsumedEnergy(address addr) public view returns (uint256) {
        if (address(addr) == address(0)) revert InvalidInput(WRONG_ADDRESS);
        return energyStorage_.consumedAmount(addr);
    }

    /**
     * @dev Get consumed LBA energy amount for address `addr`
     *
     * @param addr The wallet address to get consumed energy for
     * @return Consumed energy amount
     */
    function getConsumedLBAEnergy(address addr) public view returns (uint256) {
        if (address(addr) == address(0)) revert InvalidInput(WRONG_ADDRESS);
        return lbaEnergyStorage_.consumedAmount(addr);
    }

    /**
     * @dev Calculate the energy for `addr` based on the staking history  before the endTime of specified period
     *
     * @param addr The wallet address to calculated for
     * @param periodId The period id for energy calculation
     * @return energy amount
     */
    function calculateEnergy(address addr, uint256 periodId) public view returns (uint256) {
        if (address(addr) == address(0)) revert InvalidInput(WRONG_ADDRESS);
        if (periodId == 0 || periodId > periodIdCounter) revert ContractError(WRONG_PERIOD_ID);

        Period memory period = getPeriod(periodId);

        Stake[] memory astoHistory = stakingLogic_.getHistory(ASTO_TOKEN_ID, addr, period.endTime);
        Stake[] memory lpHistory = stakingLogic_.getHistory(LP_TOKEN_ID, addr, period.endTime);

        uint256 astoEnergyAmount = _calculateEnergyForToken(astoHistory, period.astoMultiplier);
        uint256 lpEnergyAmount = _calculateEnergyForToken(lpHistory, period.lpMultiplier);

        return (astoEnergyAmount + lpEnergyAmount);
    }

    /**
     * @dev Calculate the energy for specific staked token
     *
     * @param history The staking history for the staked token
     * @param multiplier The multiplier for staked token
     * @return total energy amount for the token
     */
    function _calculateEnergyForToken(Stake[] memory history, uint256 multiplier) internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = history.length; i > 0; i--) {
            if (currentTime() < history[i - 1].time) continue;

            uint256 elapsedTime = i == history.length
                ? currentTime().sub(history[i - 1].time)
                : history[i].time.sub(history[i - 1].time);

            total = total.add(elapsedTime.mul(history[i - 1].amount).mul(multiplier));
        }
        return total.div(SECONDS_PER_DAY);
    }

    /**
     * @dev Calculate available energy generated by keeping LP tokens in LBA contract
     *
     * @param addr The wallet address to calculated for
     * @param periodId The period id for energy calculation
     * @return energy amount
     */
    function calculateAvailableLBAEnergy(address addr, uint256 periodId) public view returns (uint256) {
        if (address(addr) == address(0)) revert InvalidInput(WRONG_ADDRESS);
        if (periodId == 0 || periodId > periodIdCounter) revert ContractError(WRONG_PERIOD_ID);

        Period memory period = getPeriod(periodId);

        uint256 lbaEnergyStartTime = lba_.lpTokenReleaseTime();
        if (currentTime() < lbaEnergyStartTime) return 0;

        uint256 elapsedTime = currentTime() - lbaEnergyStartTime;
        uint256 lbaLPAmount = lba_.claimableLPAmount(addr);

        return elapsedTime.mul(lbaLPAmount).mul(period.lbaLPMultiplier).div(SECONDS_PER_DAY);
    }

    /**
     * @dev Get the energy amount available for address `addr`
     *
     * @param addr The wallet address to get energy for
     * @param periodId The period id for energy calculation
     * @return Energy amount available
     */
    function getEnergy(address addr, uint256 periodId) public view returns (uint256) {
        return calculateEnergy(addr, periodId) - getConsumedEnergy(addr) + getRemainingLBAEnergy(addr, periodId);
    }

    /**
     * @dev Get remaining LBA energy amount available for address `addr` to spend
     *
     * @param addr The wallet address to get energy for
     * @param periodId The period id for energy calculation
     * @return Energy amount remaining
     */
    function getRemainingLBAEnergy(address addr, uint256 periodId) public view returns (uint256) {
        uint256 availableEnergy = calculateAvailableLBAEnergy(addr, periodId);
        uint256 consumedEnergy = getConsumedLBAEnergy(addr);
        if (availableEnergy > 0 && availableEnergy > consumedEnergy) return availableEnergy - consumedEnergy;
        return 0;
    }

    /**
     * @dev Consume energy generated before the endTime of period `periodId`
     * @dev Energy accumulated by keeping LP tokens in LBA contract will be consumed first
     *
     * @param addr The wallet address to consume from
     * @param periodId The period id for energy consumption
     * @param amount The amount of energy to consume
     */
    function useEnergy(
        address addr,
        uint256 periodId,
        uint256 amount
    ) external whenNotPaused onlyRole(CONSUMER_ROLE) {
        if (address(addr) == address(0)) revert InvalidInput(WRONG_ADDRESS);
        if (periodId == 0 || periodId > periodIdCounter) revert ContractError(WRONG_PERIOD_ID);
        if (amount > getEnergy(addr, periodId)) revert InvalidInput(WRONG_AMOUNT);

        uint256 remainingLBAEnergy = getRemainingLBAEnergy(addr, periodId);
        uint256 lbaEnergyToSpend = Math.min(amount, remainingLBAEnergy);

        // use LBA energy first
        if (lbaEnergyToSpend > 0) {
            lbaEnergyStorage_.increaseConsumedAmount(addr, lbaEnergyToSpend);
            emit LBAEnergyUsed(addr, lbaEnergyToSpend);
        }

        uint256 energyToSpend = amount - lbaEnergyToSpend;
        if (energyToSpend > 0) {
            energyStorage_.increaseConsumedAmount(addr, energyToSpend);
            emit EnergyUsed(addr, energyToSpend);
        }
    }

    /** ----------------------------------
     * ! Getters
     * ----------------------------------- */

    /**
     * @dev Get period data by period id `periodId`
     *
     * @param periodId The id of period to get
     * @return a Period struct
     */
    function getPeriod(uint256 periodId) public view returns (Period memory) {
        if (periodId == 0 || periodId > periodIdCounter) revert InvalidInput(WRONG_PERIOD_ID);
        return periods[periodId];
    }

    /**
     * @notice Get the current period based on current timestamp
     *
     * @return current period data
     */
    function getCurrentPeriod() external view returns (Period memory) {
        return periods[getCurrentPeriodId()];
    }

    /**
     * @notice Get the current period id based on current timestamp
     *
     * @return current periodId
     */
    function getCurrentPeriodId() public view returns (uint256) {
        for (uint256 index = 1; index <= periodIdCounter; index++) {
            Period memory p = periods[index];
            if (currentTime() >= uint256(p.startTime) && currentTime() < uint256(p.endTime)) {
                return index;
            }
        }
        return 0;
    }

    /**
     * @notice Get the current periodId based on current timestamp
     * @dev Can be overridden by child contracts
     *
     * @return current timestamp
     */
    function currentTime() public view virtual returns (uint256) {
        // solhint-disable-next-line not-rely-on-time
        return block.timestamp;
    }

    /** ----------------------------------
     * ! Administration         | Multisig
     * ----------------------------------- */

    /**
     * @dev Add new periods
     * @dev Only dao contract has the permission to call this function
     *
     * @param _periods The list of periods to be added
     */
    function addPeriods(Period[] memory _periods) external onlyRole(MULTISIG_ROLE) {
        _addPeriods(_periods);
    }

    /**
     * @dev Add a new period
     * @dev Only dao contract has the permission to call this function
     *
     * @param period The period instance to add
     */
    function addPeriod(Period memory period) external onlyRole(MULTISIG_ROLE) {
        _addPeriod(period);
    }

    /**
     * @dev Update a period
     * @dev Only dao contract has the permission to call this function
     *
     * @param periodId The period id to update
     * @param period The period data to update
     */
    function updatePeriod(uint256 periodId, Period memory period) external onlyRole(MULTISIG_ROLE) {
        _updatePeriod(periodId, period);
    }

    /**
     * @dev Add new periods
     * @dev This is a private function, can only be called in this contract
     *
     * @param _periods The list of periods to be added
     */
    function _addPeriods(Period[] memory _periods) internal {
        for (uint256 i = 0; i < _periods.length; i++) {
            _addPeriod(_periods[i]);
        }
    }

    /**
     * @dev Add a new period
     * @dev This is an internal function
     *
     * @param period The period instance to add
     */
    function _addPeriod(Period memory period) internal {
        periods[++periodIdCounter] = period;
        emit PeriodAdded(currentTime(), periodIdCounter, period);
    }

    /**
     * @dev Update a period
     * @dev This is an internal function
     *
     * @param periodId The period id to update
     * @param period The period data to update
     */
    function _updatePeriod(uint256 periodId, Period memory period) internal {
        if (periodId == 0 || periodId > periodIdCounter) revert ContractError(WRONG_PERIOD_ID);
        periods[periodId] = period;
        emit PeriodUpdated(currentTime(), periodId, period);
    }

    /** ----------------------------------
     * ! Administration       | CONTROLLER
     * ----------------------------------- */

    /**
     * @dev Initialize the contract:
     * @dev only controller is allowed to call this function
     *
     * @param dao The dao contract address
     * @param energyStorage The energy storage contract address
     * @param stakingLogic The staking logic contrct address
     */
    function init(
        address dao,
        address multisig,
        address energyStorage,
        address lbaEnergyStorage,
        address stakingLogic
    ) external onlyRole(CONTROLLER_ROLE) {
        if (!_initialized) {
            if (!_isContract(energyStorage)) revert ContractError(INVALID_ENERGY_STORAGE);
            if (!_isContract(lbaEnergyStorage)) revert ContractError(INVALID_LBA_ENERGY_STORAGE);
            if (!_isContract(stakingLogic)) revert ContractError(INVALID_STAKING_LOGIC);

            stakingLogic_ = Staking(stakingLogic);
            energyStorage_ = EnergyStorage(energyStorage);
            lbaEnergyStorage_ = EnergyStorage(lbaEnergyStorage);

            _clearRole(DAO_ROLE);
            _grantRole(DAO_ROLE, dao);

            _clearRole(MULTISIG_ROLE);
            _grantRole(MULTISIG_ROLE, multisig);

            _initialized = true;
        }
    }

    /**
     * @dev Update the DAO contract address
     * @dev only Controller is allowed to change the address of DAO contract
     */
    function setDao(address newDao) external onlyRole(CONTROLLER_ROLE) {
        _clearRole(DAO_ROLE);
        _grantRole(DAO_ROLE, newDao);
    }

    /**
     * @dev Update the Multisig contract address
     * @dev only Controller is allowed to change the address of Multisig contract
     */
    function setMultisig(address newMultisig, address dao) external onlyRole(CONTROLLER_ROLE) {
        _clearRole(MULTISIG_ROLE);
        _grantRole(MULTISIG_ROLE, newMultisig);
        _grantRole(MULTISIG_ROLE, dao);
    }

    /**
     * @dev Update the Controller contract address
     * @dev only controller is allowed to call this function
     */
    function setController(address newController) external onlyRole(CONTROLLER_ROLE) {
        _clearRole(CONTROLLER_ROLE);
        _grantRole(CONTROLLER_ROLE, newController);
    }

    /**
     * @dev Update the Consumer contract address
     * @dev only controller is allowed to call this function
     */
    function setConsumer(address consumer) external onlyRole(CONTROLLER_ROLE) {
        _clearRole(CONSUMER_ROLE);
        _grantRole(CONSUMER_ROLE, consumer);
    }

    /**
     * @dev Pause the contract
     * @dev only controller is allowed to call this function
     */
    function pause() external onlyRole(CONTROLLER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause the contract
     * @dev only controller is allowed to call this function
     */
    function unpause() external onlyRole(CONTROLLER_ROLE) {
        _unpause();
    }
}
