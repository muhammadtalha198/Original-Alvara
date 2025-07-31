// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IBSKTPair {
    function initialize(address factoryAddress, string memory name, address[] calldata tokens) external;

    function mint(address _to, uint256[] calldata amounts) external returns (uint256 liquidity);

    function burn(address _to) external returns (uint256[] memory amounts);

    function transferTokensToOwner() external;

    function updateTokens(address[] calldata _tokens) external;

    function setReentrancyGuardStatus(bool _state) external;

    function distMgmtFee() external;

    function getTokenAddress(uint256 _index) external view returns (address);

    function getTokenReserve(uint256 _index) external view returns (uint256);

    function getTokenList() external view returns (address[] memory);

    function getTokensReserve() external view returns (uint256[] memory);

    function getTotalMgmtFee() external view returns (uint);

    function calculateShareETH(uint256 _amountLP) external view returns (uint256 amountETH);

    function calculateShareTokens(uint256 _amountLP) external view returns (uint256[] memory amountTokens);

    function getTokenAndUserBal(address _user) external view returns (uint256[] memory, uint256, uint256);
}
