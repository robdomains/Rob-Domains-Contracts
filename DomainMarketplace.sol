// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/*

██████╗  ██████╗ ██████╗     ██████╗  ██████╗ ███╗   ███╗ █████╗ ██╗███╗   ██╗███████╗
██╔══██╗██╔═══██╗██╔══██╗    ██╔══██╗██╔═══██╗████╗ ████║██╔══██╗██║████╗  ██║██╔════╝
██████╔╝██║   ██║██████╔╝    ██║  ██║██║   ██║██╔████╔██║███████║██║██╔██╗ ██║███████╗
██╔══██╗██║   ██║██╔══██╗    ██║  ██║██║   ██║██║╚██╔╝██║██╔══██║██║██║╚██╗██║╚════██║
██║  ██║╚██████╔╝██████╔╝    ██████╔╝╚██████╔╝██║ ╚═╝ ██║██║  ██║██║██║ ╚████║███████║
╚═╝  ╚═╝ ╚═════╝ ╚═════╝     ╚═════╝  ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝╚══════╝

──────────────────────────────────────────────────────────────────────────────────────

Rob Domains Protocol
https://robdn.com

Official smart contracts powering the Rob Domains ecosystem.

──────────────────────────────────────────────────────────────────────────────────────

*/

interface IDomainNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function getNameByTokenId(uint256 tokenId) external view returns (string memory);
}

/**
 * @title DomainMarketplace
 * @notice Marketplace for Rob DomainNFT.
 *
 * Security upgrades in this v2:
 *  - Inline ReentrancyGuard on all ETH/NFT-touching functions.
 *  - Pull-payment refund pattern: offer cancellations queue funds in
 *    `pendingRefunds` instead of pushing ETH mid-loop (eliminates gas-bomb
 *    attacks and reentrancy in _cancelAllOffers).
 *  - Permanent offer-slot reuse (Gas Bomb fix): _activeOfferIndexPlusOne
 *    permanently records each buyer's slot index for a token and is never
 *    cleared. makeOffer always rewrites the same struct; offers[tokenId].length
 *    is permanently bounded by unique-buyer count. The active flag inside the
 *    Offer struct tracks liveness; the slot index lives forever in the mapping.
 *  - Per-maker offer index: _makerOffers[maker] stores the list of
 *    (tokenId, offerIndex) pairs for every unique token the maker has ever
 *    offered on. getOffersByMaker is O(unique tokens offered by the maker)
 *    with no marketplace-wide loop — replacing the previous O(tokens × offers)
 *    double loop that would hit RPC gas limits at scale.
 *  - Offer expiration: each offer stores a deadline; expired offers cannot be
 *    accepted but remain withdrawable by the maker.
 *  - O(1) circular-buffer for recent sales (replaces O(n) array shift).
 *  - Checks-Effects-Interactions ordering enforced throughout.
 *  - Failed refunds in `rejectOffer` fall back to `pendingRefunds` so ETH
 *    is never permanently lost.
 */
contract DomainMarketplace {

    // ─────────────────────────────────────────────
    //  Inline ReentrancyGuard
    // ─────────────────────────────────────────────
    uint256 private _reentrancyStatus;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    modifier nonReentrant() {
        require(_reentrancyStatus != _ENTERED, "Marketplace: reentrant call");
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ─────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────
    address public admin;
    address public feeRecipient;
    IDomainNFT public domainNFT;

    uint256 public constant FEE_BPS = 200; // 2% (200 / 10000)

    struct Listing {
        address seller;
        uint256 price;
        bool    active;
    }

    struct Offer {
        address buyer;
        uint256 amount;
        bool    active;
        uint256 expiration; // unix timestamp; 0 = never expires
    }

    struct SaleRecord {
        uint256 tokenId;
        address seller;
        address buyer;
        uint256 price;
        uint256 timestamp;
    }

    // ── Per-maker offer index ─────────────────────────────────────────────────
    // Records every (tokenId, permanent offerIndex) pair for a maker.
    // Populated once when a buyer makes their first offer on a given token;
    // never modified or removed afterwards. Liveness is tracked by
    // offers[tokenId][offerIndex].active, not by this array.
    //
    // This replaces the previous _tokenIdsWithOffers / _hasOffers approach,
    // making getOffersByMaker O(unique tokens offered by the maker) instead of
    // O(all tokens with offers × all offers per token).
    struct MakerOffer {
        uint256 tokenId;
        uint256 offerIndex; // permanent slot in offers[tokenId]
    }
    mapping(address => MakerOffer[]) private _makerOffers;

    // tokenId → Listing
    mapping(uint256 => Listing) public listings;

    // tokenId → array of Offer
    mapping(uint256 => Offer[]) public offers;

    // Pull-payment: ETH pending withdrawal per address
    mapping(address => uint256) public pendingRefunds;

    // Active listing enumeration
    uint256[] private _activeListingIds;
    mapping(uint256 => uint256) private _listingIndex; // tokenId → index

    // Permanent offer-slot registry: buyer → offerIndex + 1.
    // Set once on the buyer's first offer for a token; NEVER cleared afterwards.
    // Value is offerIndex + 1; 0 means this buyer has never offered on this token.
    //
    // Permanence is the key gas-bomb defence: repeated makeOffer → withdraw →
    // makeOffer cycles always reuse the same Offer struct, so offers[tokenId].length
    // is permanently capped to the number of *unique* buyers for that token.
    // Whether an offer is currently live is tracked by offers[tokenId][idx].active.
    mapping(uint256 => mapping(address => uint256)) private _activeOfferIndexPlusOne;

    // Recent sales – O(1) circular buffer capped at 100 entries.
    uint256 private constant MAX_RECENT_SALES = 100;
    SaleRecord[100] private _recentSales;
    uint256 private _recentSalesHead;  // index of oldest entry
    uint256 private _recentSalesCount; // entries filled (0–100)

    // ─────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────
    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event ListingCancelled(uint256 indexed tokenId, address indexed seller);
    event Sold(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 price);
    event OfferMade(uint256 indexed tokenId, address indexed buyer, uint256 amount, uint256 offerIndex, uint256 expiration);
    event OfferAccepted(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 amount);
    event OfferRejected(uint256 indexed tokenId, uint256 offerIndex);
    event OfferWithdrawn(uint256 indexed tokenId, uint256 offerIndex);
    event RefundPending(address indexed recipient, uint256 amount);
    event RefundClaimed(address indexed recipient, uint256 amount);
    event FeeRecipientUpdated(address newFeeRecipient);

    // ─────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────
    constructor(address _domainNFT, address _feeRecipient) {
        require(_domainNFT    != address(0), "Marketplace: zero NFT address");
        require(_feeRecipient != address(0), "Marketplace: zero fee recipient");
        admin              = msg.sender;
        domainNFT          = IDomainNFT(_domainNFT);
        feeRecipient       = _feeRecipient;
        _reentrancyStatus  = _NOT_ENTERED;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Marketplace: not admin");
        _;
    }

    // ─────────────────────────────────────────────
    //  Listings
    // ─────────────────────────────────────────────

    /**
     * @notice List a domain for sale.
     * @dev Caller must have granted isApprovedForAll (preferred) or
     *      per-token approval to this contract first.
     */
    function listForSale(uint256 tokenId, uint256 price) external {
        require(price > 0, "Marketplace: price must be > 0");
        require(domainNFT.ownerOf(tokenId) == msg.sender, "Marketplace: not owner");
        require(
            domainNFT.getApproved(tokenId) == address(this) ||
            domainNFT.isApprovedForAll(msg.sender, address(this)),
            "Marketplace: not approved"
        );
        require(!listings[tokenId].active, "Marketplace: already listed");

        listings[tokenId] = Listing({ seller: msg.sender, price: price, active: true });

        _listingIndex[tokenId] = _activeListingIds.length;
        _activeListingIds.push(tokenId);

        emit Listed(tokenId, msg.sender, price);
    }

    /**
     * @notice Cancel an active listing.
     */
    function cancelListing(uint256 tokenId) external {
        Listing storage l = listings[tokenId];
        require(l.active, "Marketplace: not listed");
        require(l.seller == msg.sender || msg.sender == admin, "Marketplace: not seller");

        l.active = false;
        _removeFromActiveListings(tokenId);

        emit ListingCancelled(tokenId, l.seller);
    }

    /**
     * @notice Buy a listed domain at the asking price.
     * @dev Remaining offers are moved to pendingRefunds (pull pattern).
     *      Follows Checks → Effects → Interactions.
     */
    function buyDomain(uint256 tokenId) external payable nonReentrant {
        Listing storage l = listings[tokenId];
        require(l.active, "Marketplace: not listed");
        require(msg.value >= l.price, "Marketplace: insufficient payment");
        require(msg.sender != l.seller, "Marketplace: seller cannot buy");

        address seller = l.seller;
        uint256 price  = l.price;

        // Effects
        l.active = false;
        _removeFromActiveListings(tokenId);
        _queueRefundsForAllOffers(tokenId); // no ETH push – queue only

        // Interactions
        domainNFT.safeTransferFrom(seller, msg.sender, tokenId);

        uint256 fee    = (price * FEE_BPS) / 10000;
        uint256 payout = price - fee;

        (bool feeSent, ) = feeRecipient.call{value: fee}("");
        require(feeSent, "Marketplace: fee transfer failed");

        (bool payoutSent, ) = seller.call{value: payout}("");
        require(payoutSent, "Marketplace: payout failed");

        if (msg.value > price) {
            (bool refundSent, ) = msg.sender.call{value: msg.value - price}("");
            require(refundSent, "Marketplace: overpay refund failed");
        }

        _recordSale(tokenId, seller, msg.sender, price);
        emit Sold(tokenId, seller, msg.sender, price);
    }

    // ─────────────────────────────────────────────
    //  Offers
    // ─────────────────────────────────────────────

    /**
     * @notice Make an offer on any domain (listed or not).
     * @param tokenId  Domain token ID.
     * @param duration Seconds until the offer expires. 0 = never expires.
     *
     * @dev If the caller already has an active offer on this token the
     *      existing offer is updated in place: the old ETH amount is queued
     *      to pendingRefunds and the new msg.value replaces it. This keeps
     *      the active-offer count bounded by unique buyers, preventing
     *      unbounded-loop gas bombs.
     *
     *      On the first offer from a buyer for a given token, a MakerOffer
     *      entry is pushed to _makerOffers[buyer] so getOffersByMaker can
     *      enumerate this buyer's offers in O(unique tokens offered) without
     *      any marketplace-wide scan.
     */
    function makeOffer(uint256 tokenId, uint256 duration)
        external
        payable
        nonReentrant
        returns (uint256 offerIndex)
    {
        require(msg.value > 0, "Marketplace: offer must be > 0");
        domainNFT.ownerOf(tokenId); // reverts if token nonexistent

        uint256 expiration = duration > 0 ? block.timestamp + duration : 0;

        uint256 existingIndexPlusOne = _activeOfferIndexPlusOne[tokenId][msg.sender];

        if (existingIndexPlusOne != 0) {
            // ── Reuse the permanent slot ────────────────────────────────────
            offerIndex = existingIndexPlusOne - 1;
            Offer storage existing = offers[tokenId][offerIndex];

            if (existing.active) {
                // Offer is currently active — queue the old ETH for refund.
                // Guard is essential: if the slot was previously withdrawn,
                // rejected, or cancelled by a sale, active is false and the
                // funds were already returned; queueing again would be a
                // double-refund.
                pendingRefunds[msg.sender] += existing.amount;
                emit RefundPending(msg.sender, existing.amount);
            }

            // Reactivate and update the existing slot in place.
            existing.amount     = msg.value;
            existing.expiration = expiration;
            existing.active     = true;
        } else {
            // ── New offer ───────────────────────────────────────────────────
            offerIndex = offers[tokenId].length;
            offers[tokenId].push(Offer({
                buyer:      msg.sender,
                amount:     msg.value,
                active:     true,
                expiration: expiration
            }));

            _activeOfferIndexPlusOne[tokenId][msg.sender] = offerIndex + 1;

            // Register this (tokenId, offerIndex) pair in the maker's personal
            // index. This is the only write needed — never updated or removed.
            _makerOffers[msg.sender].push(MakerOffer({
                tokenId:    tokenId,
                offerIndex: offerIndex
            }));
        }

        emit OfferMade(tokenId, msg.sender, msg.value, offerIndex, expiration);
    }

    /**
     * @notice Accept an active, non-expired offer.
     * @dev Remaining offers are moved to pendingRefunds (pull pattern).
     */
    function acceptOffer(uint256 tokenId, uint256 offerIndex) external nonReentrant {
        require(domainNFT.ownerOf(tokenId) == msg.sender, "Marketplace: not owner");
        require(
            domainNFT.getApproved(tokenId) == address(this) ||
            domainNFT.isApprovedForAll(msg.sender, address(this)),
            "Marketplace: not approved"
        );

        Offer storage o = offers[tokenId][offerIndex];
        require(o.active, "Marketplace: offer not active");
        require(
            o.expiration == 0 || block.timestamp <= o.expiration,
            "Marketplace: offer expired"
        );

        address buyer  = o.buyer;
        uint256 amount = o.amount;

        // Effects — mark inactive; permanent slot in _activeOfferIndexPlusOne is preserved
        o.active = false;

        if (listings[tokenId].active) {
            listings[tokenId].active = false;
            _removeFromActiveListings(tokenId);
        }

        _queueRefundsForAllOffersExcept(tokenId, offerIndex);

        // Interactions
        domainNFT.safeTransferFrom(msg.sender, buyer, tokenId);

        uint256 fee    = (amount * FEE_BPS) / 10000;
        uint256 payout = amount - fee;

        (bool feeSent, ) = feeRecipient.call{value: fee}("");
        require(feeSent, "Marketplace: fee failed");

        (bool payoutSent, ) = msg.sender.call{value: payout}("");
        require(payoutSent, "Marketplace: payout failed");

        _recordSale(tokenId, msg.sender, buyer, amount);
        emit OfferAccepted(tokenId, msg.sender, buyer, amount);
    }

    /**
     * @notice Reject an offer. Attempts immediate refund; falls back to
     *         pendingRefunds so ETH is never permanently lost.
     */
    function rejectOffer(uint256 tokenId, uint256 offerIndex) external nonReentrant {
        require(domainNFT.ownerOf(tokenId) == msg.sender, "Marketplace: not owner");
        Offer storage o = offers[tokenId][offerIndex];
        require(o.active, "Marketplace: offer not active");

        address buyer  = o.buyer;
        uint256 amount = o.amount;

        // Effects — permanent slot preserved; only active flag cleared
        o.active = false;

        // Interaction: push first; fall back to pull on failure
        (bool sent, ) = buyer.call{value: amount}("");
        if (!sent) {
            pendingRefunds[buyer] += amount;
            emit RefundPending(buyer, amount);
        }

        emit OfferRejected(tokenId, offerIndex);
    }

    /**
     * @notice Withdraw an offer you made (works whether active or expired,
     *         and regardless of whether the domain is currently listed).
     */
    function withdrawOffer(uint256 tokenId, uint256 offerIndex) external nonReentrant {
        Offer storage o = offers[tokenId][offerIndex];
        require(o.active, "Marketplace: offer not active");
        require(o.buyer == msg.sender, "Marketplace: not offer maker");

        uint256 amount = o.amount;

        // Effects — permanent slot preserved; only active flag cleared
        o.active = false;

        // Interaction
        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Marketplace: refund failed");

        emit OfferWithdrawn(tokenId, offerIndex);
    }

    /**
     * @notice Claim any ETH pending for msg.sender (from cancelled offers).
     * @dev This is the recovery path when a direct push refund failed, or
     *      when an offer was replaced in place via a second makeOffer call.
     */
    function claimRefund() external nonReentrant {
        uint256 amount = pendingRefunds[msg.sender];
        require(amount > 0, "Marketplace: no pending refund");

        // Effects
        pendingRefunds[msg.sender] = 0;

        // Interaction
        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Marketplace: claim failed");

        emit RefundClaimed(msg.sender, amount);
    }

    // ─────────────────────────────────────────────
    //  View functions
    // ─────────────────────────────────────────────

    struct ListingView {
        uint256 tokenId;
        string  domainName;
        address seller;
        uint256 price;
    }

    function getActiveListings() external view returns (ListingView[] memory) {
        uint256 count = _activeListingIds.length;
        ListingView[] memory result = new ListingView[](count);
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = _activeListingIds[i];
            Listing storage l = listings[tokenId];
            result[i] = ListingView({
                tokenId:    tokenId,
                domainName: domainNFT.getNameByTokenId(tokenId),
                seller:     l.seller,
                price:      l.price
            });
        }
        return result;
    }

    function getListingsByOwner(address owner) external view returns (ListingView[] memory) {
        uint256 total = _activeListingIds.length;
        uint256 count = 0;
        for (uint256 i = 0; i < total; i++) {
            if (listings[_activeListingIds[i]].seller == owner) count++;
        }
        ListingView[] memory result = new ListingView[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < total; i++) {
            uint256 tokenId = _activeListingIds[i];
            if (listings[tokenId].seller == owner) {
                result[idx++] = ListingView({
                    tokenId:    tokenId,
                    domainName: domainNFT.getNameByTokenId(tokenId),
                    seller:     listings[tokenId].seller,
                    price:      listings[tokenId].price
                });
            }
        }
        return result;
    }

    struct OfferView {
        uint256 tokenId;
        string  domainName;
        uint256 offerIndex;
        address buyer;
        uint256 amount;
        uint256 expiration; // 0 = never expires
    }

    /**
     * @notice Returns all active offers made by `maker`.
     * @dev Iterates only _makerOffers[maker] — the maker's personal index of
     *      (tokenId, offerIndex) pairs recorded at offer creation time.
     *      Complexity: O(number of unique tokens the maker has ever offered on).
     *      No marketplace-wide loop, no nested scan over all tokens or all offers.
     *      Results are independent of current listing state because the maker
     *      index is populated regardless of whether a token is listed.
     */
    function getOffersByMaker(address maker) external view returns (OfferView[] memory) {
        MakerOffer[] storage makerList = _makerOffers[maker];
        uint256 total = makerList.length;
        uint256 count = 0;

        for (uint256 i = 0; i < total; i++) {
            if (offers[makerList[i].tokenId][makerList[i].offerIndex].active) {
                count++;
            }
        }

        OfferView[] memory result = new OfferView[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < total; i++) {
            uint256 tokenId    = makerList[i].tokenId;
            uint256 offerIndex = makerList[i].offerIndex;
            Offer storage o    = offers[tokenId][offerIndex];
            if (o.active) {
                result[idx++] = OfferView({
                    tokenId:    tokenId,
                    domainName: domainNFT.getNameByTokenId(tokenId),
                    offerIndex: offerIndex,
                    buyer:      o.buyer,
                    amount:     o.amount,
                    expiration: o.expiration
                });
            }
        }
        return result;
    }

    struct OfferDetail {
        address buyer;
        uint256 amount;
        bool    active;
        uint256 expiration;
    }

    function getOffersForToken(uint256 tokenId) external view returns (OfferDetail[] memory) {
        Offer[] storage os = offers[tokenId];
        OfferDetail[] memory result = new OfferDetail[](os.length);
        for (uint256 i = 0; i < os.length; i++) {
            result[i] = OfferDetail({
                buyer:      os[i].buyer,
                amount:     os[i].amount,
                active:     os[i].active,
                expiration: os[i].expiration
            });
        }
        return result;
    }

    function getRecentSales() external view returns (SaleRecord[] memory) {
        SaleRecord[] memory result = new SaleRecord[](_recentSalesCount);
        for (uint256 i = 0; i < _recentSalesCount; i++) {
            result[i] = _recentSales[(_recentSalesHead + i) % MAX_RECENT_SALES];
        }
        return result;
    }

    function getListing(uint256 tokenId) external view returns (Listing memory) {
        return listings[tokenId];
    }

    // ─────────────────────────────────────────────
    //  Admin
    // ─────────────────────────────────────────────

    function updateFeeRecipient(address newFeeRecipient) external onlyAdmin {
        require(newFeeRecipient != address(0), "Marketplace: zero address");
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(newFeeRecipient);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Marketplace: zero address");
        admin = newAdmin;
    }

    // ─────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────

    function _removeFromActiveListings(uint256 tokenId) internal {
        uint256 lastIndex  = _activeListingIds.length - 1;
        uint256 tokenIndex = _listingIndex[tokenId];

        if (tokenIndex != lastIndex) {
            uint256 lastTokenId = _activeListingIds[lastIndex];
            _activeListingIds[tokenIndex] = lastTokenId;
            _listingIndex[lastTokenId]    = tokenIndex;
        }
        _activeListingIds.pop();
        delete _listingIndex[tokenId];
    }

    /**
     * @dev Mark all active offers on a token as inactive and queue their ETH
     *      as pending refunds. Permanent slots in _activeOfferIndexPlusOne are
     *      intentionally preserved so future makeOffer calls reuse the same
     *      storage slot rather than appending new ones.
     *      No ETH is transferred here — safe in loops.
     */
    function _queueRefundsForAllOffers(uint256 tokenId) internal {
        Offer[] storage os = offers[tokenId];
        for (uint256 i = 0; i < os.length; i++) {
            if (os[i].active) {
                os[i].active = false;
                pendingRefunds[os[i].buyer] += os[i].amount;
                emit RefundPending(os[i].buyer, os[i].amount);
            }
        }
    }

    /**
     * @dev Like _queueRefundsForAllOffers but skips one index (the accepted offer).
     *      Permanent slots in _activeOfferIndexPlusOne are preserved.
     */
    function _queueRefundsForAllOffersExcept(uint256 tokenId, uint256 skipIndex) internal {
        Offer[] storage os = offers[tokenId];
        for (uint256 i = 0; i < os.length; i++) {
            if (i != skipIndex && os[i].active) {
                os[i].active = false;
                pendingRefunds[os[i].buyer] += os[i].amount;
                emit RefundPending(os[i].buyer, os[i].amount);
            }
        }
    }

    /**
     * @dev O(1) circular-buffer insert for recent sales.
     *      Overwrites the oldest entry once the buffer is full.
     */
    function _recordSale(uint256 tokenId, address seller, address buyer, uint256 price) internal {
        uint256 insertIndex;
        if (_recentSalesCount < MAX_RECENT_SALES) {
            insertIndex = (_recentSalesHead + _recentSalesCount) % MAX_RECENT_SALES;
            _recentSalesCount++;
        } else {
            // Buffer full: overwrite oldest, advance head
            insertIndex      = _recentSalesHead;
            _recentSalesHead = (_recentSalesHead + 1) % MAX_RECENT_SALES;
        }
        _recentSales[insertIndex] = SaleRecord({
            tokenId:   tokenId,
            seller:    seller,
            buyer:     buyer,
            price:     price,
            timestamp: block.timestamp
        });
    }
}
