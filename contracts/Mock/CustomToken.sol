// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract CustomToken is ERC20Upgradeable, OwnableUpgradeable {
    function initialize(string memory name, string memory symbol)
        public
        initializer
    {
        __Ownable_init();
        __ERC20_init(name, symbol);
        _mint(msg.sender, 200_000_000 * 10**decimals());
    }

    function mint() public onlyOwner {
        super._mint(owner(), 200_000_000 * 10**decimals());
    }
}
