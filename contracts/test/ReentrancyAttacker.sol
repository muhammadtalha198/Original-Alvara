// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IBSKTPair.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Interface for BasketTokenStandard with just the functions we need
interface IBasketTokenStandard {
    function contribute(uint256 _buffer, uint256 _deadline ) external payable;
    function withdraw(uint256 _liquidity, uint256 _deadline) external;
    function withdrawETH(uint256 _liquidity, uint256 _buffer, uint256 _deadline) external;
    receive() external payable;
}

/**
 * @title ReentrancyAttacker
 * @dev Contract to test reentrancy protection in BSKTTokenStandard
 */
contract ReentrancyAttacker {
    address payable public bsktAddress;
    address public bsktPairAddress;
    bool public attacking = false;
    bool public attackSucceeded = false;
    string public revertReason = "";
    uint256 deadline;
    
    enum AttackType { NONE, CONTRIBUTE, WITHDRAW, WITHDRAW_ETH }
    AttackType public attackType = AttackType.NONE;
    
    // Events for debugging
    event AttackInitiated(string attackType);
    event ReceiveTriggered(uint256 amount);
    event AttackCompleted(bool success, string revertReason);
    
    // Receive function to handle ETH transfers
    receive() external payable {
        emit ReceiveTriggered(msg.value);
        
        // If we're in the middle of an attack, try to reenter
        if (attacking) {
            if (bsktAddress != address(0)) {
                // Try to reenter the contract based on the attack type
                if (attackType == AttackType.CONTRIBUTE) {
                    // Try to call contribute again during the first contribute call
                    try IBasketTokenStandard(bsktAddress).contribute{value: msg.value / 2}(100, deadline) {
                        // If this succeeds, the reentrancy guard is not working
                        attackSucceeded = true;
                    } catch Error(string memory reason) {
                        // Expected to fail with reentrancy guard
                        revertReason = reason;
                    } catch {
                        // Expected to fail with reentrancy guard
                        revertReason = "unknown error";
                    }
                } else if (attackType == AttackType.WITHDRAW) {
                    // Try to call withdraw again during the first withdraw call
                    try IBasketTokenStandard(bsktAddress).withdraw(1, deadline) {
                        // If this succeeds, the reentrancy guard is not working
                        attackSucceeded = true;
                    } catch Error(string memory reason) {
                        // Expected to fail with reentrancy guard
                        revertReason = reason;
                    } catch {
                        // Expected to fail with reentrancy guard
                        revertReason = "unknown error";
                    }
                } else if (attackType == AttackType.WITHDRAW_ETH) {
                    // Try to call withdrawETH again during the first withdrawETH call
                    try IBasketTokenStandard(bsktAddress).withdrawETH(1, 100, deadline) {
                        // If this succeeds, the reentrancy guard is not working
                        attackSucceeded = true;
                    } catch Error(string memory reason) {
                        // Expected to fail with reentrancy guard
                        revertReason = reason;
                    } catch {
                        // Expected to fail with reentrancy guard
                        revertReason = "unknown error";
                    }
                }
            }
        }
    }
    
    // Set the BSKT contract address
    function setBSKTAddress(address payable _bsktAddress) external {
        bsktAddress = _bsktAddress;
    }
    
    // Set the BSKT Pair contract address
    function setBSKTPairAddress(address _bsktPairAddress) external {
        bsktPairAddress = _bsktPairAddress;
    }
    
    // Attack the contribute function
    function attackContribute(uint256 _buffer, uint256 _deadline) external payable {
        require(bsktAddress != address(0), "BSKT address not set");
        emit AttackInitiated("contribute");
        
        attackType = AttackType.CONTRIBUTE;
        attacking = true;
        attackSucceeded = false;
        revertReason = "";
        deadline = _deadline;
        
        // Call contribute, which will send ETH to this contract via the receive function
        try IBasketTokenStandard(bsktAddress).contribute{value: msg.value}(_buffer, _deadline) {
            // If we get here, the initial contribute call succeeded
            // but we need to check if our reentrancy attempt succeeded
            if (attackSucceeded) {
                revert("Reentrancy attack succeeded");
            }
        } catch Error(string memory reason) {
            revertReason = reason;
        } catch {
            revertReason = "unknown error";
        }
        
        attacking = false;
        attackType = AttackType.NONE;
        emit AttackCompleted(attackSucceeded, revertReason);
    }
    
    // Attack the withdraw function
    function attackWithdraw(uint256 _deadline) external {
        require(bsktAddress != address(0), "BSKT address not set");
        require(bsktPairAddress != address(0), "BSKT Pair address not set");
        emit AttackInitiated("withdraw");
        
        attackType = AttackType.WITHDRAW;
        attacking = true;
        attackSucceeded = false;
        revertReason = "";
        deadline = _deadline;
        
        // Get our LP token balance
        uint256 lpBalance = IERC20(bsktPairAddress).balanceOf(address(this));
        // Approve the BSKT contract to spend our LP tokens
        IERC20(bsktPairAddress).approve(bsktAddress, lpBalance);
        
        // Call withdraw, which should trigger a callback to this contract
        try IBasketTokenStandard(bsktAddress).withdraw(lpBalance, _deadline) {
            // If we get here, the initial withdraw call succeeded
            // but we need to check if our reentrancy attempt succeeded
            if (attackSucceeded) {
                revert("Reentrancy attack succeeded");
            }
        } catch Error(string memory reason) {
            revertReason = reason;
        } catch {
            revertReason = "unknown error";
        }
        
        attacking = false;
        attackType = AttackType.NONE;
        emit AttackCompleted(attackSucceeded, revertReason);
    }
    
    // Attack the withdrawETH function
    function attackWithdrawETH(uint256 _buffer, uint256 _deadline) external {
        require(bsktAddress != address(0), "BSKT address not set");
        require(bsktPairAddress != address(0), "BSKT Pair address not set");
        emit AttackInitiated("withdrawETH");
        
        attackType = AttackType.WITHDRAW_ETH;
        attacking = true;
        attackSucceeded = false;
        revertReason = "";
        deadline = _deadline;
        
        // Get our LP token balance
        uint256 lpBalance = IERC20(bsktPairAddress).balanceOf(address(this));
        // Approve the BSKT contract to spend our LP tokens
        IERC20(bsktPairAddress).approve(bsktAddress, lpBalance);
        
        // Call withdrawETH, which should trigger a callback to this contract
        try IBasketTokenStandard(bsktAddress).withdrawETH(lpBalance, _buffer, _deadline) {
            // If we get here, the initial withdrawETH call succeeded
            // but we need to check if our reentrancy attempt succeeded
            if (attackSucceeded) {
                revert("Reentrancy attack succeeded");
            }
        } catch Error(string memory reason) {
            revertReason = reason;
        } catch {
            revertReason = "unknown error";
        }
        
        attacking = false;
        attackType = AttackType.NONE;
        emit AttackCompleted(attackSucceeded, revertReason);
    }
}
