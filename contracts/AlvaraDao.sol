// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/IERC20.sol";

contract AlvaraDao is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    IERC20 public ALVA;
    IERC20 public xALVA;

    mapping(address => uint256) public userLockPeriod;
    mapping(address => bool) public blackListAddress;

    uint256 public lockedPeriod;

    event Stake(address indexed staker, uint256 xALVAReceived);
    event Unstake(address indexed unstaker, uint256 alvaReceived);
    event BlackListUser(address _user, bool _status);
    event UpdateLockPeriod(uint lockedPeriod, uint _lockedPeriod);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _alva,
        address _xalva,
        uint256 _lockedPeriod
    ) public initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();

        require(_alva != address(0), "Invalid alva address");
        require(_xalva != address(0), "Invalid xALVA address");

        ALVA = IERC20(_alva);
        xALVA = IERC20(_xalva);
        lockedPeriod = _lockedPeriod;
    }

    // Enter the alvaDao. Pay some alvas. Earn some shares.
    function enter(uint256 _amount) public {
        require(blackListAddress[msg.sender] != true, "BlackListed User");
        uint256 totalAlva = ALVA.balanceOf(address(this));
        uint256 totalShares = xALVA.totalSupply();
        if (totalShares == 0 || totalAlva == 0) {
            xALVA.mint(_msgSender(), _amount);
            emit Stake(_msgSender(), _amount);
        } else {
            uint256 _userShare = (_amount * totalShares) / totalAlva;
            xALVA.mint(_msgSender(), _userShare);
            emit Stake(_msgSender(), _userShare);
        }
        userLockPeriod[msg.sender] = block.timestamp;
        ALVA.transferFrom(_msgSender(), address(this), _amount);
    }

    // Leave the alvaDao. Claim back your alvas.
    function leave(uint256 _share) public {
        require(blackListAddress[msg.sender] != true, "BlackListed User");
        require(
            block.timestamp >= (userLockPeriod[msg.sender] + lockedPeriod),
            "Can not unStake"
        );
        uint256 totalShares = xALVA.totalSupply();
        uint256 _userShare = (_share * ALVA.balanceOf(address(this))) /
            totalShares;
        xALVA.burnFrom(_msgSender(), _share);
        ALVA.transfer(_msgSender(), _userShare);

        emit Unstake(_msgSender(), _userShare);
    }

    /**
     * @dev Used only by admin or owner, used to blacklist any user in any emergency case
     *
     * @param _user address of blacklistef user
     * @param _status status of user
     */
    function blackListUser(address _user, bool _status) external onlyOwner {
        require(blackListAddress[_user] != _status, "Already in same status");
        blackListAddress[_user] = _status;

        emit BlackListUser(_user, _status);
    }

    // Update lock period
    function updateLockPeriod(uint256 _lockedPeriod) external onlyOwner {
        emit UpdateLockPeriod(lockedPeriod, _lockedPeriod);

        lockedPeriod = _lockedPeriod;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}
}
