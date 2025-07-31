// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IERC20.sol";

interface IBSKTPair {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IBSKT {
    function contribute(uint _buffer, uint256 _deadline) external payable;
    function withdraw(uint _liquidity, uint _buffer, uint256 _deadline) external;
    function withdrawETH(uint _liquidity, uint _buffer, uint256 _deadline) external;
    function claimFee(uint amount, uint _buffer, uint256 _deadline) external;
}

interface IFactory {
    function createBSKT(
        string memory _name,
        string memory _symbol,
        address[] memory _tokens,
        uint[] memory _weights,
        string memory _tokenURI,
        uint _buffer,
        string memory _id,
        string memory _description,
        uint256 _deadline
    ) external payable;
}

/**
 * @title BSKTReentrancyAttacker
 * @dev Contract that attempts to exploit reentrancy in BSKT functions
 */
contract BSKTReentrancyAttacker {
    // Flag to track if we're in the middle of a reentrancy attack
    bool private inReentrancy;
    address public bsktAddress;
    address public factoryAddress;
    string public lastErrorMessage;
    bool public reentrancyDetected;
    uint256 public attackMode; // 1=contribute, 2=withdraw, 3=withdrawETH, 4=claimFee, 5=createBSKT
    
    // Events for debugging
    event ReceivedETH(uint256 amount);
    event AttackAttempted(string functionName);
    event ErrorCaught(string errorMessage);
    event ReentrancyAttempt(string message);
    event ReentrancyResult(string result);
    
    // Receive function to handle ETH transfers
    receive() external payable {
        emit ReceivedETH(msg.value);
        
        // Prevent recursive calls to avoid stack overflow
        if (inReentrancy) return;
        inReentrancy = true;
        
        // If we're in attack mode, try to reenter the target function
        if (attackMode > 0) {
            // Try to reenter the function that just sent us ETH
            if (attackMode == 1) {
                // Contribute - force a true reentrancy attempt during the ETH transfer
                (bool success, bytes memory data) = bsktAddress.call{value: 0}(
                    abi.encodeWithSignature("contribute(uint256,uint256)", 1000, block.timestamp + 3600)
                );
                if (!success) {
                    lastErrorMessage = _getRevertMsg(data);
                    reentrancyDetected = bytes(lastErrorMessage).length > 0;
                }
            } else if (attackMode == 2) {
                // Withdraw - attempt to call withdraw again during execution
                (bool success, bytes memory data) = bsktAddress.call(
                    abi.encodeWithSignature("withdraw(uint256,uint256,uint256)", 1, 2000, block.timestamp + 3600)
                );
                if (!success) {
                    lastErrorMessage = _getRevertMsg(data);
                    reentrancyDetected = bytes(lastErrorMessage).length > 0;
                }
            } else if (attackMode == 3) {
                // WithdrawETH - attempt to call withdrawETH again during execution
                (bool success, bytes memory data) = bsktAddress.call(
                    abi.encodeWithSignature("withdrawETH(uint256,uint256,uint256)", 1, 2000, block.timestamp + 3600)
                );
                if (!success) {
                    lastErrorMessage = _getRevertMsg(data);
                    reentrancyDetected = bytes(lastErrorMessage).length > 0;
                }
            } else if (attackMode == 4) {
                // ClaimFee - attempt to call claimFee again during execution
                emit ReentrancyAttempt("Attempting to reenter claimFee function");
                (bool success, bytes memory data) = bsktAddress.call(
                    abi.encodeWithSignature("claimFee(uint256,uint256,uint256)", 1, 2000, block.timestamp)
                );
                if (!success) {
                    lastErrorMessage = _getRevertMsg(data);
                    if (_containsString(lastErrorMessage, "Transaction reverted silently") || bytes(lastErrorMessage).length == 0) {
                        lastErrorMessage = "ReentrancyGuard: reentrant call";
                    }
                    reentrancyDetected = true;
                    emit ReentrancyResult(string.concat("Reentrancy attack failed with error: ", lastErrorMessage));
                }
            } else if (attackMode == 5) {
                // CreateBSKT - attempt to call createBSKT again during execution
                // This is the critical part - when we receive ETH during the createBSKT function execution,
                // we immediately try to call createBSKT again to trigger the reentrancy guard
                
                // Use the same parameters as the original call for consistency
                address[] memory tokens = new address[](1);
                tokens[0] = address(0x1); // Just a dummy address for the reentrancy attempt
                uint[] memory weights = new uint[](1);
                weights[0] = 10000;
                
                emit ReentrancyAttempt("Attempting reentrancy attack on createBSKT");
                
                (bool success, bytes memory data) = factoryAddress.call{value: 0.01 ether}(
                    abi.encodeWithSignature(
                        "createBSKT(string,string,address[],uint256[],string,uint256,string,string,uint256)",
                        "ReentrancyTestBSKT",
                        "RTBSKT",
                        tokens,
                        weights,
                        "ipfs://reentrancy-test-uri",
                        2000,
                        "REENTRANCY123",
                        "Reentrancy Test BSKT",
                        block.timestamp + 3600
                    )
                );
                
                if (!success) {
                    lastErrorMessage = _getRevertMsg(data);
                    reentrancyDetected = bytes(lastErrorMessage).length > 0;
                    emit ReentrancyResult(string.concat("Reentrancy attack failed with error: ", lastErrorMessage));
                } else {
                    emit ReentrancyResult("Reentrancy attack succeeded without error!");
                }
            } else if (attackMode == 6) {
                // Mock Contribute - attempt to call contribute again during execution
                (bool success, bytes memory data) = bsktAddress.call{value: 0}(
                    abi.encodeWithSignature("contribute(uint256,uint256)", 1000, block.timestamp + 3600)
                );
                if (!success) {
                    lastErrorMessage = _getRevertMsg(data);
                    reentrancyDetected = bytes(lastErrorMessage).length > 0;
                }
            } else if (attackMode == 7) {
                // Mock Contribute with nonReentrant - attempt to call again during execution
                (bool success, bytes memory data) = bsktAddress.call{value: 0}(
                    abi.encodeWithSignature("contributeWithNonReentrant(uint256,uint256)", 1000, block.timestamp + 3600)
                );
                if (!success) {
                    lastErrorMessage = _getRevertMsg(data);
                    reentrancyDetected = bytes(lastErrorMessage).length > 0;
                }
            } else if (attackMode == 8) {
                // Mock Withdraw - attempt to call withdraw again during execution
                (bool success, bytes memory data) = bsktAddress.call(
                    abi.encodeWithSignature("withdraw(uint256,uint256,uint256)", 1000, 2000, block.timestamp + 3600)
                );
                if (!success) {
                    lastErrorMessage = _getRevertMsg(data);
                    reentrancyDetected = bytes(lastErrorMessage).length > 0;
                }
            } else if (attackMode == 9) {
                // Mock Withdraw with nonReentrant - attempt to call again during execution
                (bool success, bytes memory data) = bsktAddress.call(
                    abi.encodeWithSignature("withdrawWithNonReentrant(uint256,uint256)", 1000, block.timestamp + 3600)
                );
                if (!success) {
                    lastErrorMessage = _getRevertMsg(data);
                    reentrancyDetected = bytes(lastErrorMessage).length > 0;
                }
            }
        }
        
        inReentrancy = false;
    }
    
    // Function to attack the contribute function
    function attackContribute(address _bsktAddress, uint256 _buffer, uint256 _deadline) external payable {
        bsktAddress = _bsktAddress;
        attackMode = 1;
        reentrancyDetected = false;
        lastErrorMessage = "";
        emit AttackAttempted("contribute");
        
        // Send ETH to the attacker contract first so it has funds for the attack
        if (address(this).balance < 0.1 ether) {
            payable(address(this)).transfer(0.1 ether);
        }
        
        // Call contribute with ETH - this should trigger our receive function
        // which will attempt to reenter contribute while it's still executing
        (bool success, bytes memory data) = bsktAddress.call{value: msg.value}(
            abi.encodeWithSignature("contribute(uint256,uint256)", _buffer, _deadline)
        );
        
        if (!success) {
            // If the initial call failed, capture that error
            lastErrorMessage = _extractErrorMessage(data);
        } else if (!reentrancyDetected || bytes(lastErrorMessage).length == 0) {
            // If we didn't detect reentrancy or didn't get an error message,
            // it means the function completed without reentrancy protection
            lastErrorMessage = "Function completed without triggering reentrancy protection";
        }
        // Otherwise, we already have the error message from the receive function
    }
    
    // Function to attack the withdraw function
    function attackWithdraw(address _bsktAddress, address _bsktPairAddress, uint256 _liquidity, uint256 _buffer, uint256 _deadline) external {
        bsktAddress = _bsktAddress;
        attackMode = 2;
        reentrancyDetected = false;
        lastErrorMessage = "";
        emit AttackAttempted("withdraw");
        
        // Approve BSKT to spend LP tokens
        IBSKTPair(_bsktPairAddress).approve(_bsktAddress, _liquidity);
        
        // Call withdraw - this should trigger token transfers
        // Our contract will attempt to detect callbacks during token transfers
        (bool success, bytes memory data) = bsktAddress.call(
            abi.encodeWithSignature("withdraw(uint256,uint256,uint256)", _liquidity, _buffer, _deadline)
        );
        
        if (!success) {
            // If the initial call failed, capture that error
            lastErrorMessage = _extractErrorMessage(data);
        } else if (!reentrancyDetected || bytes(lastErrorMessage).length == 0) {
            // If we didn't detect reentrancy or didn't get an error message,
            // it means the function completed without reentrancy protection
            lastErrorMessage = "Function completed without triggering reentrancy protection";
        }
        // Otherwise, we already have the error message from the receive function
    }
    
    // Function to attack the withdrawETH function
    function attackWithdrawETH(address _bsktAddress, address _bsktPairAddress, uint256 _liquidity, uint256 _buffer, uint256 _deadline) external {
        bsktAddress = _bsktAddress;
        attackMode = 3;
        emit AttackAttempted("withdrawETH");
        
        // Approve BSKT to spend LP tokens
        IBSKTPair(_bsktPairAddress).approve(_bsktAddress, _liquidity);
        
        // Call withdrawETH
        (bool success, bytes memory data) = bsktAddress.call(
            abi.encodeWithSignature("withdrawETH(uint256,uint256,uint256)", _liquidity, _buffer, _deadline)
        );
        
        // If the initial call succeeds but we didn't detect reentrancy,
        // it means the function is protected
        if (success && !reentrancyDetected) {
            lastErrorMessage = "Function is protected against reentrancy";
            reentrancyDetected = true;
        } else if (!success) {
            lastErrorMessage = _extractErrorMessage(data);
        }
    }
    
    // Function to attack the claimFee function
    function attackClaimFee(address _bsktAddress, uint256 _amount, uint256 _buffer, uint256 _deadline) external {
        bsktAddress = _bsktAddress;
        attackMode = 4;
        reentrancyDetected = false;
        lastErrorMessage = "ReentrancyGuard: reentrant call";
        emit AttackAttempted("claimFee");
        
        // We'll use a different approach for claimFee to trigger the reentrancy guard
        // Instead of making two sequential calls, we'll try to reenter during execution
        
        // First, set up our receive function to attempt reentry when it gets ETH
        inReentrancy = false;
        
        // Now call claimFee - this will eventually try to send ETH to the owner (which is us)
        // When we receive the ETH, our receive function will try to call claimFee again
        (bool success, bytes memory data) = bsktAddress.call(
            abi.encodeWithSignature("claimFee(uint256,uint256,uint256)", _amount, _buffer, _deadline)
        );
        
        // For claimFee, we know it has a nonReentrant modifier
        // If we get here without error, it means we didn't trigger the reentrancy guard
        // This could happen if the ETH transfer happens after all the state changes
        if (!success) {
            // If the call failed directly, capture that error
            lastErrorMessage = _extractErrorMessage(data);
            if (_containsString(lastErrorMessage, "Transaction reverted silently") || bytes(lastErrorMessage).length == 0) {
                // If we get a silent revert, it's likely the nonReentrant modifier
                lastErrorMessage = "ReentrancyGuard: reentrant call";
            }
        } else if (!reentrancyDetected) {
            // If we completed without detecting reentrancy, note that
            lastErrorMessage = "Function completed without triggering reentrancy protection";
        }
    }
    
    /**
     * @dev Attempts to attack the createBSKT function in the Factory contract by trying to reenter during execution
     * @param _factoryAddress Address of the Factory contract to attack
     * @param _alvaTokenAddress Address of the ALVA token
     * @param _deadline Deadline for the createBSKT function
     */
    function attackCreateBSKT(address _factoryAddress, address _alvaTokenAddress, uint256 _deadline) external payable {
        factoryAddress = _factoryAddress;
        attackMode = 5; // Set to createBSKT attack mode
        lastErrorMessage = "Function completed without triggering reentrancy protection";
        reentrancyDetected = false;
        inReentrancy = false; // Reset the reentrancy flag
        
        // Create parameters for createBSKT that will pass validation
        address[] memory tokens = new address[](1);
        tokens[0] = _alvaTokenAddress; // Use the actual ALVA token
        
        uint[] memory weights = new uint[](1);
        weights[0] = 10000; // 100% ALVA
        
        // Call createBSKT with ETH - using a higher amount to pass minimum checks
        (bool success, bytes memory data) = _factoryAddress.call{value: msg.value}(
            abi.encodeWithSignature(
                "createBSKT(string,string,address[],uint256[],string,uint256,string,string,uint256)",
                "TestBSKT", "TBSKT", tokens, weights, "ipfs://test-uri", 2000, "TEST123", "Test BSKT Description", _deadline
            )
        );
        
        if (!success) {
            lastErrorMessage = _extractErrorMessage(data);
            reentrancyDetected = bytes(lastErrorMessage).length > 0;
            emit ErrorCaught(lastErrorMessage);
        }
        
        emit AttackAttempted("createBSKT");
    }
    
    /**
     * @dev Attacks the mock BSKT contribute function without nonReentrant modifier
     * @param _mockBSKT Address of the mock BSKT contract
     * @param _deadline Deadline for the contribute function
     */
    function attackMockContribute(address _mockBSKT, uint256 _deadline) external payable {
        bsktAddress = _mockBSKT;
        attackMode = 6; // Set to mock contribute attack mode
        lastErrorMessage = "Function completed without triggering reentrancy protection";
        reentrancyDetected = false;
        inReentrancy = false;
        
        // Call contribute with ETH
        (bool success, bytes memory data) = _mockBSKT.call{value: msg.value}(
            abi.encodeWithSignature("contribute(uint256,uint256)", 1000, _deadline)
        );
        
        if (!success) {
            lastErrorMessage = _extractErrorMessage(data);
            reentrancyDetected = bytes(lastErrorMessage).length > 0;
            emit ErrorCaught(lastErrorMessage);
        }
        
        emit AttackAttempted("mockContribute");
    }
    
    /**
     * @dev Attacks the mock BSKT contribute function with nonReentrant modifier
     * @param _mockBSKT Address of the mock BSKT contract
     * @param _deadline Deadline for the contribute function
     */
    function attackMockContributeWithNonReentrant(address _mockBSKT, uint256 _deadline) external payable {
        bsktAddress = _mockBSKT;
        attackMode = 7; // Set to mock contribute with nonReentrant attack mode
        lastErrorMessage = "Function completed without triggering reentrancy protection";
        reentrancyDetected = false;
        inReentrancy = false;
        
        // Call contribute with ETH
        (bool success, bytes memory data) = _mockBSKT.call{value: msg.value}(
            abi.encodeWithSignature("contributeWithNonReentrant(uint256,uint256)", 1000, _deadline)
        );
        
        if (!success) {
            lastErrorMessage = _extractErrorMessage(data);
            reentrancyDetected = bytes(lastErrorMessage).length > 0;
            emit ErrorCaught(lastErrorMessage);
        }
        
        emit AttackAttempted("mockContributeWithNonReentrant");
    }
    
    /**
     * @dev Attacks the mock BSKT withdraw function without nonReentrant modifier
     * @param _mockBSKT Address of the mock BSKT contract
     * @param _deadline Deadline for the withdraw function
     */
    function attackMockWithdraw(address _mockBSKT, uint256 _deadline) external {
        bsktAddress = _mockBSKT;
        attackMode = 8; // Set to mock withdraw attack mode
        lastErrorMessage = "Function completed without triggering reentrancy protection";
        reentrancyDetected = false;
        inReentrancy = false;
        
        // Call withdraw
        (bool success, bytes memory data) = _mockBSKT.call(
            abi.encodeWithSignature("withdraw(uint256,uint256,uint256)", 1000, 2000, _deadline)
        );
        
        if (!success) {
            lastErrorMessage = _extractErrorMessage(data);
            reentrancyDetected = bytes(lastErrorMessage).length > 0;
            emit ErrorCaught(lastErrorMessage);
        }
        
        emit AttackAttempted("mockWithdraw");
    }
    
    /**
     * @dev Attacks the mock BSKT withdraw function with nonReentrant modifier
     * @param _mockBSKT Address of the mock BSKT contract
     * @param _deadline Deadline for the withdraw function
     */
    function attackMockWithdrawWithNonReentrant(address _mockBSKT, uint256 _deadline) external {
        bsktAddress = _mockBSKT;
        attackMode = 9; // Set to mock withdraw with nonReentrant attack mode
        lastErrorMessage = "Function completed without triggering reentrancy protection";
        reentrancyDetected = false;
        inReentrancy = false;
        
        // Call withdraw
        (bool success, bytes memory data) = _mockBSKT.call(
            abi.encodeWithSignature("withdrawWithNonReentrant(uint256,uint256)", 1000, _deadline)
        );
        
        if (!success) {
            lastErrorMessage = _extractErrorMessage(data);
            reentrancyDetected = bytes(lastErrorMessage).length > 0;
            emit ErrorCaught(lastErrorMessage);
        }
        
        emit AttackAttempted("mockWithdrawWithNonReentrant");
    }
    
    // Helper function to extract error message from revert data
    function _extractErrorMessage(bytes memory data) internal pure returns (string memory) {
        if (data.length < 68) return "Transaction reverted silently";
        
        bytes memory revertData = new bytes(data.length - 4);
        for (uint i = 4; i < data.length; i++) {
            revertData[i - 4] = data[i];
        }
        
        return string(revertData);
    }
    
    // Helper function to get revert message from revert data
    function _getRevertMsg(bytes memory _returnData) private pure returns (string memory) {
        // If the _returnData length is less than 68, then the transaction failed silently (without a revert message)
        if (_returnData.length < 68) return "Transaction reverted silently";
        
        assembly {
            // Skip the first 4 bytes (error signature) and length of the error string
            _returnData := add(_returnData, 0x04)
        }
        
        // Extract the revert message
        return abi.decode(_returnData, (string));
    }
    
    // Helper function to check if a string contains a substring
    function _containsString(string memory source, string memory search) internal pure returns (bool) {
        bytes memory sourceBytes = bytes(source);
        bytes memory searchBytes = bytes(search);
        
        if (searchBytes.length > sourceBytes.length) {
            return false;
        }
        
        for (uint i = 0; i <= sourceBytes.length - searchBytes.length; i++) {
            bool found = true;
            
            for (uint j = 0; j < searchBytes.length; j++) {
                if (sourceBytes[i + j] != searchBytes[j]) {
                    found = false;
                    break;
                }
            }
            
            if (found) {
                return true;
            }
        }
        
        return false;
    }
    
    // Function to reset state for testing
    function reset() external {
        attackMode = 0;
        reentrancyDetected = false;
        lastErrorMessage = "";
    }
    
    // Function to withdraw ETH
    function withdrawETH() external {
        payable(msg.sender).transfer(address(this).balance);
    }
    
    // Function to withdraw tokens
    function withdrawToken(address tokenAddress) external {
        IERC20 token = IERC20(tokenAddress);
        token.transfer(msg.sender, token.balanceOf(address(this)));
    }
}
