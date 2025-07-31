// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

interface IWETH {
    // Events
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);
    
    // Functions
    function deposit() external payable;
    
    // No-argument withdraw function (withdraws all)
    function withdraw() external;
    
    // Withdraw with specific amount
    function withdraw(uint wad) external;
    
    function mint(address to, uint256 amount) external;
    
    function burn(address from, uint256 amount) external;
    
    function transfer(address to, uint256 amount) external returns (bool);
    
    function allowance(address owner, address spender)
        external
        view
        returns (uint256);
    
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
    
    // Additional ERC20 functions
    function balanceOf(address account) external view returns (uint256);
    
    function approve(address spender, uint256 amount) external returns (bool);
}
