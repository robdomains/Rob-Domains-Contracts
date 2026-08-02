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

/**
 * @title ProfileBadgeRegistry
 * @notice Stores NFT profile badges per wallet address.
 *         Badges are linked to the WALLET address, not to any domain name.
 *         All domains owned by the same wallet will display the same badges.
 *
 * Rules:
 *  - Maximum 10 badges per wallet.
 *  - On addBadge(), ownership is validated via ownerOf(tokenId).
 *  - Display-time validation must also call ownerOf(); if the NFT has been
 *    transferred away, the front-end must hide the badge automatically.
 *  - No database. No signatures. Pure on-chain storage.
 */

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
}

contract ProfileBadgeRegistry {
    // ─────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────

    uint256 public constant MAX_BADGES = 10;

    // ─────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────

    struct Badge {
        address nftContract;
        uint256 tokenId;
    }

    // ─────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────

    /// @dev wallet address → array of badge entries
    mapping(address => Badge[]) private _badges;

    // ─────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────

    event BadgeAdded(
        address indexed wallet,
        address indexed nftContract,
        uint256 indexed tokenId
    );

    event BadgeRemoved(
        address indexed wallet,
        address indexed nftContract,
        uint256 indexed tokenId
    );

    // ─────────────────────────────────────────────
    //  Write functions
    // ─────────────────────────────────────────────

    /**
     * @notice Add an NFT as a profile badge.
     *         Reverts if caller does not currently own the NFT,
     *         if the badge is already present, or if the 10-badge limit is reached.
     */
    function addBadge(address nftContract, uint256 tokenId) external {
        require(nftContract != address(0), "Invalid NFT contract");
        require(_badges[msg.sender].length < MAX_BADGES, "Max badges reached");

        // Ownership check — must be current owner
        address owner = IERC721(nftContract).ownerOf(tokenId);
        require(owner == msg.sender, "Not the NFT owner");

        // Duplicate check
        Badge[] storage badges = _badges[msg.sender];
        for (uint256 i = 0; i < badges.length; i++) {
            require(
                !(badges[i].nftContract == nftContract && badges[i].tokenId == tokenId),
                "Badge already added"
            );
        }

        badges.push(Badge({ nftContract: nftContract, tokenId: tokenId }));
        emit BadgeAdded(msg.sender, nftContract, tokenId);
    }

    /**
     * @notice Remove an existing badge.
     *         Uses swap-and-pop to keep storage compact.
     *         Reverts if the badge is not found.
     */
    function removeBadge(address nftContract, uint256 tokenId) external {
        Badge[] storage badges = _badges[msg.sender];
        uint256 len = badges.length;

        for (uint256 i = 0; i < len; i++) {
            if (badges[i].nftContract == nftContract && badges[i].tokenId == tokenId) {
                // Swap with last element and pop
                if (i != len - 1) {
                    badges[i] = badges[len - 1];
                }
                badges.pop();
                emit BadgeRemoved(msg.sender, nftContract, tokenId);
                return;
            }
        }

        revert("Badge not found");
    }

    // ─────────────────────────────────────────────
    //  Read functions
    // ─────────────────────────────────────────────

    /**
     * @notice Returns all stored badge entries for a wallet.
     *         NOTE: The caller / front-end must still verify current ownership
     *         by calling ownerOf() for each badge before displaying it.
     */
    function getBadges(address wallet)
        external
        view
        returns (address[] memory nftContracts, uint256[] memory tokenIds)
    {
        Badge[] storage badges = _badges[wallet];
        uint256 len = badges.length;

        nftContracts = new address[](len);
        tokenIds     = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            nftContracts[i] = badges[i].nftContract;
            tokenIds[i]     = badges[i].tokenId;
        }
    }

    /**
     * @notice Returns the number of badges stored for a wallet.
     */
    function getBadgeCount(address wallet) external view returns (uint256) {
        return _badges[wallet].length;
    }
}
