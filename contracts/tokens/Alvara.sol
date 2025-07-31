// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";

import {WithSupervisedTransfers} from "../utils/WithSupervisedTransfers.sol";

contract Alvara is
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    WithSupervisedTransfers
{
    /**
     * @dev Whenever an action is performed that is restricted, this error will be shown
     */
    error ActionRestricted();
    
    /**
     * @dev Error displayed when address is already greylisted
     */
    error AddressAlreadyGreylisted();

    /**
     * @dev Error displayed when an address is not in grey list and function tries to remove it 
     */
    error AddressNotInGreyList();

    /**
     * @dev Define role for managing the grey list
     */
    bytes32 public constant GREYLIST_MANAGER_ROLE = keccak256("GREYLIST_MANAGER_ROLE");
    
    /**
     * @dev Mapping to keep track of greylisted wallet addresses
     */
    mapping(address => bool) private _greyList;

    /**
     * @dev Emitted when an address is added to the grey list.
     * @param account The address that has been greylisted.
     */
    event GreyListed(address indexed account);

    /**
     * @dev Emitted when an address is removed from the grey list.
     * @param account The address that has been removed from the grey list.
     */
    event RemovedFromGreyList(address indexed account);
    
    /**
     * @dev Constructor will disable initializers.
     */

    constructor() {
        _disableInitializers(); // Locks the implementation
    }

    /**
     * @dev Initializer
     */
    function initialize() public initializer {
        __ERC20_init("Alvara", "ALVA");
        __ERC20Burnable_init();
        __WithSupervisedTransfers_init();

        _mint(msg.sender, 200_000_000 * 10**decimals());
    }

    /**
     * @dev Adds a wallet address to the grey list. Can only be called by the GREYLIST_MANAGER_ROLE holder.
     * @param account The address to be added to the grey list.
     */
    function addToGreyList(address account) public onlyRole(GREYLIST_MANAGER_ROLE) {
        if (_greyList[account]) {
            revert AddressAlreadyGreylisted();
        }
        _greyList[account] = true;
        emit GreyListed(account);
    }

    /**
     * @dev Removes an address from the grey list. Can only be called by the GREYLIST_MANAGER_ROLE holder.
     * @param account The address to be removed from the grey list.
     */
    function removeFromGreyList(address account) public onlyRole(GREYLIST_MANAGER_ROLE) {
        if (!_greyList[account]) {
            revert AddressNotInGreyList(); // Revert if the address is not greylisted
        }
        _greyList[account] = false;
        emit RemovedFromGreyList(account);
    }

    /**
     * @dev Checks if an address is a part of grey list.
     * @param account The address to be checked.
     * @return true if the address is on the grey list, false otherwise.
     */
    function isGreyListed(address account) public view returns (bool){
        return _greyList[account]; 
    }

    /**
     * @dev Override _transfer to add a custom check for greylist
     */
    function _transfer(
        address from, 
        address to, 
        uint256 amount
        ) internal override {
            if (_greyList[from]) {
                revert ActionRestricted(); // Restrict Grey Listed address to perform transfer action
            }
            super._transfer(from, to, amount);
    }

    /**
     * @dev Public Transfer From method including supervised transfer control
    */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override supervisedTransferFrom(from, to) returns (bool) {
        return super.transferFrom(from, to, amount);
    }
}