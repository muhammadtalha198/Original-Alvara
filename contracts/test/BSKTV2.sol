// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/interfaces/IERC2981Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "../interfaces/IBSKTPair.sol";
import "../interfaces/IFactory.sol";
import "../interfaces/IUniswap.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/IBSKT.sol";

/// @title BSKTV2
/// @notice A contract for testing Beacon Proxy pattern
/// @dev In this contract some new states and methods are added to test the beacon proxy upgrade mechanism

contract BSKTV2 is
    ERC721URIStorageUpgradeable,
    IERC2981Upgradeable,
    ReentrancyGuardUpgradeable,
    IBSKT
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ===============================================
    // Type Declarations
    // ===============================================

    /// @notice Structure containing token addresses and their weights
    /// @dev Core data structure for the basket's composition
    struct TokenDetails {
        address[] tokens;
        uint256[] weights;
    }

    // ===============================================
    // Constants
    // ===============================================

    /// @notice ERC2981 interface identifier for royalty information
    /// @dev Used for ERC165 interface detection
    bytes4 private constant INTERFACE_ID_ERC2981 = 0x2a55205a;

    /// @notice Precision value for percentage calculations (100% = 10000)
    /// @dev Used to represent token weights and buffer with high precision
    uint256 public constant PERCENT_PRECISION = 10000;

    // ===============================================
    // State Variables
    // ===============================================

    /// @notice Address of the BSKT pair contract
    /// @dev The pair contract holds the actual token reserves and manages liquidity
    address public bsktPair;

    /// @notice Address of the factory contract
    /// @dev Factory provides utility functions and manages whitelisted contracts
    address public factory;
    
    /// @notice Version of the contract implementation
    /// @dev Used to verify the upgrade was successful
    uint256 public constant VERSION = 2;
    
    /// @notice Last time the basket was rebalanced
    /// @dev New state variable added in v2 to track rebalancing
    uint256 public lastRebalanceTimestamp;
    
    /// @notice Performance fee percentage
    /// @dev New state variable added in v2 for performance-based fees
    uint256 public performanceFeePercent;

    /// @notice Unique identifier for the basket
    /// @dev Used for external identification of the basket
    string public id;

    /// @notice Description of the basket
    /// @dev Human-readable description of the basket's purpose or contents
    string public description;

    /// @notice Mapping for supported interfaces (ERC165)
    /// @dev Tracks which interfaces the contract implements
    mapping(bytes4 => bool) private _supportedInterfaces;

    /// @notice Storage for token details
    /// @dev Contains the current set of tokens and their weights in the basket
    TokenDetails private _tokenDetails;

    // ===============================================
    // Modifiers
    // ===============================================

    /// @notice Ensures LP withdrawal meets the minimum required by the factory
    /// @param amount The LP amount being withdrawn
    modifier validateMinLpWithdrawal(uint256 amount) {
        uint256 min = _factory().minLpWithdrawal();
        if (amount < min) revert InvalidWithdrawalAmount();
        _;
    }

    /// @notice Validates that two arrays have the same length
    /// @param lengthOne Length of the first array
    /// @param lengthTwo Length of the second array
    /// @dev Used to ensure tokens and weights arrays match in length
    modifier checkLength(uint256 lengthOne, uint256 lengthTwo) {
        if (lengthOne != lengthTwo || lengthOne == 0 || lengthTwo == 0)
            revert InvalidLength();
        _;
    }

    /// @notice Restricts access to the token owner only
    /// @dev Uses getOwner() which returns the owner of NFT with ID 0
    modifier onlyOwner() {
        if (getOwner() != msg.sender) revert InvalidOwner();
        _;
    }

    /// @notice Modifier to restrict transfers through non-whitelisted contracts
    /// @param target The target address to check for whitelisting
    /// @dev Allows transfers to EOAs but restricts contracts to whitelisted ones
    modifier onlyWhitelistedContract(address target) {
        if (isContractAddress(target)) {
            if (!_factory().isWhitelistedContract(target))
                revert ContractNotWhitelisted();
        }
        _;
    }

    // ===============================================
    // Events
    // ===============================================

    /// @notice Emitted when ETH is contributed to the basket
    /// @param bskt Address of the basket contract
    /// @param sender Address of the contributor
    /// @param amount Amount of ETH contributed
    event ContributedToBSKTV2(address indexed bskt, address indexed sender, uint256 amount);

    /// @notice Emitted when tokens are withdrawn from the basket
    /// @param bskt Address of the basket contract
    /// @param sender Address of the user withdrawing
    /// @param tokens Array of token addresses withdrawn
    event WithdrawnFromBSKTV2(
        address bskt,
        address indexed sender,
        address[] tokens
    );

    /// @notice Emitted when ETH is withdrawn from the basket
    /// @param bskt Address of the basket contract
    /// @param sender Address of the user withdrawing
    /// @param amount Amount of ETH withdrawn
    event WithdrawnETHFromBSKTV2(
        address bskt,
        address indexed sender,
        uint256 amount
    );

    /// @notice Emitted when the basket is rebalanced
    /// @param bskt Address of the basket contract
    /// @param oldtokens Array of token addresses
    /// @param oldWeights Previous weights of tokens
    /// @param newWeights New weights of tokens after rebalancing
    event BSKTRebalancedV2(
        address indexed bskt,
        address[] oldtokens,
        uint256[] oldWeights,
        address[] newTokens,
        uint256[] newWeights
    );

    /// @notice Emitted when the platform fee is deducted during a user action (e.g., contribute, withdrawETH, withdrawTokens)
    /// @param feeAmount The deducted fee amount in wei
    /// @param feePercent The applied fee percentage
    /// @param feeCollector The address that received the deducted fee
    /// @param action The type of action triggering the fee (e.g., "contribute", "withdrawTokens", "withdrawETH")
    event PlatformFeeDeductedV2(
        uint256 feeAmount,
        uint256 feePercent,
        address indexed feeCollector,
        string action
    );

    /// @notice Emitted when management fee is claimed
    /// @param bskt Address of the basket contract
    /// @param lpAmount Amount of LP tokens
    /// @param ethAmount Amount of ETH
    event FeeClaimedV2(
        address indexed bskt,
        address indexed manager,
        uint256 lpAmount,
        uint256 ethAmount
    );



    /// @notice Emitted when performance fee is set
    /// @param bskt Address of the basket contract
    /// @param feePercent The new performance fee percentage
    event PerformanceFeeSetV2(address indexed bskt, uint256 feePercent);
    
    /// @notice Emitted when basket is rebalanced using V2 functionality
    /// @param bskt Address of the basket contract
    /// @param owner Address of the basket owner
    /// @param tokens Array of token addresses in the basket
    /// @param targetWeights Array of target weights for the tokens
    event BasketRebalancedV2(address indexed bskt, address indexed owner, address[] tokens, uint256[] targetWeights);
    
    /// @notice Emitted when performance fee is collected
    /// @param bskt Address of the basket contract
    /// @param owner Address of the basket owner
    /// @param feeAmount Amount of fee collected
    event PerformanceFeeCollectedV2(address indexed bskt, address indexed owner, uint256 feeAmount);
    // ===============================================
    // Errors
    // ===============================================

    /// @notice Error thrown when array lengths do not match
    error InvalidLength();

    /// @notice Error thrown when an invalid token is provided
    error InvalidToken();

    /// @notice Error thrown when token weights are invalid
    error InvalidWeight();

    /// @notice Error thrown when a non-owner tries to perform an owner-only action
    error InvalidOwner();

    /// @notice Error thrown when buffer value is invalid
    /// @param provided The provided buffer value
    /// @param minRequired The minimum required buffer
    /// @param maxAllowed The maximum allowed buffer
    error InvalidBuffer(
        uint256 provided,
        uint256 minRequired,
        uint256 maxAllowed
    );

    /// @notice Error thrown when a contract is not whitelisted
    error ContractNotWhitelisted();

    /// @notice Error thrown when a zero value is sent for a contribution
    error ZeroContributionAmount();

    /// @notice Error thrown when an emergency operation has invalid parameters
    error InvalidEmergencyParams();

    /// @notice Error thrown when no ALVA token is included in the basket
    error NoAlvaTokenIncluded();

    /// @notice Error thrown when ALVA token percentage is too low
    /// @param provided The provided ALVA percentage
    /// @param required The minimum required percentage
    error InsufficientAlvaPercentage(uint256 provided, uint256 required);

    /// @notice Error thrown when a duplicate token is detected
    error DuplicateToken();

    /// @notice Error thrown when a token weight is zero
    error ZeroTokenWeight();

    /// @notice Error thrown when an interface ID is invalid
    error InvalidInterfaceId();

    /// @notice Error thrown when a withdrawal amount is zero or invalid
    error InvalidWithdrawalAmount();

    /// @notice Thrown when the dealine is in past and invalid to be used for the execution
    /// @param deadline The invalid deadline value that caused the error
    error DeadlineInPast(uint256 deadline);

    /// @notice Thrown when the targeted address is not a valid contract address
    /// @param target The address that caused the error
    error InvalidContractAddress(address target);

    /// @notice Reverts if _index is out of bounds
    /// @param index The index that caused the error
    /// @param length Length of the tokens array
    error TokenIndexOutOfBounds(uint256 index, uint256 length);

    /// @notice Reverts if an unauthorized user tries to send tokens to the contract
    /// @param sender The sender address that cased the error
    error UnauthorizedSender(address sender);

    // ===============================================
    // Initialization
    // ===============================================

    /// @notice Initializes a new Basket Token
    /// @dev Sets up the ERC721 token and initializes basket parameters
    /// @param _name Name of the basket token
    /// @param _symbol Symbol of the basket token
    /// @param _owner Owner of the basket token
    /// @param _factoryAddress Factory contract address
    /// @param _tokens Array of token addresses in the basket
    /// @param _weights Array of weights for each token
    /// @param _bsktPair BSKT pair contract address
    /// @param _tokenURI URI of the basket token
    /// @param _id ID of the basket token
    /// @param _description Description of the basket
    function initialize(
        string calldata _name,
        string calldata _symbol,
        address _owner,
        address _factoryAddress,
        address[] calldata _tokens,
        uint256[] calldata _weights,
        address _bsktPair,
        string calldata _tokenURI,
        string calldata _id,
        string calldata _description
    ) external checkLength(_tokens.length, _weights.length) initializer {
        __ERC721_init(_name, _symbol);
        _registerInterface(INTERFACE_ID_ERC2981);
        __ReentrancyGuard_init();

        factory = _factoryAddress;
        id = _id;
        _checkValidTokensAndWeights(_tokens, _weights);

        bsktPair = _bsktPair;

        _tokenDetails.tokens = _tokens;
        _tokenDetails.weights = _weights;

        description = _description;

        _safeMint(_owner, 0);
        _setTokenURI(0, _tokenURI);
    }

    // ===============================================
    // External Functions
    // ===============================================

    /// @notice Allows the contract to receive ETH
    /// @dev Required for WETH.withdraw() to work properly
    receive() external payable {
        if (!isContractAddress(msg.sender))
            revert UnauthorizedSender(msg.sender);
    }

    /// @notice Allows users to contribute ETH to the basket
    /// @dev Swaps ETH for tokens according to their weights and mints LP tokens
    /// @dev The ETH is split proportionally according to token weights and swapped
    /// @param _buffer Maximum allowed buffer percentage (0-5000)
    function contribute(uint256 _buffer, uint256 _deadline)
        external
        payable
        nonReentrant
    {
        if (_buffer == 0 || _buffer >= 5000) {
            revert InvalidBuffer(_buffer, 1, 4999);
        }
        if (msg.value == 0) revert ZeroContributionAmount();

        if (_deadline <= block.timestamp) revert DeadlineInPast(_deadline);
        IFactory factoryInstance = _factory();
        // Get contribution fee from the Factory contract
        (, uint256 contributionFee, , address feeCollector) = factoryInstance
            .getPlatformFeeConfig();

        uint256 feeAmount = 0;
        // Deduct the contribution fee
        if (contributionFee > 0) {
            feeAmount = (msg.value * contributionFee) / PERCENT_PRECISION; // Calculate the contribution fee
            (bool success, ) = payable(feeCollector).call{value: feeAmount}(""); // Transfer fee to feeCollector
            require(success, "Failed to deduct Contribution Fee");
            emit PlatformFeeDeductedV2(
                feeAmount,
                contributionFee,
                feeCollector,
                "contribute"
            ); // Emit fee event for contribution
        }

        uint256 amountAfterFee = msg.value - feeAmount;
        address wethAddress = factoryInstance.weth();
        address routerAddress = factoryInstance.router();

        uint256 totalAllocated;
        uint256 tokensLength = _tokenDetails.tokens.length;
        uint256[] memory amounts = new uint256[](tokensLength);
        
        for(uint256 i = 0; i < tokensLength; ) {
            address token = _tokenDetails.tokens[i];
            uint256 weight = _tokenDetails.weights[i];

            uint256 _amountInMin;
            // For the last token, use remaining amount to avoid dust
            if (i == tokensLength - 1) {
                _amountInMin = amountAfterFee - totalAllocated;
            } else {
                _amountInMin = (amountAfterFee * weight) / PERCENT_PRECISION;
                totalAllocated += _amountInMin;
            }

            address[] memory path = factoryInstance.getPath(wethAddress, token);

            uint256 _amountOutMin = (factoryInstance.getAmountsOut(_amountInMin, path) * 
                (PERCENT_PRECISION - _buffer)) / PERCENT_PRECISION;

            uint256 balance = IERC20Upgradeable(token).balanceOf(bsktPair);
            
            IUniswapV2Router(routerAddress)
                .swapExactETHForTokensSupportingFeeOnTransferTokens{ value: _amountInMin }(
                    _amountOutMin,
                    path,
                    bsktPair,
                    _deadline
                );
    
            amounts[i] = IERC20Upgradeable(token).balanceOf(bsktPair) - balance;

            unchecked {
                ++i;
            }
        }

        IBSKTPair(bsktPair).mint(msg.sender, amounts);

        emit ContributedToBSKTV2(address(this), msg.sender, msg.value);
    }

    /// @notice Allows users to withdraw their tokens from the basket
    /// @dev Burns LP tokens and sends the underlying tokens to the user after deducting fees
    /// @dev The ETH is split proportionally according to token weights and swapped
    /// @param _liquidity Amount of liquidity tokens to burn
    /// @param _buffer Buffer tolerance to be used during swaps
    /// @param _deadline the deadline being used for the swapping
    function withdraw(
        uint256 _liquidity,
        uint256 _buffer,
        uint256 _deadline
    ) external nonReentrant validateMinLpWithdrawal(_liquidity) {
        if (_buffer == 0 || _buffer >= 5000) {
            revert InvalidBuffer(_buffer, 1, 4999);
        }

        // Get fee configuration from Factory
        IFactory factoryInstance = _factory(); 
        (, , uint256 withdrawalFee, address feeCollector) = factoryInstance
            .getPlatformFeeConfig();

        uint256 feeLiquidity = 0;


        // Process user's portion
        uint256 userLiquidity = _liquidity - feeLiquidity;

        // Withdraw Tokens
        //uint256[] memory userAmounts = _withdraw(userLiquidity, msg.sender);

        // Emit Withdrawal Event
        emit WithdrawnFromBSKTV2(
            address(this),
            msg.sender,
            _tokenDetails.tokens
        );
    }

    /// @notice Internal function to convert tokens to ETH and send to a receiver
    /// @dev Swaps tokens to ETH and sends to the specified receiver
    /// @param _amounts Array of token amounts to convert
    /// @param _receiver Address to receive the ETH
    /// @param _buffer Maximum allowed buffer percentage
    /// @return totalETH Total amount of ETH sent to receiver
    function _tokensToEth(
        IFactory factoryInstance,
        uint256[] memory _amounts,
        address payable _receiver,
        uint256 _buffer,
        uint256 _deadline
    ) private returns (uint256 totalETH) {
        if (_deadline <= block.timestamp) revert DeadlineInPast(_deadline);

        address wethAddress = factoryInstance.weth(); 
        address routerAddress = factoryInstance.router(); 
        uint256 totalWETH = 0;

        // Step 1: Convert all tokens to WETH (collected in this contract)
        for (uint256 i = 0; i < _amounts.length; ) {
            if (_amounts[i] > 0) {
                if (_tokenDetails.tokens[i] == wethAddress) {
                    totalWETH += _amounts[i];
                } else {
                    uint256 wethAmount = _swapTokensForTokens(
                        _tokenDetails.tokens[i],
                        wethAddress,
                        routerAddress,
                        _amounts[i],
                        address(this), // Send to this contract instead of receiver
                        _buffer,
                        _deadline
                    );
                    totalWETH += wethAmount;
                }
            }
            unchecked {
                ++i;
            }
        }

        // Step 2: Convert WETH to ETH and send to receiver
        if (totalWETH > 0) {
            IWETH(wethAddress).withdraw(totalWETH);
            (bool success, ) = _receiver.call{value: totalWETH}("");
            require(
                success,
                "Failed to unwrap and transfer WETH to the receiver"
            );
            totalETH = totalWETH;
        }

        return totalETH;
    }

    /// @notice Allows users to withdraw and convert to WETH
    /// @dev Burns LP tokens, receives the underlying tokens, and swaps them to WETH
    /// @param _liquidity Amount of liquidity tokens to burn
    /// @param _buffer Maximum allowed buffer percentage
    function withdrawETH(
        uint256 _liquidity,
        uint256 _buffer,
        uint256 _deadline
    ) external nonReentrant validateMinLpWithdrawal(_liquidity) {
        if (_buffer == 0 || _buffer >= 5000) {
            revert InvalidBuffer(_buffer, 1, 4999);
        }

        // Get fee configuration from Factory
        IFactory factoryInstance = _factory(); 
        (, , uint256 withdrawalFee, address feeCollector) = factoryInstance
            .getPlatformFeeConfig();

        uint256 feeLiquidity = 0;
        uint256 userLiquidity = _liquidity;
        uint256 feeWethAmount = 0;

        // // Process user's portion
        // uint256[] memory userAmounts = _withdraw(userLiquidity, address(this));


        emit WithdrawnETHFromBSKTV2(address(this), msg.sender, 0);
    }

    /// @notice Allows the owner to rebalance the basket with new tokens and weights
    /// @dev Changes the basket composition by selling current tokens and buying new ones
    /// @param _newTokens Array of new token addresses
    /// @param _newWeights Array of new token weights
    /// @param _buffer Maximum allowed buffer percentage
    /// @param _deadline Deadline for the transaction
    function rebalance(
        address[] calldata _newTokens,
        uint256[] calldata _newWeights,
        uint256 _buffer,
        uint256 _deadline
    ) external onlyOwner {
        if (_buffer == 0 || _buffer >= 5000) {
            revert InvalidBuffer(_buffer, 1, 4999);
        }
        _rebalance(_newTokens, _newWeights, _buffer, false, _deadline);
    }

    /// @notice Emergency function to rebalance the basket to a stable configuration
    /// @dev Allows rebalancing to exactly 2 tokens in emergency situations
    /// @param _newTokens Array containing exactly 2 token addresses
    /// @param _newWeights Array containing the weights for the 2 tokens, must sum to 100%
    /// @param _buffer Maximum allowed buffer percentage
    function emergencyStable(
        address[] calldata _newTokens,
        uint256[] calldata _newWeights,
        uint256 _buffer,
        uint256 _deadline
    ) external onlyOwner {
        if (_buffer == 0 || _buffer >= 5000) {
            revert InvalidBuffer(_buffer, 1, 4999);
        }
        _rebalance(_newTokens, _newWeights, _buffer, true, _deadline);
    }

    /// @notice Function to claim management fee for this BSKT
    /// @dev Converts claimed LP tokens to WETH and sends to the basket owner
    /// @param amount Amount of LP tokens to claim as management fee
    /// @param _buffer Maximum allowed buffer percentage for token swaps (1-4999)
    function claimFee(
        uint256 amount,
        uint256 _buffer,
        uint256 _deadline
    ) external onlyOwner {
        if (_buffer == 0 || _buffer >= 5000) {
            revert InvalidBuffer(_buffer, 1, 4999);
        }

        IFactory factoryInstance = _factory();

        IBSKTPair(bsktPair).distMgmtFee();
        IERC20Upgradeable(bsktPair).transfer(bsktPair, amount);
        uint256[] memory _amounts = IBSKTPair(bsktPair).burn(address(this));

        uint256 ethBought = _tokensToEth(
            factoryInstance,
            _amounts,
            payable(getOwner()),
            _buffer,
            _deadline
        );

        emit FeeClaimedV2(address(this), getOwner(), amount, ethBought);
    }

    /// @notice Override transfer functions to enforce whitelist
    /// @dev Only allows transfers to whitelisted contracts
    /// @param from Current owner address
    /// @param to New owner address
    /// @param tokenId ID of the token being transferred (always 0 for this contract)
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    )
        public
        override(ERC721Upgradeable, IERC721Upgradeable)
        onlyWhitelistedContract(to)
    {
        super.transferFrom(from, to, tokenId);
    }

    /// @notice Safe version of transferFrom with additional checks
    /// @dev Only allows transfers to whitelisted contracts
    /// @param from Current owner address
    /// @param to New owner address
    /// @param tokenId ID of the token being transferred (always 0 for this contract)
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    )
        public
        override(ERC721Upgradeable, IERC721Upgradeable)
        onlyWhitelistedContract(to)
    {
        super.safeTransferFrom(from, to, tokenId);
    }

    /// @notice Safe version of transferFrom with data parameter
    /// @dev Only allows transfers to whitelisted contracts
    /// @param from Current owner address
    /// @param to New owner address
    /// @param tokenId ID of the token being transferred (always 0 for this contract)
    /// @param data Additional data with no specified format
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    )
        public
        override(ERC721Upgradeable, IERC721Upgradeable)
        onlyWhitelistedContract(to)
    {
        super.safeTransferFrom(from, to, tokenId, data);
    }

    /// @notice Override approve function to enforce whitelist
    /// @dev Only allows approvals to whitelisted contracts
    /// @param to Address to approve
    /// @param tokenId ID of the token to approve (always 0 for this contract)
    function approve(address to, uint256 tokenId)
        public
        override(ERC721Upgradeable, IERC721Upgradeable)
        onlyWhitelistedContract(to)
    {
        super.approve(to, tokenId);
    }

    /// @notice Override setApprovalForAll function to enforce whitelist
    /// @dev Only allows approvals to whitelisted contracts
    /// @param operator Address to approve as operator
    /// @param approved Approval status to set
    function setApprovalForAll(address operator, bool approved)
        public
        override(ERC721Upgradeable, IERC721Upgradeable)        
    {
        if(approved) {
            if (isContractAddress(operator) && !_factory().isWhitelistedContract(operator)) {
                revert ContractNotWhitelisted();
            }
        }
        
        super.setApprovalForAll(operator, approved);
    }

    // ===============================================
    // Internal/Private Functions
    // ===============================================

    /// @notice Validates that tokens and weights are correctly configured
    /// @dev Checks that each token is unique, weights are valid, and ALVA is included
    /// @dev Weights must sum to PERCENT_PRECISION (10000) and ALVA must meet minimum percentage
    /// @param _tokens Array of token addresses
    /// @param _weights Array of token weights
    function _checkValidTokensAndWeights(
        address[] memory _tokens,
        uint256[] memory _weights
    ) private view {
        uint256 _totalWeight;
        bool isAlvaPresent = false;
        address alvaAddress = _factory().alva();

        for (uint256 i = 0; i < _tokens.length; ) {
            if (!isContractAddress(_tokens[i]))
                revert InvalidContractAddress(_tokens[i]);

            if (
                !_checkForDuplicateAddress(_tokens, _tokens[i], i + 1) &&
                _weights[i] != 0
            ) {
                if (_tokens[i] == alvaAddress) {
                    isAlvaPresent = true;
                    uint256 minPercentALVA = _factory().minPercentALVA();
                    if (_weights[i] < minPercentALVA) {
                        revert InsufficientAlvaPercentage(
                            _weights[i],
                            minPercentALVA
                        );
                    }
                }

                _totalWeight += _weights[i];
            } else {
                if (_weights[i] == 0) {
                    revert ZeroTokenWeight();
                } else {
                    revert InvalidToken();
                }
            }

            unchecked {
                ++i;
            }
        }

        if (!isAlvaPresent) revert NoAlvaTokenIncluded();
        if (_totalWeight != PERCENT_PRECISION) revert InvalidWeight();
    }

    /// @notice Internal function to withdraw liquidity
    /// @dev Transfers LP tokens from the user to the pair contract and burns them
    /// @param _liquidity Amount of liquidity tokens to burn
    /// @param _to Address to receive the tokens
    /// @return amounts Array of token amounts withdrawn
    function _withdraw(uint256 _liquidity, address _to)
        private
        returns (uint256[] memory amounts)
    {
        if (_liquidity == 0) revert InvalidWithdrawalAmount();

        IERC20Upgradeable(bsktPair).transferFrom(
            msg.sender,
            bsktPair,
            _liquidity
        );
        amounts = IBSKTPair(bsktPair).burn(_to);
    }

    /// @notice Internal function to perform basket rebalancing
    /// @dev Converts all tokens to WETH, then distributes WETH to buy new tokens
    /// @param _newTokens Array of new token addresses
    /// @param _newWeights Array of new token weights
    /// @param _buffer Maximum allowed buffer percentage
    /// @param _isEmergencyStable Flag for emergency stable conversion which requires exactly 2 tokens
    /// @param _deadline Deadline for the transaction
    function _rebalance(
        address[] memory _newTokens,
        uint256[] memory _newWeights,
        uint256 _buffer,
        bool _isEmergencyStable,
        uint256 _deadline
    ) private checkLength(_newTokens.length, _newWeights.length) {
        if (_isEmergencyStable && _newTokens.length != 2) {
            revert InvalidEmergencyParams();
        }
        if (_deadline <= block.timestamp) revert DeadlineInPast(_deadline);

        // As alva is required in any case
        _checkValidTokensAndWeights(_newTokens, _newWeights);

        IBSKTPair(bsktPair).setReentrancyGuardStatus(true);
        IBSKTPair(bsktPair).transferTokensToOwner();

        uint256 _wethBought;

        address wethAddress = _factory().weth();
        address routerAddress = _factory().router();
        uint256 tokensLength = _tokenDetails.tokens.length;


        emit BSKTRebalancedV2(
            address(this),
            _tokenDetails.tokens,
            _tokenDetails.weights,
            _newTokens,
            _newWeights
        );

        IBSKTPair(bsktPair).updateTokens(_newTokens);
        _tokenDetails.tokens = _newTokens;
        _tokenDetails.weights = _newWeights;
        IBSKTPair(bsktPair).setReentrancyGuardStatus(false);
    }

    /// @notice Swaps tokens using the Uniswap router
    /// @dev Internal function to handle token swaps with buffer protection
    /// @param _tokenIn Address of the input token
    /// @param _tokenOut Address of the output token
    /// @param _router Address of the Uniswap router
    /// @param _amountIn Amount of input tokens
    /// @param _to Address to receive output tokens
    /// @param _buffer Maximum allowed buffer percentage
    /// @return Amount of output tokens received
    function _swapTokensForTokens(
        address _tokenIn,
        address _tokenOut,
        address _router,
        uint256 _amountIn,
        address _to,
        uint256 _buffer,
        uint256 _deadline
    ) private returns (uint256) {
        IERC20Upgradeable(_tokenIn).safeApprove(_router, 0);
        IERC20Upgradeable(_tokenIn).safeApprove(_router, _amountIn);

        address[] memory path = _factory().getPath(_tokenIn, _tokenOut);
        if (path.length != 2) revert InvalidLength();

        uint256 _amountOutMin = (_factory().getAmountsOut(_amountIn, path) *
            (PERCENT_PRECISION - _buffer)) / PERCENT_PRECISION;

        uint256 balanceBefore = IERC20Upgradeable(_tokenOut).balanceOf(_to);
        IUniswapV2Router(_router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                _amountIn,
                _amountOutMin,
                path,
                _to,
                _deadline
            );
        uint256 balanceAfter = IERC20Upgradeable(_tokenOut).balanceOf(_to);

        return balanceAfter - balanceBefore;
    }

    /// @notice Registers an interface with ERC165
    /// @dev Adds the interface ID to the supported interfaces mapping for standard detection
    /// @dev This enables NFT marketplace and wallet compatibility via ERC-165 interface detection
    /// @param interfaceId The interface identifier, as specified in ERC-165
    function _registerInterface(bytes4 interfaceId) internal virtual {
        if (interfaceId == 0xffffffff) revert InvalidInterfaceId();
        _supportedInterfaces[interfaceId] = true;
    }

    /// @notice Checks if any address in the array matches the given address
    /// @dev Loops through the array starting from the given index and checks for matches
    /// @param _array Array to loop through
    /// @param _address Address to check
    /// @param _startIndex Index to start checking from
    function _checkForDuplicateAddress(
        address[] memory _array,
        address _address,
        uint256 _startIndex
    ) internal pure returns (bool) {
        if (_array.length > _startIndex) {
            for (uint256 i = _startIndex; i < _array.length; ) {
                if (_array[i] == _address) revert DuplicateToken();
                unchecked {
                    ++i;
                }
            }
        }
        return false;
    }

    /// @notice Returns the factory instance casted to IFactory interface
    /// @dev Used to avoid repeated casting of the factory address in loops and functions
    /// @return factoryInstance The factory interface instance
    function _factory() private view returns (IFactory) {
        return IFactory(factory);
    }

    /**
     * @notice Checks if an address is a contract
     * @param target The address to check
     * @return bool True if the address is a contract, false otherwise
     */
    function isContractAddress(address target) internal view returns (bool) {
        return AddressUpgradeable.isContract(target);
    }

    // ===============================================
    // Public/External View/Pure Functions
    // ===============================================

    /// @notice Gets the total number of tokens in the basket
    /// @dev Returns the length of the tokens array
    /// @return tokenLength Number of tokens in the basket
    function totalTokens() external view returns (uint256 tokenLength) {
        tokenLength = _tokenDetails.tokens.length;
    }

    /// @notice Calculates the total value of all tokens in WETH
    /// @dev Converts each token's value to its WETH equivalent using the router
    /// @return value Total value of all tokens in WETH
    function getTokenValueByWETH() public view returns (uint256 value) {
        IFactory factoryInstance = _factory(); 
        address wethAddress = factoryInstance.weth(); 
        uint256 tokensLength = _tokenDetails.tokens.length;
        
        for (uint256 i = 0; i < tokensLength; ) {
            address token = _tokenDetails.tokens[i]; 
            uint256 balance = IBSKTPair(bsktPair).getTokenReserve(i); 
            
            address[] memory path = factoryInstance.getPath(token, wethAddress); 
            
            value += factoryInstance.getAmountsOut(balance, path); 
            
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns the contract-level metadata URI
    /// @dev Used for OpenSea and other marketplaces to display collection info
    /// @return URI string from the factory contract
    function contractURI() public view returns (string memory) {
        return _factory().getContractURI();
    }

    /// @notice Checks if contract supports a given interface
    /// @dev Combines OpenZeppelin's implementation with custom interfaces
    /// @param interfaceId Interface identifier to check
    /// @return True if interface is supported
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721URIStorageUpgradeable, IERC165Upgradeable, IBSKT)
        returns (bool)
    {
        return
            super.supportsInterface(interfaceId) ||
            _supportedInterfaces[interfaceId];
    }

    /// @notice Calculates royalty information for token sales
    /// @dev Implements ERC2981 to provide royalty information
    /// @param _salePrice Price at which the token is being sold
    /// @return receiver Address to receive royalties
    /// @return royaltyAmount Amount of royalty to pay
    function royaltyInfo(
        uint256, /* _tokenId */
        uint256 _salePrice
    )
        external
        view
        override(IBSKT, IERC2981Upgradeable)
        returns (address receiver, uint256 royaltyAmount)
    {
        receiver = _factory().royaltyReceiver();
        uint256 rate = _factory().royaltyPercentage();
        if (rate > 0 && receiver != address(0)) {
            royaltyAmount = (_salePrice * rate) / PERCENT_PRECISION;
        }
    }

    /// @notice Gets the details of a token at specified index
    /// @dev Returns both the token address and its weight in the basket
    /// @param _index Index of the token in the basket
    /// @return token Address of the token
    /// @return weight Weight of the token in the basket
    function getTokenDetails(uint256 _index)
        external
        view
        returns (address token, uint256 weight)
    {
        uint256 length = _tokenDetails.tokens.length;
        if (_index >= length) revert TokenIndexOutOfBounds(_index, length);
        token = _tokenDetails.tokens[_index];
        weight = _tokenDetails.weights[_index];
    }

    /// @notice Gets all token details including addresses and weights
    /// @return tokens Array of token addresses
    /// @return weights Array of token weights
    function getTokenDetails()
        external
        view
        returns (address[] memory tokens, uint256[] memory weights)
    {
        return (_tokenDetails.tokens, _tokenDetails.weights);
    }

    /// @notice Get existing owner of BSKT, which will be the owner of 0 token
    /// @return owner address
    function getOwner() public view returns (address owner) {
        return ownerOf(0);
    }
    
    // ===============================================
    // New V2 Methods
    // ===============================================
    
    /// @notice Sets the performance fee percentage
    /// @dev Only callable by the owner
    /// @param _feePercent New performance fee percentage (using PERCENT_PRECISION)
    function setPerformanceFee(uint256 _feePercent) external onlyOwner {
        if (_feePercent > 2000) revert("Fee too high"); // Max 20%
        performanceFeePercent = _feePercent;
        emit PerformanceFeeSetV2(address(this), _feePercent);
    }
    
    /// @notice Rebalances the basket according to target weights
    /// @dev Allows the owner to adjust token allocations to match target weights
    /// @param _targetWeights New target weights for the tokens
    /// @param _buffer Maximum allowed buffer percentage (0-5000)
    /// @param _deadline Deadline for the transaction
    function rebalanceV2(
        uint256[] calldata _targetWeights,
        uint256 _buffer,
        uint256 _deadline
    ) external onlyOwner nonReentrant checkLength(_tokenDetails.tokens.length, _targetWeights.length) {
        if (_buffer == 0 || _buffer >= 5000) {
            revert InvalidBuffer(_buffer, 1, 4999);
        }
        if (_deadline <= block.timestamp) revert DeadlineInPast(_deadline);
        
        // Implementation would go here - simplified for this example
        // This would typically involve swapping tokens to match target weights
        
        lastRebalanceTimestamp = block.timestamp;
        emit BasketRebalancedV2(address(this), getOwner(), _tokenDetails.tokens, _targetWeights);
    }
    
    /// @notice Calculates and collects performance fees
    /// @dev Compares current value to previous value and takes a fee on gains
    /// @return feeAmount The amount of fee collected
    function collectPerformanceFee() external onlyOwner returns (uint256 feeAmount) {
        if (performanceFeePercent == 0) return 0;
        
        // Implementation would go here - simplified for this example
        // This would typically calculate the basket's performance and take a fee
        
        // For demonstration purposes only
        feeAmount = 0;
        emit PerformanceFeeCollectedV2(address(this), getOwner(), feeAmount);
        return feeAmount;
    }
    
    /// @notice Gets the version of the implementation
    /// @dev Used to verify the upgrade was successful
    /// @return The version number of this implementation
    function getVersion() external pure returns (uint256) {
        return VERSION;
    }
    

}
