// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;
/**
  This is custom UniswapV2Router02 smart-contract, to solve the faucet issue and price issue. 
  Now all Testnet Eth will be sent to this smart-contract and we have a 
  custom method to extract back the tokens to our admin address and re-use 
  the tokens
 */

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {IWETH} from "../interfaces/IWETH.sol";

contract UniswapV2Router02 is AccessControlUpgradeable {
    /* struct to store token details, price, manager(address who hold the tokens) */
    struct TokenDetail {
        uint256 price;
        address tokenManager;
    }

    /* Address to store WETH token address */
    address public immutable WETH;

    /* Mapping to store token-details against each token address. Price should be in 18 decimal places. Price should be in Eth */
    mapping(address => TokenDetail) public tokenDetails;

    /* Role for managing price */
    bytes32 public constant PRICE_MANAGER = keccak256("PRICE_MANAGER");

    /*
        Constructor to set WETH address while deployment and price manager role
    */
    constructor(address _WETH) {
        WETH = _WETH;
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(PRICE_MANAGER, _msgSender());
        tokenDetails[_WETH] = TokenDetail(1e18, _msgSender());
    }

    /*
     * Set the price of given token.
     *
     * @param {address} tokenAddress - Address of token smart-contract.
     * @param {address} tokenManager - Address which hold tokens for swaping.
     * @param {uint256} price - Real price of token in term of Eth, containing 18 decimal points.
     */
    function setTokenDetails(
        address tokenAddress,
        address tokenManager,
        uint256 price
    ) public onlyRole(PRICE_MANAGER) {
        tokenDetails[tokenAddress] = TokenDetail(price, tokenManager);
    }

    /*
     * To set the prices of multiple tokens in 1 transaction
     *
     * @param {address[]} tokenAddresses - Addresses of token smart-contracts.
     * @param {address[]} tokenManagers - Addresses which hold tokens for swaping.
     * @param {uint256[]} prices - Real prices of each token in term of Eth, containing 18 decimal points. first element of price represent first token.
     */
    function setTokensDetails(
        address[] memory tokenAddresses,
        address[] memory tokenManagers,
        uint256[] memory prices
    ) public onlyRole(PRICE_MANAGER) {
        require(
            tokenAddresses.length <= 30,
            "UniswapV2Router: Tokens array is too long, reduce the number of tokens"
        );

        for (uint256 i; i < tokenAddresses.length; i++) {
            tokenDetails[tokenAddresses[i]] = TokenDetail(
                prices[i],
                tokenManagers[i]
            );
        }
    }

    /*
     * This function is used to swap ETH for tokens that may have transfer fees (fee-on-transfer tokens).
     * This method is payable, will receive Eth in value and get WETH token and transfer to given address
     *
     * @param {uint} amountOutMin - The amount of token that minimum user want to get, to avoid buffer.
     * @param {address[]} path - path will an array of 2 token addresses. where 1st address represent tokenIn (WETH) and 2nd token will be token out
     * @param {address} to - to will be the address which will get the token.
     * @param {uint} deadline - deadline is a timestamp which will be the last timestamped where a trx can be executed.
     */

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) public payable {
        require(path[0] == WETH, "UniswapV2Router: INVALID_PATH");
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");

        uint amountIn = msg.value;
        uint amountOut = getAmountsOut(amountIn, path)[1];
        require(
            amountOut > 0 && amountOut >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );

        address manager = tokenDetails[path[1]].tokenManager;
        uint256 allowance = IWETH(path[1]).allowance(manager, address(this));
        require(
            allowance >= amountOut,
            "UniswapV2Router: INSUFFICIENT_AMOUNT_ALLOWED"
        );

        IWETH(WETH).deposit{value: amountIn}();
        IWETH(WETH).transfer(path[1], amountIn);
        IWETH(path[1]).transferFrom(manager, to, amountOut);
    }

    // function swapExactTokensForETHSupportingFeeOnTransferTokens(
    //     uint amountIn,
    //     uint amountOutMin,
    //     address[] calldata path,
    //     address to,
    //     uint deadline
    // ) external;

    /*
     * This function is used to swap any token x for any token y that may have transfer fees (fee-on-transfer tokens).
     * This method is not payable, it just swap ERC-20 tokens with each other.
     * This method will get token x from user and send to token y's manager. Then send token y to user
     *
     * @param {uint256} amountIn - The amount of token x that user want to swap.
     * @param {uint256} amountOutMin - The minimum amount of token-y that a user want to get.
     * @param {address[]} path - path will an array of 2 token addresses. where 1st address represent tokenIn and 2nd token will be token out
     * @param {address} to - to will be the address which will get the token.
     * @param {uint} deadline - deadline is a timestamp which will be the last timestamped where a trx can be executed.
     */

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) public {
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");

        uint amountOut = getAmountsOut(amountIn, path)[1];
        require(
            amountOut > 0 && amountOut >= amountOutMin,
            "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT"
        );

        //address managerIn = tokenDetails[path[0]].tokenManager;
        address managerOut = tokenDetails[path[1]].tokenManager;

        uint256 allowanceTokenIn = IWETH(path[0]).allowance(
            _msgSender(),
            address(this)
        );

        require(
            allowanceTokenIn >= amountIn,
            "UniswapV2Router: INSUFFICIENT_AMOUNT_ALLOWED_TOKEN_IN"
        );

        uint256 allowanceTokenOut = IWETH(path[1]).allowance(
            managerOut,
            address(this)
        );

        require(
            allowanceTokenOut >= amountOut,
            "UniswapV2Router: INSUFFICIENT_AMOUNT_ALLOWED_TOKEN_OUT"
        );

        IWETH(path[0]).transferFrom(_msgSender(), address(this), amountIn);
        IWETH(path[0]).transfer(managerOut, amountIn);

        IWETH(path[1]).transferFrom(managerOut, to, amountOut);
    }

    // ########### All View methods ####################

    /*
     * Return the minimum amount that can be swaped for given token.
     *
     * @param {uint} amountIn - Amount that user want to swap with other token.
     * @param {address[]} path - path will an array of 2 token addresses. where 1st address represent tokenIn and 2nd token will be token out
     * @returns {uint[]} amounts- An array of amounts, 1st element represent the tokenIn amount and 2nd will be the amounts out.
     */
    function getAmountsOut(uint amountIn, address[] memory path)
        public
        view
        returns (uint[] memory amounts)
    {
        require(
            amountIn > 0,
            "UniswapV2Router: amountIn should be greater than zero"
        );
        require(
            path.length >= 2,
            "UniswapV2Router: path contains at least 2 elements"
        );

        amounts = new uint[](path.length);
        amounts[0] = amountIn;

        for (uint i; i < path.length - 1; i++) {
            if (tokenDetails[path[i + 1]].price != 0) {
                if (path[0] == WETH) {
                    amounts[i + 1] =
                        (amountIn * 1e18) /
                        tokenDetails[path[i + 1]].price;
                } else {
                    uint amountInEth = (amountIn *
                        1e18 *
                        tokenDetails[path[0]].price) / 1e18;
                    amounts[i + 1] =
                        amountInEth /
                        tokenDetails[path[i + 1]].price;
                }
            } else {
                amounts[i + 1] = 0;
            }
        }

        return amounts;
    }

    /*
     * Return the WETH address for Router.
     */
    function getWETHAddress() public view returns (address) {
        return WETH;
    }

    /*
     * Return the price of token in term of Eth registered in the contract.
     *
     * @param {address} tokenAddress - address of the token contract.
     * @returns {uint256} price- return the price to given token registered in the contract.
     */
    function getTokenPrice(address tokenAddress) public view returns (uint256) {
        return tokenDetails[tokenAddress].price;
    }

    /*
     * Return the detail of token like price, token-manager registered in the contract.
     *
     * @param {address} tokenAddress - address of the token contract.
     * @returns {TokenDetail} tokenDetail- return the details of given token registered in the contract.
     */
    function getTokenDetails(address tokenAddress)
        public
        view
        returns (TokenDetail memory)
    {
        return tokenDetails[tokenAddress];
    }
}
