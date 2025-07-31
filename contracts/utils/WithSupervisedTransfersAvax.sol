// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/**
 * Supervised transfers allow the admin to whitelist addresses who’re allowed to receive the token using transferFrom method.
 * The admin can also specify listing timestamp.
 * After the token listing, anyone can tranferFrom without any restrictions forever.
 * Before the listing, the admin can do anything they want, including adding providing and removing liquidity from the DEX.
 */
abstract contract WithSupervisedTransfersAvax is AccessControlUpgradeable {
    /**
     * @dev Once the listingTimestamp passes (which disables supervised transfers) it can never be set again.
     * This ensures once supervised transfers are disabled, they can never be enabled again.
     */
    error TokenAlreadyListed();

    /**
     * @dev Used before listing if not allowed transferFrom occurs.
     */
    error SupervisedTranferFrom();

    /**
     * Called every time the listing timestamp is updated for easy off-chain tracking.
     * @param newListingTimestamp the value of the new listing timestamp
     */
    event ListingTimestampUpdated(uint32 newListingTimestamp);

    bytes32 public constant ALLOWED_TRANSFER_FROM_ROLE =
        keccak256("ALLOWED_TRANSFER_FROM_ROLE");
    uint32 public listingTimestamp;

    /**
     * This modifier blocks all tranferFrom function calls unless:
     * - the token has already been listed
     * - OR the transaction involves admin
     * - OR the reciver is whitelisted
     * This modifier MUST be used on the transferFrom function.
     */
    modifier supervisedTransferFrom(address from, address to) {
        bool duringSupervisedTransfers = listingTimestamp == 0 ||
            block.timestamp < listingTimestamp;
        if (duringSupervisedTransfers) {
            bool transactionInvolvesAdmin = hasRole(DEFAULT_ADMIN_ROLE, from) ||
                hasRole(DEFAULT_ADMIN_ROLE, to) ||
                hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
            if (
                !transactionInvolvesAdmin &&
                !hasRole(ALLOWED_TRANSFER_FROM_ROLE, to)
            ) {
                revert SupervisedTranferFrom();
            }
        }
        _;
    }

    /**
     * The initialize grants the admin role to the deployer
     */
    function __WithSupervisedTransfers_init(
        bytes32 MINTER_ROLE,
        bytes32 BURN_ROLE
    ) internal onlyInitializing {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(MINTER_ROLE, _msgSender());
        _grantRole(BURN_ROLE, _msgSender());
    }

    /**
     * Allows the admin to specify when the token should become tradeable.
     * Once the token is tradeable, transferFrom can never be supervised again.
     * @param newListingTimestamp epoch time of when the token is listed on DEX
     */
    function setListingTimestamp(uint32 newListingTimestamp)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (listingTimestamp > 0 && block.timestamp >= listingTimestamp) {
            revert TokenAlreadyListed();
        }
        emit ListingTimestampUpdated(newListingTimestamp);
        listingTimestamp = newListingTimestamp;
    }
}
