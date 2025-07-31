// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "../contracts/interfaces/IERC20.sol";

/**
 * @title AlvaStaking
 * @notice This contract enables staking of ALVA tokens and generates rewards in veALVA.
 *         It includes time-based and forever locks, reward distribution, and role-based access control.
 * @dev Uses OpenZeppelin's upgradeable libraries for role and pause functionalities.
 */

contract AlvaStaking is
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    // --- State Variables ---
    /// @notice Interface of the ALVA token contract.
    IERC20 public ALVA;

    /// @notice Interface of the veALVA token contract for voting power.
    IERC20 public veALVA;

    /// @notice Ratio factor for calculating veALVA from staked ALVA (1e8 scale).
    uint public constant RATIO_FACTOR = 10 ** 8;

    /// @notice Percentage precision factor for pool rewards (1e7 scale).
    uint public constant PERCENTAGE_FACTOR = 10 ** 7;

    /// @notice Reward period duration in seconds
    uint public constant REWARD_PERIOD = 1 weeks; 

    /// @notice Role that allows pausing/unpausing the contract.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Role that allows admin-level operations.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Role that allows adding rewards to the contract.
    bytes32 public constant REWARDS_ALLOCATOR_ROLE =
        keccak256("REWARDS_ALLOCATOR_ROLE");

    /**
     * @dev Structure representing data for staking pools.
     */
    struct poolData {
        bool status; // Pool availability status.
        uint veAlvaRatio; // Conversion ratio of veALVA tokens per ALAVA token staked.
        uint poolPercentage; // Percentage of rewards allocated to this pool.
        uint duration; // Duration of the staking lock for this pool.
        uint amountLocked; // Total amount of tokens locked in this pool.
        uint rewardPeriods; // Reward distribution frequency for the pool.
    }

    /**
     * @dev Structure representing data for individual locks.
     */
    struct lockData {
        string pool; // Name of the staking pool.
        uint amount; // Total amount of tokens staked in this lock.
        bool isForever; // Indicates whether this is a forever lock.
        bool isActive; // Indicates if the lock is active.
        uint duration; // Duration of the lock (0 for forever locks)
        uint startTime; // Lock start time (timestamp)
        uint endTime; // Lock end time (timestamp).
        uint votingPower; // veALVA voting power granted by this lock.
        uint rewardsCurrent; // Total rewards for this lock.
        uint openingRewardId; // First reward ID applicable to this lock.
        uint closingRewardId; // Last reward ID applicable to this lock.
        uint totalIncremented; // Tracks total increments to this lock's amount.
        mapping(uint => uint) rewardIdToIncrementedAmount; // Rewards added after increments.
    }

    /**
     * @dev Structure representing data for reward periods.
     */
    struct rewardData {
        bool isProcessed; // Indicates whether rewards have been processed.
        uint timestamp; // Timestamp for this reward period.
        uint amount; // Total rewards distributed in this period.
        mapping(string => uint) poolToAmountLocked; // Tokens locked in each pool during this period.
        mapping(string => uint) poolToNewAmount; // Newly added tokens in this period.
        mapping(string => uint) poolToExpiredAmount; // Tokens expired from locks during this period.
    }

    /// @notice List of all pools. Always include "FOREVER" at the beginning.
    string[] public Pools;

    /// @notice Tracks the current lock ID (incremented for each new lock).
    uint public currentIdLock;

    /// @notice Tracks the current reward ID (incremented for each reward period).
    uint public currentIdRewards;

    /// @notice Time interval for decaying veALVA voting power.
    uint public decayInterval;

    /// @notice Minimum staking amount required for participation.
    uint public minimumStakingAmount;

    /// @notice Minimum reward amount required for allocating rewards.
    uint public minimumRewardAmount;

    /// @notice Percentage of total balance of reward vault to be allocated for reward distribution.
    uint public vaultWithdrawalPercentage;

    /// @notice Start time for reward distribution.
    uint public startTime;

    /// @notice Total unallocated rewards available for distribution.
    uint public unallocatedRewards;

    /// --- Mappings ---
    /// @notice Maps user addresses to their list of lock IDs.
    mapping(address => uint[]) public accountToLockIds;

    /// @notice Maps user addresses to their list of lock IDs that are eligible for rewards.
    mapping(address => uint[]) public rewardEligibleLocks;

    /// @notice Maps user addresses to their finalized lock ID
    mapping(address => uint) public accountToIdFinalized;

    /// @notice Maps user addresses to their pending reward amounts.
    mapping(address => uint) public accountTocalculatedRewards;

    /// @notice Maps user addresses to their forever lock ID.
    mapping(address => uint) public accountToForeverId;

    /// @notice Maps pool names to their corresponding data.
    mapping(string => poolData) public poolToPoolData;

    /// @notice Maps lock IDs to their corresponding lock data.
    mapping(uint => lockData) public lockIdToLockData;

    /// @notice Maps reward IDs to their corresponding reward data.
    mapping(uint => rewardData) public rewardIdToRewardData;

    /// --- Events ---
    /// @notice Emitted when tokens are staked in a pool.
    event TokensStaked(
        uint indexed lockId,
        address indexed account,
        uint amount,
        string pool,
        uint veAlva
    );

    /// @notice Emitted when the staked amount is increased for an existing lock.
    event StakedAmountIncreased(uint indexed lockId, uint amount, uint veAlva);

    /// @notice Emitted when an active lock is renewed.
    event LockRenewed(uint indexed previousLockId, uint indexed newLockId);

    /// @notice Emitted when rewards are compounded.
    event Compounded(
        uint indexed lockId,
        uint amount,
        uint rewardAmount,
        uint veAlva
    );

    /// @notice Emitted when a user withdraws their tokens after lock expiry.
    event Withdrawn(address indexed account, uint indexed lockId, uint endTime);

    /// @notice Emitted when a user claims their rewards.
    event RewardsClaimed(address indexed account, uint rewardAmount);

    /// @notice Emitted when new rewards are added to the system.
    event RewardsAdded(uint indexed rewardId, uint amount);

    constructor() {
        _disableInitializers(); // Locks the implementation
    }

    /// --- Functions ---
    /**
     * @notice Initializes the staking contract with required parameters.
     * @param _alva Address of the ALVA token contract.
     * @param _veAlva Address of the veALVA token contract.
     * @param _decayInterval Interval for decaying veALVA power.
     * @param _startTime Start time for rewards distribution.
     * @param _pools List of pool names.
     * @param rewards Array of reward percentages for each pool.
     * @param veTokenRatio Array of veALVA ratios for each pool.
     * @param duration Array of durations (in seconds) for each pool.
     * @param rewardPeriods Array of reward periods for each pool.
     */
    function initialize(
        address _alva,
        address _veAlva,
        uint _decayInterval,
        uint _startTime,
        string[] memory _pools,
        uint[] memory rewards,
        uint[] memory veTokenRatio, 
        uint[] memory duration,
        uint[] memory rewardPeriods
    ) external initializer {
        require(_alva != address(0), "Invalid ALVA token address");
        require(_veAlva != address(0), "Invalid veALVA token address");

        ALVA = IERC20(_alva);
        veALVA = IERC20(_veAlva);
        decayInterval = _decayInterval;
        startTime = _startTime;
        minimumStakingAmount = 1;
        minimumRewardAmount = 10000;
        vaultWithdrawalPercentage = 5000000; 

        // Grant Roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender /*defaultAdmin*/);
        _grantRole(PAUSER_ROLE, msg.sender /*pauser*/);
        _grantRole(ADMIN_ROLE, msg.sender /*admin*/);
        _grantRole(REWARDS_ALLOCATOR_ROLE, msg.sender /*rewardsAllocator*/);

        require(duration[0] == 0, "Invalid Durations");
        uint totalRewardPercentage;
        Pools = _pools;
        for (uint i; i < _pools.length; i++) {
            poolToPoolData[_pools[i]].veAlvaRatio = veTokenRatio[i];
            poolToPoolData[_pools[i]].poolPercentage = rewards[i];
            poolToPoolData[_pools[i]].duration = duration[i];
            poolToPoolData[_pools[i]].status = true;
            poolToPoolData[_pools[i]].rewardPeriods = rewardPeriods[i];
            totalRewardPercentage += rewards[i];
        }
        require(totalRewardPercentage == PERCENTAGE_FACTOR, "Invalid Rewards");
    }

    /**
     * @notice Allows users to stake ALVA tokens into a specified pool.
     * @dev Staking requires the pool to be active and the amount to meet the minimum staking requirement.
     * @param amount The amount of ALVA tokens to stake.
     * @param pool The name of the pool where the tokens will be staked.
     */
    function stake(uint amount, string memory pool) public whenNotPaused {
        require(
            amount >= minimumStakingAmount,
            "Amount is below the minimum required"
        );
        _stake(amount, 0, 0, pool, rewardPeriodCount());
    }

    /**
     * @notice Allows users to increase the staked amount.
     * @dev Handles both forever and time-based locks. Also finalizes pending rewards before updating the lock.
     * @param amount The additional amount to be staked.
     * @param isForever A boolean indicating whether the lock is a forever lock.
     */
    function increaseAmount(uint amount, bool isForever) public whenNotPaused {
        uint lockId;
        if (isForever) {
            lockId = accountToForeverId[msg.sender];
            require(lockId != 0, "No active forever lock exists for the user");
            ALVA.burnFrom(msg.sender, amount);
        } else {
            lockId = getActiveTimeBaseLock(msg.sender);

            // if lock is ended then don't entertain increase
            require(
                lockId != 0 &&
                    lockIdToLockData[lockId].endTime > block.timestamp,
                "No Active lock exists"
            );
            ALVA.transferFrom(msg.sender, address(this), amount);
        }

        _increaseAmount(amount, lockId);

        emit StakedAmountIncreased(
            lockId,
            lockIdToLockData[lockId].amount,
            lockIdToLockData[lockId].votingPower
        );
    }

    /**
     * @notice Allows users to renew their current time-based lock into a new lock with updated parameters.
     * @dev The new lock must have a duration greater than or equal to the existing lock's duration.
     * @param amount The amount of ALVA tokens to stake in the new lock.
     * @param pool The name of the pool where the lock will be renewed.
     */
    function renewStaking(
        uint amount,
        string memory pool
    ) public whenNotPaused {
        uint activeLock = getActiveTimeBaseLock(msg.sender);
        require(
            activeLock != 0 &&
                lockIdToLockData[activeLock].endTime > block.timestamp,
            "No active lock found"
        );
        require(
            poolToPoolData[pool].duration >=
                lockIdToLockData[activeLock].duration,
            "Lock duration cannot be less than existing lock"
        );

        uint previousAmount = lockIdToLockData[activeLock].amount;
        string memory poolActiveLock = lockIdToLockData[activeLock].pool;

        //END the existing Lock
        lockIdToLockData[activeLock].isActive = false;
        lockIdToLockData[activeLock].endTime = block.timestamp;

        uint currentRewardId = rewardPeriodCount();

        if (lockIdToLockData[activeLock].closingRewardId > currentRewardId) {
            rewardIdToRewardData[lockIdToLockData[activeLock].closingRewardId]
                .poolToExpiredAmount[poolActiveLock] -= previousAmount;
            lockIdToLockData[activeLock].closingRewardId = currentRewardId;
            rewardIdToRewardData[currentRewardId].poolToExpiredAmount[
                    poolActiveLock
                ] += previousAmount;
            if (
                lockIdToLockData[activeLock].openingRewardId ==
                lockIdToLockData[activeLock].closingRewardId &&
                rewardEligibleLocks[msg.sender].length > 0
            ) {
                rewardEligibleLocks[msg.sender].pop();
            }
        }

        //New Lock
        _stake(
            amount,
            previousAmount,
            lockIdToLockData[activeLock].votingPower,
            pool,
            currentRewardId
        );

        emit LockRenewed(activeLock, currentIdLock);
    }

    /**
     * @notice Allows users to unstake their tokens after the lock has expired.
     * @dev Only applicable to time-based locks. Forever locks cannot be unstaked.
     */
    function unstake() public whenNotPaused {
        uint activeLock = getActiveTimeBaseLock(msg.sender);
        require(activeLock != 0, "No active lock found");
        require(
            block.timestamp > lockIdToLockData[activeLock].endTime,
            "Cannot unstake before the lock end time"
        );

        ALVA.transfer(msg.sender, lockIdToLockData[activeLock].amount);
        veALVA.burnTokens(msg.sender, lockIdToLockData[activeLock].votingPower);
        lockIdToLockData[activeLock].isActive = false;

        emit Withdrawn(
            msg.sender,
            activeLock,
            lockIdToLockData[activeLock].endTime
        );
    }

    /**
     * @notice Allows users to claim their accumulated rewards.
     */
    function claimRewards() public whenNotPaused {
        uint reward = _claimRewards();
        ALVA.transfer(msg.sender, reward);
        emit RewardsClaimed(msg.sender, reward);
    }

    /**
     * @notice Allows users to compound their rewards into an existing lock.
     * @dev Handles both forever and time-based locks. Rewards are added to the locked amount.
     * @param isForever A boolean indicating whether the lock is a forever lock.
     */
    function compoundRewards(bool isForever) public whenNotPaused {
        uint reward = _claimRewards();

        uint lockId;
        if (isForever) {
            lockId = accountToForeverId[msg.sender];
            require(lockId != 0, "No active forever lock exists for the user");
            ALVA.burn(reward);
        } else {
            lockId = getActiveTimeBaseLock(msg.sender);
            require(
                lockId != 0 &&
                    lockIdToLockData[lockId].endTime > block.timestamp,
                "No Active lock exists"
            );
        }

        _increaseAmount(reward, lockId);

        emit Compounded(
            lockId,
            lockIdToLockData[lockId].amount,
            reward,
            lockIdToLockData[lockId].votingPower
        );
    }

    /**
     * @notice Allows authorized accounts to add rewards for distribution.
     * @dev Can only be called by accounts with the REWARDS_ALLOCATOR_ROLE.
     */
    function topUpRewards()
        public
        onlyRole(REWARDS_ALLOCATOR_ROLE)
        whenNotPaused
    {
        uint amount = (ALVA.balanceOf(msg.sender) * vaultWithdrawalPercentage) /
            PERCENTAGE_FACTOR;

        require(
            amount >= minimumRewardAmount,
            "Reward must be at least the minimum amount"
        );

        uint _currentIdRewards = currentIdRewards;
        require(
            _currentIdRewards < rewardPeriodCount(),
            "Cannot process before time"
        );

        ALVA.transferFrom(msg.sender, address(this), amount);

        uint _unallocatedRewards = unallocatedRewards;
        amount += _unallocatedRewards;
        _unallocatedRewards = 0;

        rewardIdToRewardData[_currentIdRewards].amount = amount;
        rewardIdToRewardData[_currentIdRewards].timestamp =
            startTime +
            ((_currentIdRewards + 1) * REWARD_PERIOD);

        for (uint i = 0; i < Pools.length; i++) {
            poolToPoolData[Pools[i]].amountLocked += rewardIdToRewardData[
                _currentIdRewards
            ].poolToNewAmount[Pools[i]];

            if (i != 0) {
                poolToPoolData[Pools[i]].amountLocked -= rewardIdToRewardData[
                    _currentIdRewards
                ].poolToExpiredAmount[Pools[i]];
            }

            rewardIdToRewardData[_currentIdRewards].poolToAmountLocked[
                    Pools[i]
                ] = poolToPoolData[Pools[i]].amountLocked;

            if (poolToPoolData[Pools[i]].amountLocked == 0) {
                _unallocatedRewards +=
                    (amount * poolToPoolData[Pools[i]].poolPercentage) /
                    PERCENTAGE_FACTOR;
            }
        }

        unallocatedRewards = _unallocatedRewards;

        emit RewardsAdded(_currentIdRewards, amount);
        rewardIdToRewardData[_currentIdRewards].isProcessed = true;
        currentIdRewards++;
    }

    // --- Internal and Helper Functions ---
    /**
     * @notice Internal function to handle the staking logic for users.
     * @dev Handles both new staking and lock renewal logic.
     * @param amountNew The new amount to be staked.
     * @param amountOld The previously staked amount (if renewing).
     * @param votingPowerOld The previous veALVA voting power (if renewing).
     * @param pool The name of the pool where staking is happening.
     */
    function _stake(
        uint amountNew,
        uint amountOld,
        uint votingPowerOld,
        string memory pool,
        uint currentRewardId
    ) internal {
        require(
            poolToPoolData[pool].status,
            "The pool is not available for staking"
        );

        currentIdLock++;
        uint rewardIdExpired = currentRewardId + poolToPoolData[pool].rewardPeriods;

        uint amountTotal = amountNew + amountOld;
        uint votingPowerTotal = getveAlvaAmount(amountTotal, pool);
        if (votingPowerTotal > votingPowerOld)
            veALVA.mint(msg.sender, votingPowerTotal - votingPowerOld);

        //CHECK THAT USER DOES NOT HAVE ANY ACTIVE STAKING
        if (poolToPoolData[pool].duration != 0) {
            require(
                getActiveTimeBaseLock(msg.sender) == 0,
                "Timebase lock already exists"
            );

            accountToLockIds[msg.sender].push(currentIdLock);

            if(poolToPoolData[pool].poolPercentage > 0)
                rewardEligibleLocks[msg.sender].push(currentIdLock);

            if (amountNew > 0)
                ALVA.transferFrom(msg.sender, address(this), amountNew);

            rewardIdToRewardData[rewardIdExpired].poolToExpiredAmount[
                    pool
                ] += amountTotal;
        } else {
            require(
                accountToForeverId[msg.sender] == 0,
                "Forever lock already exists"
            );
            accountToForeverId[msg.sender] = currentIdLock;
            lockIdToLockData[currentIdLock].isForever = true;
            ALVA.burnFrom(msg.sender, amountTotal);
        }

        lockIdToLockData[currentIdLock].pool = pool;
        lockIdToLockData[currentIdLock].amount = amountTotal;
        lockIdToLockData[currentIdLock].duration = poolToPoolData[pool]
            .duration;
        lockIdToLockData[currentIdLock].startTime = block.timestamp;
        lockIdToLockData[currentIdLock].endTime =
            block.timestamp +
            poolToPoolData[pool].duration;
        lockIdToLockData[currentIdLock].votingPower = votingPowerTotal;
        lockIdToLockData[currentIdLock].isActive = true;

        lockIdToLockData[currentIdLock].openingRewardId = currentRewardId;
        lockIdToLockData[currentIdLock].closingRewardId = rewardIdExpired;

        rewardIdToRewardData[currentRewardId].poolToNewAmount[
            pool
        ] += amountTotal;

        emit TokensStaked(
            currentIdLock,
            msg.sender,
            amountTotal,
            pool,
            votingPowerTotal
        );
    }

    /**
     * @notice Internal function to increase the staked amount in an existing lock.
     * @param amount The additional amount to be staked.
     * @param lockId The ID of the lock to be updated.
     */
    function _increaseAmount(uint amount, uint lockId) internal {
        require(
            amount >= minimumStakingAmount,
            "Amount is below the minimum required"
        );

        string memory poolActiveLock = lockIdToLockData[lockId].pool;
        require(
            poolToPoolData[poolActiveLock].status,
            "Pool is currently disabled"
        );

        uint veALVANew = getveAlvaAmount(amount, poolActiveLock);
        veALVA.mint(msg.sender, veALVANew);

        lockIdToLockData[lockId].amount += amount;
        lockIdToLockData[lockId].votingPower += veALVANew;

        uint rewardIdCurrent = rewardPeriodCount();
        uint closingRewardId = lockIdToLockData[lockId].closingRewardId;

        if (closingRewardId >= rewardIdCurrent || lockIdToLockData[lockId].isForever) {
            rewardIdToRewardData[rewardIdCurrent].poolToNewAmount[
                poolActiveLock
            ] += amount;

            rewardIdToRewardData[closingRewardId].poolToExpiredAmount[
                poolActiveLock
            ] += amount;
        }

        lockIdToLockData[lockId].totalIncremented += amount;
        lockIdToLockData[lockId].rewardIdToIncrementedAmount[
                rewardIdCurrent
            ] = lockIdToLockData[lockId].totalIncremented;
    }

    /**
     * @notice Internal function to claim rewards for a user.
     * @return reward The total reward amount claimed.
     */
    function _claimRewards() internal returns (uint reward) {
        if (
            rewardEligibleLocks[msg.sender].length >
            accountToIdFinalized[msg.sender]
        ) {
            _finalizeTimeBaseRewards(
                rewardEligibleLocks[msg.sender][accountToIdFinalized[msg.sender]]
            );
        }

        _finalizeForeverLockRewards();

        reward = accountTocalculatedRewards[msg.sender];

        require(reward > 0, "No rewards available for claiming");

        //Reset the Pending to Zero
        accountTocalculatedRewards[msg.sender] = 0;
    }

    /**
     * @notice Internal function to finalize time-based rewards for a specific lock.
     * @param lockId The ID of the lock for which rewards are finalized.
     */
    function _finalizeTimeBaseRewards(uint lockId) internal {
        if (
            lockId != 0 &&
            lockIdToLockData[lockId].openingRewardId <
            lockIdToLockData[lockId].closingRewardId
        ) {
            uint rewardAmount;
            uint incrementedAmount;
            (
                rewardAmount,
                lockIdToLockData[lockId].openingRewardId,
                incrementedAmount
            ) = countRewards(lockId, 10);

            lockIdToLockData[lockId].rewardsCurrent += rewardAmount;
            accountTocalculatedRewards[msg.sender] += rewardAmount;
            lockIdToLockData[lockId].rewardIdToIncrementedAmount[
                    lockIdToLockData[lockId].openingRewardId
                ] = incrementedAmount;

            if (
                lockIdToLockData[lockId].openingRewardId ==
                lockIdToLockData[lockId].closingRewardId
            ) {
                accountToIdFinalized[msg.sender]++;
            }
        }
    }

    /**
     * @notice Internal function to finalize rewards for forever locks.
     */
    function _finalizeForeverLockRewards() internal {
        uint lockId = accountToForeverId[msg.sender];
        if (
            lockId != 0 &&
            lockIdToLockData[lockId].openingRewardId < currentIdRewards
        ) {
            uint rewardAmount;
            uint incrementedAmount;
            (
                rewardAmount,
                lockIdToLockData[lockId].openingRewardId,
                incrementedAmount
            ) = countRewards(lockId, 10);

            lockIdToLockData[lockId].rewardsCurrent += rewardAmount;
            accountTocalculatedRewards[msg.sender] += rewardAmount;
            lockIdToLockData[lockId].rewardIdToIncrementedAmount[
                    lockIdToLockData[lockId].openingRewardId
                ] = incrementedAmount;
        }
    }

    /**
     * @notice Calculates the rewards for a specific reward ID and lock.
     * @param rewardId The ID of the reward period.
     * @param lockId The ID of the lock for which rewards are calculated.
     * @param incrementedAmount The incremented amount in the lock for this reward period.
     * @return rewards The calculated rewards for the given lock and reward period.
     */
    function _calculateRewards(
        uint rewardId,
        uint lockId,
        uint incrementedAmount
    ) internal view returns (uint rewards) {
        string memory pool = lockIdToLockData[lockId].pool;

        uint amountAtGivenRewardId = lockIdToLockData[lockId].amount -
            (lockIdToLockData[lockId].totalIncremented - incrementedAmount);

        rewards =
            (((rewardIdToRewardData[rewardId].amount *
                poolToPoolData[pool].poolPercentage) * amountAtGivenRewardId) /
                rewardIdToRewardData[rewardId].poolToAmountLocked[pool]) /
            PERCENTAGE_FACTOR;
    }

    // --- SETTERS ---

    /**
     * @notice Updates the minimum reward amount required for allocating rewards.
     * @dev This function can only be called by an account with the ADMIN_ROLE.
     * @param amount The new minimum reward amount to be set.
     */
    function updateMinimumRewardAmount(
        uint amount
    ) public onlyRole(ADMIN_ROLE) {
        minimumRewardAmount = amount;
    }

    /**
     * @notice Updates the active status of a specific pool.
     * @dev This function can only be called by an account with the ADMIN_ROLE.
     * @param pool The name of the pool to update.
     * @param status The new status of the pool (true = active, false = inactive).
     */
    function updatePoolStatus(
        string memory pool,
        bool status
    ) public onlyRole(ADMIN_ROLE) {
        // Verify that the pool exists in the Pools array
        bool exists = false;
        uint lenght = Pools.length;
        for (uint256 i = 0; i < lenght; i++) {
            if (
                keccak256(abi.encodePacked(Pools[i])) ==
                keccak256(abi.encodePacked(pool))
            ) {
                exists = true;
                break;
            }
        }
        require(exists, "Pool does not exist");

        // Update the status of the pool
        poolToPoolData[pool].status = status;
    }

    /**
     * @notice Updates the minimum staking amount for all pools.
     * @dev This function can only be called by an account with the ADMIN_ROLE.
     * @param amount The new minimum staking amount.
     */
    function updateMinStakingAmount(uint amount) public onlyRole(ADMIN_ROLE) {
        require(amount >= 1, "Minimum amount must be at least 1");
        minimumStakingAmount = amount;
    }

    /**
     * @notice Updates the withdrawal percentage applied to the balance of reward vault for reward allocation.
     * @dev This function can only be called by an account with the ADMIN_ROLE.
     * @param amount The new withdrawal percentage, scaled by the PERCENTAGE_FACTOR for precision.
     */
    function updateWithdrawalPercentage(
        uint amount
    ) public onlyRole(ADMIN_ROLE) {
        require(amount <= PERCENTAGE_FACTOR, "Invalid percentage value");
        vaultWithdrawalPercentage = amount;
    }

    /**
     * @notice Updates the decay interval for veALVA voting power.
     * @dev This function can only be called by an account with the ADMIN_ROLE.
     * @param newInterval The new decay interval in seconds.
     */
    function updateDecayInterval(uint newInterval) public onlyRole(ADMIN_ROLE) {
        require(
            newInterval > 0 && newInterval <= 1 weeks,
            "Interval should be within the valid range"
        );
        decayInterval = newInterval;
    }

    /**
     * @notice Pauses all contract functionality.
     * @dev This function can only be called by an account with the PAUSER_ROLE.
     */
    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses all contract functionalities.
     * @dev This function can only be called by an account with the PAUSER_ROLE.
     */
    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // --- GETTERS ---

    /**
     * @notice Calculates the rewards for a specific lock based on the current reward state.
     * @param lockId The ID of the lock for which rewards are being calculated.
     * @return pendingCurrent The total pending rewards for the lock.
     * @return openingRewardId The next reward ID that needs processing for this lock.
     * @return incrementedAmount The incremented amount applicable for rewards calculation.
     */

    function countRewards(
        uint lockId,
        uint batchSize
    )
        public
        view
        returns (
            uint pendingCurrent,
            uint openingRewardId,
            uint incrementedAmount
        )
    {
        lockData storage _lockData = lockIdToLockData[lockId];

        require(_lockData.amount > 0, "Invalid Lock Id");

        uint closingId = _lockData.isForever
            ? currentIdRewards
            : _lockData.closingRewardId;
        openingRewardId = _lockData.openingRewardId;

        uint endingId = openingRewardId + batchSize;

        incrementedAmount = _lockData.rewardIdToIncrementedAmount[
            openingRewardId
        ];

        for (
            ;
            endingId > openingRewardId && closingId > openingRewardId;
            openingRewardId++
        ) {
            if (rewardIdToRewardData[openingRewardId].timestamp == 0) break;
            pendingCurrent += _calculateRewards(
                openingRewardId,
                lockId,
                incrementedAmount
            );

            if (_lockData.rewardIdToIncrementedAmount[openingRewardId] > 0)
                incrementedAmount = _lockData.rewardIdToIncrementedAmount[
                    openingRewardId
                ];
        }
    }

    /**
     * @notice Retrieves the total pending rewards for a specific account.
     * @param account The address of the account.
     * @return totalReward The total pending rewards for the account.
     */
    function getRewardsPending(
        address account
    ) public view returns (uint totalReward) {
        uint timebaseReward;
        uint foreverLockReward;
        for (
            uint currentIndex = accountToIdFinalized[account];
            currentIndex < rewardEligibleLocks[account].length;
            currentIndex++
        ) {
            (uint reward, , ) = countRewards(
                rewardEligibleLocks[account][currentIndex],
                lockIdToLockData[rewardEligibleLocks[account][currentIndex]]
                    .closingRewardId -
                    lockIdToLockData[rewardEligibleLocks[account][currentIndex]]
                        .openingRewardId
            );
            timebaseReward += reward;
        }

        if (
            accountToForeverId[account] > 0 &&
            currentIdRewards >
            lockIdToLockData[accountToForeverId[account]].openingRewardId
        ) {
            (foreverLockReward, , ) = countRewards(
                accountToForeverId[account],
                currentIdRewards -
                    lockIdToLockData[accountToForeverId[account]]
                        .openingRewardId
            );
        }

        totalReward =
            timebaseReward +
            foreverLockReward +
            accountTocalculatedRewards[account];
    }

    /**
     * @notice Retrieves the active time-based lock ID for a specific account.
     * @param account The address of the account.
     * @return timebaseId The ID of the active time-based lock.
     */
    function getActiveTimeBaseLock(
        address account
    ) public view returns (uint timebaseId) {
        uint locksLength = accountToLockIds[account].length;
        if (locksLength > 0) {
            if (
                lockIdToLockData[accountToLockIds[account][locksLength - 1]]
                    .isActive
            ) {
                timebaseId = accountToLockIds[account][locksLength - 1];
            }
        }
    }

    /**
     * @notice Calculates the veALVA voting power for a given amount in a specific pool.
     * @param amount The amount of ALVA tokens staked.
     * @param pool The name of the pool.
     * @return The calculated veALVA voting power.
     */
    function getveAlvaAmount(
        uint amount,
        string memory pool
    ) public view returns (uint) {
        return (amount * poolToPoolData[pool].veAlvaRatio) / RATIO_FACTOR;
    }

    /**
     * @notice Calculates the current reward period ID based on the contract's start time.
     * @return The current reward period ID.
     */
    function rewardPeriodCount() public view returns (uint) {
        return (block.timestamp - startTime) / REWARD_PERIOD;
    }

    /**
     * @notice Retrieves the current veALVA balance of a user, accounting for decay.
     * @param account The address of the user.
     * @return balance The user's current veALVA balance.
     */
    function veAlvaBalance(address account) external view returns (uint) {
        uint activeLock = getActiveTimeBaseLock(account);
        uint balance = lockIdToLockData[activeLock].votingPower;

        if (lockIdToLockData[activeLock].startTime > 0) {
            uint intervalsPassed = (block.timestamp -
                lockIdToLockData[activeLock].startTime) / decayInterval;
            uint totalIntervals = lockIdToLockData[activeLock].duration /
                decayInterval;
            if (totalIntervals > intervalsPassed) {
                balance =
                    (balance * (totalIntervals - intervalsPassed)) /
                    totalIntervals;
            } else balance = 0;
        }

        return
            balance + lockIdToLockData[accountToForeverId[account]].votingPower;
    }

    /**
     * @notice Retrieves the incremented amount for a specific lock and reward ID.
     * @param lockId The ID of the lock.
     * @param rewardId The ID of the reward period.
     * @return amount The incremented amount for the lock during the reward period.
     */
    function getIncrementedAmount(
        uint lockId,
        uint rewardId
    ) external view returns (uint amount) {
        amount = lockIdToLockData[lockId].rewardIdToIncrementedAmount[rewardId];
    }

    /**
     * @notice Retrieves pool data for a specific reward period.
     * @param rewardId The ID of the reward period.
     * @param pool The name of the pool.
     * @return (amountLocked, newAmount, expiredAmount) The locked, new, and expired amounts for the pool.
     */
    function getPoolDataByRewardId(
        uint rewardId,
        string memory pool
    ) external view returns (uint, uint, uint) {
        return (
            rewardIdToRewardData[rewardId].poolToAmountLocked[pool],
            rewardIdToRewardData[rewardId].poolToNewAmount[pool],
            rewardIdToRewardData[rewardId].poolToExpiredAmount[pool]
        );
    }

    /**
     * @notice Retrieves number of locks total and reward eligible locks of Account.
     * @param account The address of user.
     * @return userLocksTotal The total number of locks of an account.
     * @return userRewardEligibleLocks The number of locks eligible for reward of an account.
     */
    function getTotalLocks(
        address account
    ) external view returns (uint userLocksTotal, uint userRewardEligibleLocks) {
        userLocksTotal = rewardEligibleLocks[account].length;
        userRewardEligibleLocks = accountToLockIds[account].length;
    }
}