// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract MockMarketplace {
    using Address for address payable;

    struct Listing {
        address seller;
        uint256 price;
    }

    mapping(address => mapping(uint256 => Listing)) public listings;

    event Listed(
        address indexed nftAddress,
        uint256 indexed tokenId,
        address seller,
        uint256 price
    );
    event Bought(
        address indexed nftAddress,
        uint256 indexed tokenId,
        address buyer,
        uint256 price,
        address royaltyReceiver,
        uint256 royaltyAmount
    );
    event Cancelled(
        address indexed nftAddress,
        uint256 indexed tokenId,
        address seller
    );

    function listNFT(
        address nftAddress,
        uint256 tokenId,
        uint256 price
    ) external {
        require(price > 0, "Invalid price");

        IERC721 nft = IERC721(nftAddress);
        require(nft.ownerOf(tokenId) == msg.sender, "Not owner");
        require(
            nft.getApproved(tokenId) == address(this) ||
                nft.isApprovedForAll(msg.sender, address(this)),
            "Marketplace not approved"
        );

        listings[nftAddress][tokenId] = Listing({
            seller: msg.sender,
            price: price
        });

        emit Listed(nftAddress, tokenId, msg.sender, price);
    }

    function cancelListing(address nftAddress, uint256 tokenId) external {
        Listing memory listing = listings[nftAddress][tokenId];
        require(listing.seller == msg.sender, "Not the seller");

        delete listings[nftAddress][tokenId];
        emit Cancelled(nftAddress, tokenId, msg.sender);
    }

    function buyNFT(address nftAddress, uint256 tokenId) external payable {
        require(
            msg.sender != IERC721(nftAddress).ownerOf(tokenId),
            "Cannot buy own NFT"
        );
        Listing memory listing = listings[nftAddress][tokenId];
        require(listing.price > 0, "Not listed");
        require(msg.value >= listing.price, "Insufficient payment");

        uint256 royaltyAmount;
        address royaltyReceiver;

        if (IERC165(nftAddress).supportsInterface(type(IERC2981).interfaceId)) {
            (royaltyReceiver, royaltyAmount) = IERC2981(nftAddress).royaltyInfo(
                tokenId,
                listing.price
            );
            if (royaltyAmount > 0 && royaltyReceiver != address(0)) {
                payable(royaltyReceiver).sendValue(royaltyAmount);
            }
        }

        uint256 sellerAmount = listing.price - royaltyAmount;
        payable(listing.seller).sendValue(sellerAmount);

        // Transfer NFT
        IERC721(nftAddress).safeTransferFrom(
            listing.seller,
            msg.sender,
            tokenId
        );

        delete listings[nftAddress][tokenId];

        emit Bought(
            nftAddress,
            tokenId,
            msg.sender,
            listing.price,
            royaltyReceiver,
            royaltyAmount
        );
    }

    function getListing(
        address nftAddress,
        uint256 tokenId
    ) external view returns (address seller, uint256 price) {
        Listing memory listing = listings[nftAddress][tokenId];
        return (listing.seller, listing.price);
    }

    receive() external payable {}
}
