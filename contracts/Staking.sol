// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "./utils/Ownable.sol";
import "./utils/ReentrancyGuard.sol";
import "./libraries/TransferHelper.sol";

contract Staking is Ownable, ReentrancyGuard {
    uint256 public receiverFeePercentage;
    uint256 public lastUpdatedBalance;
    uint256 public totalUsers;
    uint32 public rewardInterval;

    address public receiverAddress;

    mapping(address => address) public parentAddress;
    mapping(address => bool) public isRegistered;
    mapping(address => uint256) public usersReferred;
    mapping(address => uint256) public userReferralBonus;
    mapping(address => uint256) public userLastClaimUserBonus;
    mapping(address => uint256) public userLastClaimBalanceBonus;

    /* =========== CONSTRUCTOR =========== */

    constructor() {
        receiverFeePercentage = 1200; // 12%
        rewardInterval = 1 minutes; // 1 days
    }

    /* =========== STRUCTS =========== */

    // Struct contains different Stake Plans
    struct StakePlan {
        uint256 minimumDeposit;
        uint256 minDailyROI;
        uint256 maxDailyROI;
        uint32 timePeriod;
    }
    mapping(uint256 => StakePlan) public stakePlanMapping;

    // Struct contains User stakes accordinf to stakePlan he invests in
    struct UserStake {
        uint256 stakeAmount;
        uint256 stakePlan;
        uint32 stakeTime;
        uint32 lastRewardClaim;
    }
    mapping(address => mapping(uint256 => UserStake)) public userStakeMapping;

    /* =========== SET PLAN FUNCTION =========== */

    // Sets new staking plan
    function setStakePlan(
        uint256 _stakeSerial,
        uint256 _minimumDeposit,
        uint256 _minDailyROI,
        uint256 _maxDailyROI,
        uint32 _timePeriod
    ) public onlyOwner {
        StakePlan memory newStake = StakePlan({
            minimumDeposit: _minimumDeposit,
            minDailyROI: _minDailyROI,
            maxDailyROI: _maxDailyROI,
            timePeriod: _timePeriod
        });
        stakePlanMapping[_stakeSerial] = newStake;
    }

    /* =========== STAKING SECTION =========== */

    // Function stakes TRON on the platform
    function stakeTron(uint256 _stakeSerial, address _referral)
        public
        payable
        nonReentrant
        returns (bool success)
    {
        // Referral address should be a registered user
        require(
            isRegistered[_referral],
            "Referral Address need to be a registered user"
        );

        // If referral address is not 0 address
        if (_referral != address(0)) {
            // User should not be registered before
            require(
                !isRegistered[msg.sender],
                "User is already a registered investor"
            );

            // Parent of the user should be a zero address
            require(
                parentAddress[msg.sender] == address(0),
                "Parent of user should not exist"
            );

            // Distribute referral rewards
            distributeToParents(_referral, msg.value);

            ++totalUsers;
        }

        // Internal function handles the staking process
        stakeTronInternal(_stakeSerial, msg.value);

        // Updation
        isRegistered[msg.sender] = true;
        parentAddress[msg.sender] = _referral;
        usersReferred[_referral]++;

        updateContractBalance();

        return true;
    }

    // Function lets users to reinvest their rewards without claiming
    function reinvestRewards(uint256 _stakeSerial)
        public
        returns (bool success)
    {
        uint256 _rewards = userReferralBonus[msg.sender];

        // Rewards should not be zero
        require(_rewards > 0, "No referral rewards available");

        // Internal function handles the staking process
        stakeTronInternal(_stakeSerial, _rewards);

        // Updation
        userReferralBonus[msg.sender] = 0;

        updateContractBalance();

        return true;
    }

    // Internal function creates staking instances
    function stakeTronInternal(uint256 _stakeSerial, uint256 _amount) internal {
        StakePlan memory stakeInfo = stakePlanMapping[_stakeSerial];

        // Amount should be equal or greater than the stake plan choosen
        require(
            _amount >= stakeInfo.minimumDeposit,
            "Value sent is lower than minumun value required"
        );

        // Receiverre (12%)
        uint256 _receiverShare = (_amount * receiverFeePercentage) / 10000;

        // Transfers the receiver's share
        TransferHelper.safeTransferETH(receiverAddress, _receiverShare);

        // Creates a new instance of struct
        UserStake memory newStake = UserStake({
            stakeAmount: _amount -
                _receiverShare +
                userStakeMapping[msg.sender][_stakeSerial].stakeAmount,
            stakePlan: _stakeSerial,
            stakeTime: uint32(block.timestamp),
            lastRewardClaim: uint32(block.timestamp)
        });
        userStakeMapping[msg.sender][_stakeSerial] = newStake;
    }

    // Function distributes tron to the parents in 4 levels. 15%, 4%, 1% and 1% in 4 levels
    function distributeToParents(address _parentAddress, uint256 _amount)
        internal
    {
        // If address is not zero address
        if (_parentAddress != address(0)) {
            userReferralBonus[_parentAddress] += (15 * _amount) / 100;

            _parentAddress = parentAddress[_parentAddress];

            // If address is not zero address
            if (_parentAddress != address(0)) {
                userReferralBonus[_parentAddress] += (4 * _amount) / 100;

                _parentAddress = parentAddress[_parentAddress];

                // If address is not zero address
                if (_parentAddress != address(0)) {
                    userReferralBonus[_parentAddress] += (_amount) / 100;

                    _parentAddress = parentAddress[_parentAddress];

                    // If address is not zero address
                    if (_parentAddress != address(0)) {
                        userReferralBonus[_parentAddress] += (_amount) / 100;
                    }
                }
            }
        }
    }

    /* =========== UNSTAKING =========== */

    // Function unStakes TRON from the platform
    function unstakeTron(uint256 _stakeSerial) external returns (bool success) {
        UserStake storage userInfo = userStakeMapping[msg.sender][_stakeSerial];
        StakePlan memory stakeInfo = stakePlanMapping[userInfo.stakePlan];

        require(
            block.timestamp > userInfo.stakeTime + stakeInfo.timePeriod,
            "Stake time is not yet over"
        );

        require(userInfo.stakeAmount > 0, "Already Unstaked");

        TransferHelper.safeTransferETH(msg.sender, userInfo.stakeAmount);

        // Rewards Claiming
        claimStakingRewards(_stakeSerial);
        claimuserReferralBonus();
        claimTotalBalanceReward(_stakeSerial);
        claimTotalUsersReward(_stakeSerial);

        delete stakeInfo;

        updateContractBalance();

        return true;
    }

    /* =========== REFERRAL REWARDS SECTION =========== */

    // Function lets user claim their referral bonuses
    function claimuserReferralBonus() public returns (bool success) {
        uint256 _rewards = userReferralBonus[msg.sender];

        // Rewards should not be 0
        require(_rewards > 0, "No referral rewards available");

        // User must have referred atleast 3 users
        require(
            usersReferred[msg.sender] >= 3,
            "User need to have atleast 3 referrals to claim referral rewards"
        );

        // Contract should have enough balance
        require(address(this).balance > _rewards, "Contract balance is low");

        TransferHelper.safeTransferETH(msg.sender, _rewards);
        userReferralBonus[msg.sender] = 0;

        updateContractBalance();

        return true;
    }

    /* =========== STAKING REWARDS SECTION =========== */

    // Function enables user to claim rewards
    function claimStakingRewards(uint256 _stakeSerial)
        public
        returns (bool success)
    {
        UserStake storage userInfo = userStakeMapping[msg.sender][_stakeSerial];

        // User should have stakeAmount
        require(userInfo.stakeAmount > 0, "User has no stake");

        (uint256 _rewards, ) = calculateStakingRewards(
            msg.sender,
            _stakeSerial
        );

        // If rewards are greater than 0, then transfer the rewards to the user
        if (_rewards > 0) {
            TransferHelper.safeTransferETH(msg.sender, _rewards);
            userInfo.lastRewardClaim = uint32(block.timestamp);
        }

        updateContractBalance();

        return true;
    }

    // Function returns rewards and current ROI user is getting
    function calculateStakingRewards(address _userAddress, uint256 _stakeSerial)
        public
        view
        returns (uint256, uint256)
    {
        UserStake memory userInfo = userStakeMapping[_userAddress][
            _stakeSerial
        ];
        StakePlan memory stakeInfo = stakePlanMapping[userInfo.stakePlan];

        return
            calculateStakingRewardsInternal(
                _userAddress,
                _stakeSerial,
                stakeInfo.minDailyROI,
                stakeInfo.maxDailyROI,
                1
            );
    }

    // Internal Function returns rewards and current ROI user is getting
    function calculateStakingRewardsInternal(
        address _userAddress,
        uint256 _stakeSerial,
        uint256 _minDailyROI,
        uint256 _maxDailyROI,
        uint256 _tempCount
    ) internal view returns (uint256, uint256) {
        UserStake memory userInfo = userStakeMapping[_userAddress][
            _stakeSerial
        ];
        StakePlan memory stakeInfo = stakePlanMapping[userInfo.stakePlan];

        // If maximum rewards are already given or timePeriod was 0 (1st case)
        if (
            (_tempCount * rewardInterval) > stakeInfo.timePeriod &&
            stakeInfo.timePeriod != 0
        ) {
            return (0, _minDailyROI);
        }
        // If current time is greater than rewardsInterval * tempCount
        else if (
            block.timestamp >
            userInfo.lastRewardClaim + (_tempCount * rewardInterval)
        ) {
            uint256 _reward = (userInfo.stakeAmount * _minDailyROI) / 10000;
            uint256 _addedRewards;
            uint256 _currentRoi = _minDailyROI;

            // If current time is greater than next interval
            if (
                block.timestamp >
                userInfo.lastRewardClaim + ((_tempCount + 1) * rewardInterval)
            ) {
                // If timePeriod is not 0 (Case 1)
                if (stakeInfo.timePeriod != 0) {
                    // If min and max ROIs match. No further increase
                    if (_minDailyROI == _maxDailyROI) {
                        (
                            _addedRewards,
                            _currentRoi
                        ) = calculateStakingRewardsInternal(
                            _userAddress,
                            _stakeSerial,
                            _minDailyROI,
                            _maxDailyROI,
                            _tempCount + 1
                        );
                    }
                    // Increase in min ROI
                    else {
                        (
                            _addedRewards,
                            _currentRoi
                        ) = calculateStakingRewardsInternal(
                            _userAddress,
                            _stakeSerial,
                            _minDailyROI + 10,
                            _maxDailyROI,
                            _tempCount + 1
                        );
                    }
                }
                // If timePeriod is 0. Infinite reward, but no increase in min ROI
                else {
                    (
                        _addedRewards,
                        _currentRoi
                    ) = calculateStakingRewardsInternal(
                        _userAddress,
                        _stakeSerial,
                        _minDailyROI,
                        _maxDailyROI,
                        _tempCount + 1
                    );
                }
            }

            return (_reward + _addedRewards, _currentRoi);
        }
        // If current time is lower than rewardsInterval * tempCount
        else {
            return (0, _minDailyROI);
        }
    }

    /* =========== TOTAL USERS BONUS SECTION =========== */

    //  Function claims rewards every time number of users in the contract exceeds by 1000
    function claimTotalUsersReward(uint256 _stakeSerial) public {
        UserStake memory userInfo = userStakeMapping[msg.sender][_stakeSerial];

        // User should have a stake in the contract
        require(userInfo.stakeAmount > 0, "User has no stake");

        (
            uint256 _rewards,
            uint256 _lastClaimAvalailable
        ) = calculateTotalUsersReward(msg.sender, _stakeSerial);

        // Claim only if rewards are more than 0
        if (_rewards > 0) {
            TransferHelper.safeTransferETH(msg.sender, _rewards);
            userLastClaimUserBonus[msg.sender] = _lastClaimAvalailable;
        }

        // Updates contract balance
        updateContractBalance();
    }

    // Function calculates user rewards every time total users exceeds by 1000
    function calculateTotalUsersReward(
        address _userAddress,
        uint256 _stakeSerial
    ) public view returns (uint256, uint256) {
        UserStake memory userInfo = userStakeMapping[_userAddress][
            _stakeSerial
        ];

        uint256 _rewards;
        uint256 _lastClaim;

        // If total users have increased by atleast 1000
        if (
            (totalUsers / 1000) > (userLastClaimUserBonus[_userAddress] / 1000)
        ) {
            _rewards =
                (((totalUsers / 1000) -
                    (userLastClaimUserBonus[_userAddress] / 1000)) *
                    userInfo.stakeAmount) /
                100;

            _lastClaim = (totalUsers / 1000) * 1000;
        }
        // If total users are still less than 1000 increase
        else {
            _rewards = 0;
            _lastClaim = userLastClaimUserBonus[_userAddress];
        }

        return (_rewards, _lastClaim);
    }

    /* =========== TOTAL USERS BONUS SECTION =========== */

    // Function claims rewards every time contract balance increases by 1 Million TRON
    function claimTotalBalanceReward(uint256 _stakeSerial)
        public
        returns (bool success)
    {
        UserStake memory userInfo = userStakeMapping[msg.sender][_stakeSerial];

        require(userInfo.stakeAmount > 0, "User doesn't have any stake");

        (
            uint256 _rewards,
            uint256 _lastUpdatedBalance
        ) = calculateTotalBalanceReward(msg.sender, _stakeSerial);

        // Claims only if rewards are more than 0
        if (_rewards > 0) {
            TransferHelper.safeTransferETH(msg.sender, _rewards);
            userLastClaimBalanceBonus[msg.sender] = _lastUpdatedBalance;
        }

        return true;
    }

    // Function calculates rewards every time contract balance increases by 1 Million TRON
    function calculateTotalBalanceReward(
        address _userAddress,
        uint256 _stakeSerial
    ) public view returns (uint256, uint256) {
        UserStake memory userInfo = userStakeMapping[_userAddress][
            _stakeSerial
        ];

        uint256 _rewards;
        uint256 _lasUpdatedBalance;

        // If last updated balance is greater than last balance user claimed
        if (lastUpdatedBalance > userLastClaimBalanceBonus[_userAddress]) {
            _rewards =
                (((lastUpdatedBalance -
                    userLastClaimBalanceBonus[_userAddress]) / 10**6) *
                    userInfo.stakeAmount) /
                100;
            _lasUpdatedBalance = lastUpdatedBalance;
        }
        // If the values are equal
        else {
            _rewards = 0;
            _lasUpdatedBalance = userLastClaimBalanceBonus[_userAddress];
        }

        return (_rewards, _lasUpdatedBalance);
    }

    // Functio updates contract balance in a factor of 1 Million
    function updateContractBalance() internal {
        uint256 _currentContractBalance = (address(this).balance /
            ((10**6) * (10**18))) * (10**6);

        // If contract's balance has increased by 1 Million TRX
        if (_currentContractBalance > lastUpdatedBalance) {
            lastUpdatedBalance = _currentContractBalance;
        }
    }

    /* =========== OTHER FUNCTIONS =========== */

    // Updates Admin fee percentage
    function updatereceiverFeePercentage(uint256 _newPercentage)
        external
        onlyOwner
    {
        receiverFeePercentage = _newPercentage;
    }

    // Updates Receiver Address
    function updateReceiverAddress(address _newAddress) external onlyOwner {
        receiverAddress = _newAddress;
    }

    // Updates Rewards Interval
    function updateRewardInterval(uint32 _rewardInterval) external onlyOwner {
        rewardInterval = _rewardInterval;
    }
}
