// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "./RobCollection.sol";

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
 * @title CollectionFactory
 * @notice Deploys fully on-chain RobCollection (ERC721) contracts for .rob domain holders.
 *
 * All collection metadata is passed directly to the RobCollection constructor and stored
 * on-chain. No IPFS. No Pinata. No metadataUri. One transaction deploys a complete,
 * OpenSea-compatible collection.
 *
 * Domain ownership is verified on every createCollection call.
 * Collection IDs are sequential integers starting at 1.
 *
 * Deploy constructor args:
 *   _domainNFT — address of the deployed DomainNFT contract
 */

interface IDomainNFT {
    function balanceOf(address owner) external view returns (uint256);
}

contract CollectionFactory {
    // ─────────────────────────────────────────────────────────────────────────
    //  Storage
    // ─────────────────────────────────────────────────────────────────────────

    IDomainNFT public immutable domainNFT;

    uint256 private _collectionCount;

    struct CollectionInfo {
        uint256 id;
        address owner;
        address collection; // deployed ERC721 address
        uint256 createdAt;
    }

    mapping(uint256 => CollectionInfo) public collections;
    mapping(address => uint256[]) private _ownerCollections;

    // ─────────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────────

    event CollectionCreated(
        uint256 indexed id,
        address indexed owner,
        address indexed collection
    );

    // ─────────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _domainNFT) {
        require(_domainNFT != address(0), "CollectionFactory: zero domain address");
        domainNFT = IDomainNFT(_domainNFT);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Write
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Deploy a new fully on-chain ERC721 collection in a single transaction.
     *         All metadata is stored inside the RobCollection contract — no IPFS, no Pinata.
     *         Reverts if caller owns no .rob domain — cannot be bypassed via explorer.
     *
     * @param name          ERC721 name
     * @param symbol        ERC721 symbol (up to 8 chars recommended)
     * @param totalSupply   Maximum number of NFTs that can ever be minted
     * @param mintPrice     Price in wei per NFT
     * @param maxPerWallet  Maximum NFTs a single wallet may mint
     * @param startTime     Mint open time (unix seconds)
     * @param endTime       Mint close time (unix seconds)
     * @param description   Collection description (stored on-chain, shown by OpenSea)
     * @param imageUrl      Collection image URL (stored on-chain)
     * @param bannerUrl     Collection banner URL (stored on-chain)
     * @param website       Website URL (optional, stored on-chain)
     * @param twitter       Twitter URL (optional, stored on-chain)
     * @param discord       Discord URL (optional, stored on-chain)
     * @param telegram      Telegram URL (optional, stored on-chain)
     */
    function createCollection(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        uint256 mintPrice,
        uint256 maxPerWallet,
        uint256 startTime,
        uint256 endTime,
        string calldata description,
        string calldata imageUrl,
        string calldata bannerUrl,
        string calldata website,
        string calldata twitter,
        string calldata discord,
        string calldata telegram
    ) external returns (uint256 collectionId, address collectionAddress) {
        // ── Domain ownership check — enforced in the contract itself ──────────
        require(
            domainNFT.balanceOf(msg.sender) > 0,
            "CollectionFactory: must own a .rob domain"
        );

        require(bytes(name).length > 0, "CollectionFactory: empty name");
        require(bytes(symbol).length > 0, "CollectionFactory: empty symbol");
        require(totalSupply > 0, "CollectionFactory: zero supply");
        require(maxPerWallet > 0, "CollectionFactory: zero max per wallet");
        require(endTime > startTime, "CollectionFactory: end before start");

        // ── Assign sequential ID ──────────────────────────────────────────────
        _collectionCount++;
        collectionId = _collectionCount;

        // ── Deploy fully on-chain ERC721 contract ─────────────────────────────
        RobCollection collection = new RobCollection(
            name,
            symbol,
            totalSupply,
            mintPrice,
            maxPerWallet,
            startTime,
            endTime,
            msg.sender,
            description,
            imageUrl,
            bannerUrl,
            website,
            twitter,
            discord,
            telegram
        );
        collectionAddress = address(collection);

        // ── Store ─────────────────────────────────────────────────────────────
        collections[collectionId] = CollectionInfo({
            id: collectionId,
            owner: msg.sender,
            collection: collectionAddress,
            createdAt: block.timestamp
        });
        _ownerCollections[msg.sender].push(collectionId);

        emit CollectionCreated(collectionId, msg.sender, collectionAddress);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Read
    // ─────────────────────────────────────────────────────────────────────────

    function getCollection(uint256 id) external view returns (CollectionInfo memory) {
        return collections[id];
    }

    function getCollectionCount() external view returns (uint256) {
        return _collectionCount;
    }

    function getCollectionsByOwner(address owner) external view returns (uint256[] memory) {
        return _ownerCollections[owner];
    }

    function getAllCollections() external view returns (CollectionInfo[] memory) {
        CollectionInfo[] memory result = new CollectionInfo[](_collectionCount);
        for (uint256 i = 1; i <= _collectionCount; i++) {
            result[i - 1] = collections[i];
        }
        return result;
    }
}
