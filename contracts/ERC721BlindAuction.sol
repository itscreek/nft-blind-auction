// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity >=0.8.13 <0.8.20;

import "./BlindAuction.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract ERC721BlindAuction is BlindAuction {
    // The token contract of auction target
    IERC721 public ERC721Contract;
    // the token id of auction target
    uint256 public targetTokenId;

    constructor(
        address _beneficiary,
        EncryptedERC20 _tokenContract,
        uint256 biddingTime,
        uint _auctionType, // _auctionType must be 0 or 1. 0 is first price auction and 1 is second price auction.
        bool isStoppable,
        IERC721 _ERC721Contract,
        uint256 _targetTokenId
    ) BlindAuction(_beneficiary, _tokenContract, biddingTime, _auctionType, isStoppable) {
        ERC721Contract = _ERC721Contract;
        targetTokenId = _targetTokenId;
    }

    function claim() public onlyAfterEnd override(BlindAuction){
        require(!objectClaimed);
        TFHE.req(TFHE.le(highestBid, bidData.bids[msg.sender]));

        objectClaimed = true;
        if (auctionType == AuctionTypes.firstPrice) {
            bidData.bids[msg.sender] = TFHE.NIL32;
        }
        if (auctionType == AuctionTypes.secondPrice) {
            bidData.bids[msg.sender] = TFHE.sub(highestBid, secondHighestBid);
        }
        emit AuctionWinner(msg.sender);
        ERC721Contract.safeTransferFrom(beneficiary, msg.sender, targetTokenId);
    }
}
