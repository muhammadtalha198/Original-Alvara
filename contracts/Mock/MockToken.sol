// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("My Token", "MT") {
        _mint(msg.sender, 200_000_000 * 10**decimals());
    }
}
