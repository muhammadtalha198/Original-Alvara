// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "../interfaces/IFactory.sol";
import "../interfaces/IBSKTPair.sol";

/// @title Basket Token Standard Pair
/// @notice A contract for managing liquidity pairs of basket tokens
/// @dev Implements ERC20 for liquidity tokens and acts as a liquidity pool for the specified tokens
contract BasketTokenStandardPair is ERC20Upgradeable, OwnableUpgradeable, IBSKTPair {
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
    event FeeAccrued(address indexed owner, uint256 months, uint256 supply, uint256 amount, uint256 newAccruedAt);

    /// @notice Emitted when the token list is updated
    /// @param _tokens New array of token addresses
    event TokensUpdated(address[] _tokens);

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
        emit TokensUpdated(_tokens);
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
            totalETH += factoryInstance.getAmountsOut(amounts[i], path);

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

        emit FeeAccrued(owner(), months, supply, feeAmount, lastAccruedAt);
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
