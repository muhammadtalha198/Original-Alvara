// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;
/**
  This is custom WETH token smart-contract, to solve the faucet issue. 
  Now all Testnet Eth will be sent to this smart-contract and we have a 
  custom method to extract back the tokens to our admin address and re-use 
  the tokens
 */

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract WETH is ERC20Upgradeable, OwnableUpgradeable {
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    function initialize() public initializer {
        __ERC20_init("Wrapped Ether", "WETH");
        __Ownable_init();
    }

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        super._mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw() public onlyOwner {
        uint256 amount = address(this).balance;
        require(amount > 0, "Not enough balance to withdraw");
        payable(msg.sender).transfer(amount);
        emit Withdrawal(msg.sender, amount);
    }

    function mint(address to, uint256 amount) public onlyOwner {
        super._mint(to, amount);
    }

    function burn(address from, uint256 amount) public onlyOwner {
        super._burn(from, amount);
    }

    function withdraw(uint256 wad) public {
        require(balanceOf(msg.sender) >= wad);
        super._burn(msg.sender,wad);
        payable(msg.sender).transfer(wad);
        emit Withdrawal(msg.sender, wad);
    }
}
