// SPDX-License-Identifier: BSD-3-Clause-Clear

pragma solidity >=0.8.13 <0.8.20;

import "fhevm/abstracts/EIP712WithModifier.sol";

import "fhevm/lib/TFHE.sol";

import "./EncryptedERC20.sol";

contract BlindAuction is EIP712WithModifier {
    uint public endTime;

    address public beneficiary;

    // Current highest bid.
    euint32 internal highestBid;

    // Current second highest bid.
    euint32 internal secondHighestBid;

    // struct of bid datas
    struct BidData {
        // Mapping from bidder to their bid value.
        mapping(address => euint32) bids;
        // Number of bid
        uint bidCounter;
        // Array of bidders addresses
        address[] bidders;
    }

    BidData public bidData;

    // The token contract used for encrypted bids.
    EncryptedERC20 public tokenContract;

    // Auction Type
    enum AuctionTypes {
        firstPrice,
        secondPrice
    }
    AuctionTypes public auctionType;

    // Whether the auction object has been claimed.
    bool public objectClaimed;

    // If the token has been transferred to the beneficiary
    bool public tokenTransferred;

    bool public stoppable;

    bool public manuallyStopped = false;

    // The owner of the contract.
    address public contractOwner;

    // The function has been called too early.
    // Try again at `time`.
    error TooEarly(uint time);
    // The function has been called too late.
    // It cannot be called after `time`.
    error TooLate(uint time);

    event AuctionWinner(address who);

    event AuctionStopped();

    constructor(
        address _beneficiary,
        EncryptedERC20 _tokenContract,
        uint biddingTime,
        uint _auctionType,
        bool isStoppable
    ) EIP712WithModifier("Authorization token", "1") {
        beneficiary = _beneficiary;
        tokenContract = _tokenContract;
        endTime = block.timestamp + biddingTime;
        auctionType = AuctionTypes(_auctionType);
        objectClaimed = false;
        tokenTransferred = false;
        bidData.bidCounter = 0;
        stoppable = isStoppable;
        contractOwner = msg.sender;
    }

    // Bid an `encryptedValue`.
    function bid(bytes calldata encryptedValue) public onlyBeforeEnd {
        euint32 value = TFHE.asEuint32(encryptedValue);
        euint32 existingBid = bidData.bids[msg.sender];
        if (TFHE.isInitialized(existingBid)) {
            ebool isHigher = TFHE.lt(existingBid, value);
            // Update bid with value
            bidData.bids[msg.sender] = TFHE.cmux(isHigher, value, existingBid);
            // Transfer only the difference between existing and value
            euint32 toTransfer = TFHE.sub(value, existingBid);
            // Transfer only if bid is higher
            euint32 amount = TFHE.mul(TFHE.asEuint8(isHigher), toTransfer);
            tokenContract.transferFrom(msg.sender, address(this), amount);
        } else {
            bidData.bidCounter++;
            bidData.bids[msg.sender] = value;
            bidData.bidders.push(msg.sender);
            tokenContract.transferFrom(msg.sender, address(this), value);
        }
        euint32 currentBid = bidData.bids[msg.sender];
        if (!TFHE.isInitialized(highestBid)) {
            highestBid = currentBid;
        } else {
            highestBid = TFHE.cmux(TFHE.lt(highestBid, currentBid), currentBid, highestBid);
        }

        if (auctionType == AuctionTypes.secondPrice) {
            if (!TFHE.isInitialized(secondHighestBid)) {
                secondHighestBid = currentBid;
            } else {
                euint8 isHigherThanSecondHighest = TFHE.asEuint8(TFHE.lt(secondHighestBid, currentBid));
                euint8 isLowerThanHighest = TFHE.asEuint8(TFHE.gt(highestBid, currentBid));
                ebool updateSecondHighest = TFHE.asEbool(TFHE.and(isHigherThanSecondHighest, isLowerThanHighest));
                secondHighestBid = TFHE.cmux(updateSecondHighest, currentBid, secondHighestBid);
            }
        }
    }

    function getBid(
        bytes32 publicKey,
        bytes calldata signature
    ) public view onlySignedPublicKey(publicKey, signature) returns (bytes memory) {
        return TFHE.reencrypt(bidData.bids[msg.sender], publicKey, 0);
    }

    // Stop the auction
    function stop() public onlyContractOwner {
        require(stoppable && !tokenTransferred && !objectClaimed);
        manuallyStopped = true;
        emit AuctionStopped();
    }

    // Refund the user bids if the auction is stopped
    function refund() public onlyContractOwner {
        require(manuallyStopped);

        for (uint i = 0; i < bidData.bidCounter; i++) {
            address bidder = bidData.bidders[i];
            euint32 bidValue = bidData.bids[bidder];
            bidData.bids[bidder] = TFHE.NIL32;
            tokenContract.transfer(bidder, bidValue);
        }
    }

    // Returns an encrypted value of 0 or 1 under the caller's public key, indicating
    // if the caller has the highest bid.
    function doIHaveHighestBid(
        bytes32 publicKey,
        bytes calldata signature
    ) public view onlyAfterEnd onlySignedPublicKey(publicKey, signature) returns (bytes memory) {
        if (TFHE.isInitialized(highestBid) && TFHE.isInitialized(bidData.bids[msg.sender])) {
            return TFHE.reencrypt(TFHE.le(highestBid, bidData.bids[msg.sender]), publicKey);
        } else {
            return TFHE.reencrypt(TFHE.asEuint32(0), publicKey);
        }
    }

    // Claim the object. Succeeds only if the caller has the highest bid.
    function claim() public virtual onlyAfterEnd {
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
    }

    // Transfer token to beneficiary
    function auctionEnd() public onlyAfterEnd {
        require(!tokenTransferred);

        tokenTransferred = true;
        if (auctionType == AuctionTypes.firstPrice) {
            tokenContract.transfer(beneficiary, highestBid);
        }

        if (auctionType == AuctionTypes.secondPrice) {
            tokenContract.transfer(beneficiary, secondHighestBid);
        }
    }

    // Withdraw a bid from the auction to the caller once the auction has stopped.
    function withdraw() public onlyAfterEnd {
        euint32 bidValue = bidData.bids[msg.sender];

        if (!objectClaimed) {
            TFHE.req(TFHE.lt(bidValue, highestBid));
        }

        bidData.bids[msg.sender] = TFHE.NIL32;
        tokenContract.transfer(msg.sender, bidValue);
    }

    modifier onlyBeforeEnd() {
        if (block.timestamp >= endTime || manuallyStopped == true) revert TooLate(endTime);
        _;
    }

    modifier onlyAfterEnd() {
        if (block.timestamp <= endTime && manuallyStopped == false) revert TooEarly(endTime);
        _;
    }

    modifier onlyContractOwner() {
        require(msg.sender == contractOwner);
        _;
    }
}
