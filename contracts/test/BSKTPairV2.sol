// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "../interfaces/IFactory.sol";
import "../interfaces/IBSKTPair.sol";

/// @title BSKTPairV2
/// @notice A contract for testing Beacon Proxy pattern
/// @dev In this contract some new states and methods are added to test the beacon proxy upgrade mechanism
contract BSKTPairV2 is ERC20Upgradeable, OwnableUpgradeable, IBSKTPair {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ===============================================
    // State Variables
    // ===============================================
    
    /// @notice Address of the factory contract
    /// @dev The factory contract is responsible for managing the liquidity pairs
    address public factory;

    /// @notice Timestamp of the last fee accrual
    /// @dev The lastAccruedAt variable stores the timestamp for occurrence of fee accrual
    uint256 public lastAccruedAt;
    
    /// @notice Boolean to track reentrancy
    /// @dev Prevents reentrancy by checking the state of operations in BSKT
    bool public reentrancyGuardEntered;
    
    /// @notice Array of token addresses in the basket
    /// @dev The tokens array stores the addresses of the tokens in the basket
    address[] private tokens;

    /// @notice Array of token reserves corresponding to the tokens array
    /// @dev The reserves array stores the reserve amounts of the tokens in the basket
    uint256[] private reserves;
    
    /// @notice Version of the contract implementation
    /// @dev Used to verify the upgrade was successful
    uint256 public constant VERSION = 2;
    
    /// @notice Last time the pair was rebalanced
    /// @dev New state variable added in v2 to track rebalancing
    uint256 public lastRebalanceTimestamp;
    
    /// @notice Fee tier for the pair
    /// @dev New state variable added in v2 for dynamic fee tiers
    uint256 public feeTier;
    
    /// @notice Historical price data storage
    /// @dev Stores historical price points for analytics
    mapping(uint256 => uint256) public historicalPrices;
    
    /// @notice Last price update timestamp
    /// @dev Tracks when the price was last updated
    uint256 public lastPriceUpdateTime;

    /// @notice Modifier to prevent reentrancy in read-only functions
    /// @dev Prevents reentrancy by checking the state of operations in BSKT
    modifier nonReentrantReadOnly() {
        if(reentrancyGuardEntered) revert ReentrantCall();
        _;
    }

    // ===============================================
    // Events
    // ===============================================

    /// @notice Emitted when the management fee is accrued
    /// @param owner Address of the BSKT contract
    /// @param months Number of months since last accrual
    /// @param supply Current supply of LP tokens
    /// @param amount Amount of LP tokens to be minted as fee
    /// @param newAccruedAt New timestamp for fee accrual
    event FeeAccruedV2(address indexed owner, uint256 months, uint256 supply, uint256 amount, uint256 newAccruedAt);

    /// @notice Emitted when the token list is updated
    /// @param _tokens New array of token addresses
    event TokensUpdatedV2(address[] _tokens);
    
    /// @notice Emitted when the fee tier is updated
    /// @param oldFeeTier Previous fee tier value
    /// @param newFeeTier New fee tier value
    event FeeTierUpdatedV2(uint256 oldFeeTier, uint256 newFeeTier);
    
    /// @notice Emitted when a price point is recorded
    /// @param timestamp Time when the price was recorded
    /// @param price The recorded price value
    event PriceRecordedV2(uint256 timestamp, uint256 price);
    
    /// @notice Emitted when the pair is rebalanced
    /// @param rebalancer Address that performed the rebalance
    /// @param timestamp Time of rebalance
    event PairRebalancedV2(address indexed rebalancer, uint256 timestamp);

    // ===============================================
    // Errors
    // ===============================================

    /// @notice Error thrown when an invalid token is provided
    /// @dev The InvalidToken error is thrown when a token address is invalid
    error InvalidToken();

    /// @notice Error thrown when there is insufficient liquidity for an operation
    /// @dev The InsufficientLiquidity error is thrown when there is not enough liquidity for an operation
    error InsufficientLiquidity();

    /// @notice Error thrown when an invalid recipient address is provided
    /// @dev The InvalidRecipient error is thrown when an address is zero
    error InvalidRecipient();

    /// @notice Error thrown when a parameter string is empty
    error EmptyStringParameter(string paramName);

    /// @notice Error thrown when a reentrancy attempt is detected
    /// @dev The ReentrancyError is thrown when a reentrancy attempt is detected
    error ReentrantCall();
    
    /// @notice Error thrown when an invalid fee tier is provided
    /// @dev The InvalidFeeTier error is thrown when a fee tier is out of allowed range
    error InvalidFeeTier(uint256 provided, uint256 maxAllowed);
    
    /// @notice Error thrown when price recording fails
    /// @dev The PriceRecordingFailed error is thrown when price recording fails
    error PriceRecordingFailed();
    
    /// @notice Error thrown when rebalance is attempted too soon
    /// @dev The RebalanceTooSoon error is thrown when rebalance cooldown hasn't passed
    error RebalanceTooSoon(uint256 lastRebalance, uint256 cooldownPeriod);

    // ===============================================
    // Initialization
    // ===============================================

    /// @notice Initializes the pair contract
    /// @dev Sets up the ERC20 token and initializes pair parameters
    /// @param _factoryAddress Factory contract address
    /// @param _name Name of the pair token
    /// @param _tokens Array of token addresses in the pair
    function initialize(
        address _factoryAddress,
        string memory _name,
        address[] calldata _tokens
    ) external initializer {
        if (_tokens.length == 0) revert InvalidToken();
        if (bytes(_name).length == 0) revert EmptyStringParameter("name");

        _name = string(abi.encodePacked(_name, "-LP"));

        __ERC20_init(_name, _name);
        __Ownable_init();

        tokens = _tokens;
        reserves = new uint256[]  (tokens.length);

        factory = _factoryAddress;
        lastAccruedAt = block.timestamp;
    }

    // ===============================================
    // External Functions
    // ===============================================

    /// @notice Transfer Tokens To Owner 
    /// @dev Transfers all tokens to the owner, typically called during basket rebalancing
    /// @dev This function is only callable by the owner
    function transferTokensToOwner() external onlyOwner {
        address ownerAddress = owner();
        uint256 tokensLength = tokens.length;
        for (uint256 i = 0; i < tokensLength; ) {
            address token = tokens[i]; 
            uint256 balance = reserves[i]; 

            if (balance > 0) {
                IERC20Upgradeable(token).safeTransfer(ownerAddress, balance); 
            }

            unchecked { ++i; }
        }
    }

    /// @notice Updates the token list
    /// @dev Replaces the current token list with a new one
    /// @param _tokens New array of token addresses
    /// @dev This function is only callable by the owner
    function updateTokens(address[] calldata _tokens) external onlyOwner {
        if (_tokens.length == 0) revert InvalidToken();

        tokens = _tokens;
        _updateRebalanceReserve();
        emit TokensUpdatedV2(_tokens);
    }

    /// @notice Mints liquidity tokens
    /// @dev Calculates the liquidity amount based on token balances and mints LP tokens
    /// @param _to Address to mint tokens to
    /// @return liquidity Amount of liquidity tokens minted
    /// @dev This function is only callable by the owner
    function mint(address _to, uint256[] calldata amounts)
        external
        onlyOwner
        returns (uint256 liquidity)
    {
        if (_to == address(0)) revert InvalidRecipient();

        IFactory factoryInstance = _factory();
        address wethAddress = factoryInstance.weth();

        distMgmtFee();
        uint256 tokensLength = tokens.length;
        uint256 totalETH;

        for (uint256 i = 0; i < tokensLength; ) {
            address token = tokens[i]; 
            address[] memory path = factoryInstance.getPath(token, wethAddress); 
            totalETH +=  1e18; //factoryInstance.getAmountsOut(amounts[i], path);

            unchecked { ++i; }
        }

        liquidity = totalSupply() == 0 ? 1000 ether : calculateShareLP(totalETH);
        _mint(_to, liquidity);

        for (uint256 i = 0; i < amounts.length; ) {
            reserves[i] += amounts[i];

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Burns liquidity tokens
    /// @dev Burns LP tokens and transfers the corresponding tokens to the recipient
    /// @param _to Address to transfer tokens to
    /// @return amounts Array of token amounts transferred
    /// @dev This function is only callable by the owner
    function burn(address _to)
        external
        onlyOwner
        returns (uint256[] memory amounts)
    {
        if (_to == address(0)) revert InvalidRecipient();

        distMgmtFee();
        uint256 _liquidity = balanceOf(address(this));
        if (_liquidity == 0) revert InsufficientLiquidity();

        amounts = calculateShareTokens(_liquidity);
        _burn(address(this), _liquidity);
        uint256 tokensLength = tokens.length; 
        for (uint256 i = 0; i < tokensLength; ) {
            uint256 amount = amounts[i];
            if (amount > 0){
                address token = tokens[i]; 
                IERC20Upgradeable(token).safeTransfer(_to, amount); 
            } 


            reserves[i] -= amount; 

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Sets or resets the reentrancy guard flag
    /// @param _state New state for the reentrancy guard flag for read-only functions
    /// @notice This function is only callable by the owner
    function setReentrancyGuardStatus(bool _state) external onlyOwner {
        reentrancyGuardEntered = _state;
    }

    // ===============================================
    // Public Functions
    // ===============================================

    /// @notice Distributes the management fee
    /// @dev Mints LP tokens for the BSKT manager and updates the accrual time. It can be called by internal functions, external cron jobs, or manually by any account.
    function distMgmtFee() public {
        (uint256 months, uint256 supply, uint256 feeAmount) = calFee();
        if(months == 0) return;

        // Mint fee Lp tokens for BSKT manager
        if (feeAmount > 0) _mint(owner(), feeAmount);

        // Update the accrual time
        lastAccruedAt += months * 30 days;

        emit FeeAccruedV2(owner(), months, supply, feeAmount, lastAccruedAt);
    }

    // ===============================================
    // Public View/Pure Functions
    // ===============================================

    
    /// @notice Calculates the share of LP tokens
    /// @dev Calculates the amount of LP tokens for a specific amount of ETH value
    /// @param _amountETH Amount of ETH to calculate share for
    /// @return amountLP Amount of LP tokens
    function calculateShareLP(uint256 _amountETH)
    public
    view
    nonReentrantReadOnly
    returns (uint256 amountLP)
    {
        uint256 reservedETH = _totalReservedETH();
        if (reservedETH == 0) return 1000 ether;
        amountLP = ((_amountETH * totalSupply()) / reservedETH);
    }
    
    /// @notice Calculates the share of ETH
    /// @dev Calculates the equivalent ETH value for a specific amount of LP tokens
    /// @param _amountLP Amount of LP tokens to calculate share for
    /// @return amountETH Amount of ETH
    function calculateShareETH(uint256 _amountLP)
    public
    view
    nonReentrantReadOnly
    returns (uint256 amountETH)
    {
        uint256 supply = totalSupply(); 
        if (supply == 0) return 0;
        
        IFactory factoryInstance = _factory();
        uint256 reservesLength = reserves.length;
        address wethAddress = factoryInstance.weth();
        
        for (uint256 i = 0; i < reservesLength; ) {
            address token = tokens[i]; 
            uint256 tokenBalance = reserves[i]; 
            if (tokenBalance > 0) {
                address[] memory path = factoryInstance.getPath(token, wethAddress); 
                uint256 share = (_amountLP * tokenBalance) / supply;
                amountETH += factoryInstance.getAmountsOut(share, path);
            }
            unchecked {
                ++i;
            }
        }
    }
    
    /// @notice Calculates the share of tokens
    /// @dev Calculates the token amounts that correspond to a specific amount of LP tokens
    /// @param _amountLP Amount of LP tokens to calculate share for
    /// @return amountTokens Array of token amounts corresponding to the LP tokens
    function calculateShareTokens(uint256 _amountLP)
    public
    view
    nonReentrantReadOnly
    returns (uint256[] memory amountTokens)
    {
        uint256 supply = totalSupply(); 
        amountTokens = new uint256[](tokens.length);
        if (supply == 0) return amountTokens;
        
        for (uint256 i = 0; i < reserves.length; ) {
            uint256 balance = reserves[i];
            amountTokens[i] = (_amountLP * balance) / supply;
            
            unchecked {
                ++i;
            }
        }
    }
    
    /// @notice Gets the token and user balances
    /// @dev Returns the token balances in the contract and the user's LP token balance
    /// @param _user Address to get user balance for
    /// @return _tokenBal Array of token balances in the contract
    /// @return _supply Total supply of LP tokens
    /// @return _userLP User's LP token balance
    function getTokenAndUserBal(address _user)
    public
    view
    nonReentrantReadOnly
    returns (
        uint256[] memory,
            uint256,
            uint256
        )
        {
            uint256 tokensLength = tokens.length;
            uint256[] memory _tokenBal = new uint256[](tokensLength);
            
            for (uint256 i = 0; i < tokensLength; ) {
                _tokenBal[i] = reserves[i];
                unchecked { 
                    ++i; 
                }
            }
            
            uint256 _supply = totalSupply();
            uint256 _userLP = balanceOf(_user);
            return (_tokenBal, _supply, _userLP);
    }
    
    /// @notice Calculates the management fee
    /// @dev Calculates the management fee based on the time elapsed since last accrual
    /// @return months Number of months since last accrual
    /// @return supply Current supply of LP tokens
    /// @return feeAmount Amount of LP tokens to be minted
    function calFee() public view returns (uint256 months, uint256 supply, uint256 feeAmount) {
        months = (block.timestamp - lastAccruedAt)/ 30 days;
        supply = totalSupply();
        if(months == 0 || supply == 0) return (months, supply, 0);
        feeAmount  = _factory().calMgmtFee(months, supply);
    }

    /// @notice Returns the token address in the basket
    /// @param _index Index of the token in the basket
    /// @return Token address
    function getTokenAddress(uint256 _index)
        external
        view
        nonReentrantReadOnly
        returns (address)
    {
        return tokens[_index];
    }

    /// @notice Returns the token reserve in the basket
    /// @param _index Index of the token in the basket
    /// @return Token reserve
    function getTokenReserve(uint256 _index)
        external
        view
        nonReentrantReadOnly
        returns (uint256)
    {
        return reserves[_index];
    }
    
    /// @notice Gets the token list
    /// @dev Returns the array of token addresses in the basket
    /// @return Array of token addresses
    function getTokenList() public view nonReentrantReadOnly
        returns (address[] memory) {
        return tokens;
    }

    /// @notice Gets the token reserves
    /// @dev Returns the array of token reserves in the basket
    /// @return Array of token reserves
    function getTokensReserve() public view nonReentrantReadOnly
        returns (uint256[] memory) {
        return reserves;
    }

    /// @notice Gets the total management fee
    /// @dev Returns the fee by calculating new fee and adding existing fee balance
    /// @return Total management fee
    function getTotalMgmtFee() external view returns (uint) { 
        (, , uint256 feeAmount) = calFee();
        return feeAmount + balanceOf(owner());
    }

    // ===============================================
    // Private Functions
    // ===============================================

    /// @notice Returns the factory instance casted to IFactory interface
    /// @dev Used to avoid repeated casting of the factory address in loops and functions
    /// @return factoryInstance The factory interface instance
    function _factory() private view returns (IFactory) {
        return IFactory(factory);
    }
    
    // ===============================================
    // New V2 Methods
    // ===============================================
    
    /// @notice Sets the fee tier for the pair
    /// @dev Only callable by the owner
    /// @param _feeTier New fee tier value (basis points)
    function setFeeTier(uint256 _feeTier) external onlyOwner {
        if (_feeTier > 1000) revert InvalidFeeTier(_feeTier, 1000); // Max 10%
        
        uint256 oldFeeTier = feeTier;
        feeTier = _feeTier;
        emit FeeTierUpdatedV2(oldFeeTier, _feeTier);
    }
    
    /// @notice Records a price point for historical tracking
    /// @dev Updates the historical price mapping with current price
    /// @return success Whether the price was successfully recorded
    function recordPrice() external returns (bool success) {
        uint256 currentPrice = _calculateCurrentPrice();
        if (currentPrice == 0) revert PriceRecordingFailed();
        
        uint256 timestamp = block.timestamp;
        historicalPrices[timestamp] = currentPrice;
        lastPriceUpdateTime = timestamp;
        
        emit PriceRecordedV2(timestamp, currentPrice);
        return true;
    }
    
    /// @notice Rebalances the pair with a cooldown period
    /// @dev Can only be called after cooldown period has passed
    /// @param cooldownPeriod Minimum time between rebalances
    function rebalanceV2(uint256 cooldownPeriod) external onlyOwner {
        if (block.timestamp < lastRebalanceTimestamp + cooldownPeriod) {
            revert RebalanceTooSoon(lastRebalanceTimestamp, cooldownPeriod);
        }
        
        // Implementation would go here - simplified for this example
        // This would typically involve adjusting token balances
        
        lastRebalanceTimestamp = block.timestamp;
        emit PairRebalancedV2(msg.sender, block.timestamp);
    }
    
    /// @notice Gets the version of the implementation
    /// @dev Used to verify the upgrade was successful
    /// @return The version number of this implementation
    function getVersion() external pure returns (uint256) {
        return VERSION;
    }
    
    /// @notice Gets historical price at a specific timestamp
    /// @dev Returns 0 if no price was recorded at that timestamp
    /// @param timestamp The timestamp to query
    /// @return price The recorded price at that timestamp
    function getPriceAtTimestamp(uint256 timestamp) external view returns (uint256 price) {
        return historicalPrices[timestamp];
    }
    
    /// @notice Gets the average price over a time period
    /// @dev Calculates average from available price points in the period
    /// @dev Parameters are commented out as implementation is simplified for testing
    /// @return avgPrice The average price over the period
    function getAveragePriceOverPeriod(uint256 /* startTime */, uint256 /* endTime */) 
        external 
        pure 
        returns (uint256 avgPrice) 
    {
        // Implementation would go here - simplified for this example
        // This would typically calculate an average from historical prices
        return 0;
    }
    
    /// @notice Calculates the current price of the pair
    /// @dev Internal helper function for price recording
    /// @return price The current price
    function _calculateCurrentPrice() internal view returns (uint256 price) {
        // Implementation would go here - simplified for this example
        // This would typically calculate the current price based on reserves
        return _totalReservedETH() > 0 ? _totalReservedETH() / totalSupply() : 0;
    }

    /// @notice Updates the rebalance reserves
    /// @dev Internal function to update reserve amounts based on current token balances
    function _updateRebalanceReserve() private {

        uint256 tokensLength = tokens.length;
        reserves = new uint256[](tokensLength);

        for (uint256 i = 0; i < tokensLength; ) {
            address token = tokens[i]; 
            reserves[i] = IERC20Upgradeable(token).balanceOf(address(this)); 
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Calculates the total reserved ETH
    /// @dev Calculates the sum of all reserve values in WETH equivalent
    /// @return totalReservedETH Total reserve value in WETH
    function _totalReservedETH() private view returns (uint256 totalReservedETH) {
        IFactory factoryInstance = _factory();
        address weth = factoryInstance.weth(); 
        uint256 length = reserves.length;

        for (uint256 i = 0; i < length; ) {
            uint256 reserve = reserves[i];
            if (reserve > 0) {
                address token = tokens[i]; 
                address[] memory path = factoryInstance.getPath(token, weth); 
                totalReservedETH += factoryInstance.getAmountsOut(reserve, path);
            }

            unchecked {
                ++i;
            }
        }
    }
}
