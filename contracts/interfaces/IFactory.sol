// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IFactory {
    // --- View Functions ---
    function alva() external view returns (address);
    function minPercentALVA() external view returns (uint16);
    function minLpWithdrawal() external view returns (uint256);
    function bsktImplementation() external view returns (address);
    function bsktPairImplementation() external view returns (address);
    function royaltyReceiver() external view returns (address);
    function royaltyPercentage() external view returns (uint256);
    function router() external view returns (address);
    function weth() external view returns (address);
    function minBSKTCreationAmount() external view returns (uint256);
    function monthlyFeeRate() external view returns (uint256);
    function collectionUri() external view returns (string memory);
    function totalBSKT() external view returns (uint);
    function getBSKTAtIndex(uint256 index) external view returns (address);
    function getPlatformFeeConfig() external view returns (uint16, uint16, uint16, address);
    function getContractURI() external view returns (string memory);
    function isWhitelistedContract(address contractAddr) external view returns (bool);
    function calMgmtFee(uint256 months, uint256 lpSupply) external view returns (uint256);
    function getAmountsOut(uint256 _amount, address[] memory _path) external view returns (uint);
    function getPath(address _tokenA, address _tokenB) external pure returns (address[] memory);

    // --- Mutative Functions ---
    function initialize(
        address _alva,
        uint16 _minPercentALVA,
        address _bsktImplementation,
        address _bsktPairImplementation,
        uint256 _monthlyFeeRate,
        address _royaltyReceiver,
        string calldata _collectionUri,
        address _feeCollector,
        address _defaultMarketplace,
        address _routerAddress,
        address _wethAddress,
        uint256 _minBSKTCreationAmount
    ) external;

    function setMinLpWithdrawal(uint256 newMin) external;
    function createBSKT(
        string calldata _name,
        string calldata _symbol,
        address[] calldata _tokens,
        uint256[] calldata _weights,
        string calldata _tokenURI,
        uint256 _buffer,
        string calldata _id,
        string calldata _description,
        uint256 _deadline
    ) external payable;
    function updateBSKTImplementation(address _bsktImplementation) external;
    function updateBSKTPairImplementation(address _bsktPairImplementation) external;
    function updateAlva(address _alva) external;
    function updateMinPercentALVA(uint16 _minPercentALVA) external;
    function updateCollectionURI(string calldata _collectionURI) external;
    function updateRoyaltyPercentage(uint256 _royaltyPercentage) external;
    function updateRoyaltyReceiver(address _royaltyReceiver) external;
    function updateMinBSKTCreationAmount(uint256 _minBSKTCreationAmount) external;
    function addWhitelistedContract(address contractAddr) external;
    function dewhitelistContract(address contractAddr) external;
    function setPlatformFeeConfig(uint16 _bsktCreationFee, uint16 _contributionFee, uint16 _withdrawalFee) external;
    function setFeeCollector(address _feeCollector) external;
}