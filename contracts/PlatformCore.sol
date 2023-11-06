// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity >=0.8.13 <0.8.20;

import "./EncryptedERC20.sol";
import "./Adam721Like.sol";
import "./BlindAuction.sol";
import "./ERC721BlindAuction.sol";

contract PlatformCore {
    // The token contract used for encrypted bids.
    EncryptedERC20 public encryptedERC20Contract;

    // The ERC721 contract used for NFT.
    Adam721Like public ERC721Contract;

    // Mapping from seller to their auctions
    mapping(address => BlindAuction[]) public auctionsList;

    error InvalidAuctionType();

    constructor(EncryptedERC20 _encryptedERC20Contract, Adam721Like _ERC721Contract) {
        encryptedERC20Contract = _encryptedERC20Contract;
        ERC721Contract = _ERC721Contract;
    }

    function registerAuction(
        uint256 tokenId,
        string memory auctionType,
        uint256 biddingTime,
        bool isStoppable
    ) public returns (BlindAuction auction) {
        // Encode auction type. "first-price" -> 0 and "second-price" -> 1
        uint _auctionType;
        bytes32 auctionTypeHashed = keccak256(abi.encodePacked(auctionType));
        if (auctionTypeHashed == keccak256(abi.encodePacked("first-price"))) {
            _auctionType = 0;
        } else if (auctionTypeHashed == keccak256(abi.encodePacked("second-price"))) {
            _auctionType = 1;
        } else {
            revert InvalidAuctionType();
        }

        auction = new ERC721BlindAuction(
            msg.sender,
            encryptedERC20Contract,
            biddingTime,
            _auctionType,
            isStoppable,
            ERC721Contract,
            tokenId
        );

        auctionsList[msg.sender].push(auction);
    }

    // return the number of auctions
    function getAuctionNum(address seller) public view returns (uint) {
        return auctionsList[seller].length;
    }
}
