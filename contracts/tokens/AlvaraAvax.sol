// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {WithSupervisedTransfersAvax} from "../utils/WithSupervisedTransfersAvax.sol";

contract AlvaraAvax is
    ERC20Upgradeable,
    OwnableUpgradeable,
    ERC20BurnableUpgradeable,
    WithSupervisedTransfersAvax
{
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURN_ROLE = keccak256("BURN_ROLE");

    function initialize() public initializer {
        __ERC20_init("Alvara", "ALVA");
        __ERC20Burnable_init();
        __WithSupervisedTransfers_init(MINTER_ROLE, BURN_ROLE);
        __Ownable_init();
    }

    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        super._mint(to, amount);
    }

    function burn(address from, uint256 amount) public onlyRole(BURN_ROLE) {
        super._burn(from, amount);
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override supervisedTransferFrom(from, to) returns (bool) {
        return super.transferFrom(from, to, amount);
    }
}
