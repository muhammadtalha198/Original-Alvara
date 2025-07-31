// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract veALVA is Initializable, ERC20Upgradeable, AccessControlUpgradeable {

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    constructor() {
        _disableInitializers(); // Locks the implementation
    }
    
    function initialize()
        external
        initializer
    {
        __ERC20_init("vote-escrowed ALVA", "veALVA");
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function mint(address to, uint256 amount) public onlyRole(ADMIN_ROLE)
    {
        _mint(to, amount);
    }

    function burnTokens(address account, uint256 amount) public onlyRole(ADMIN_ROLE)
    {
        _burn(account, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        require(from == address(0) || to == address(0), "Tokens cannot be transferred");
        super._beforeTokenTransfer(from, to, amount);
    }
}
