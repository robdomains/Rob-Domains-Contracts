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

import "./interfaces/IDomainNFT.sol";
import "./interfaces/IResolver.sol";

/**
 * @title  RobResolver
 * @author Rob Domains
 * @notice Standalone resolver contract for the .rob domain name system.
 *
 *         Responsibilities
 *         ────────────────
 *         • Primary domain registration (wallet → preferred token)
 *         • Reverse resolution  (wallet  → domain name)
 *         • Forward resolution  (name    → wallet / token)
 *         • Future text / address / content-hash records (storage reserved)
 *
 *         Architecture
 *         ────────────
 *         This contract does NOT inherit from DomainNFT and makes no changes
 *         to any existing deployed contract.  All ownership checks are
 *         delegated to the live DomainNFT contract through the IDomainNFT
 *         interface.
 *
 *         Upgradeability
 *         ──────────────
 *         Storage layout is designed for forward compatibility.  Future
 *         features (text records, multi-coin addresses, CCIP-Read, ENS
 *         compatibility, wildcards, versioning) can be added WITHOUT
 *         reorganising the existing mappings.
 *
 *         Deployment
 *         ──────────
 *         Deploy this contract independently after the DomainNFT is live.
 *         Pass the DomainNFT contract address to the constructor.
 *         No admin key or proxy pattern is required for the initial release.
 */
contract RobResolver is IResolver {
    // ─── Immutable state ──────────────────────────────────────────────────────

    /// @notice Reference to the deployed DomainNFT contract.
    IDomainNFT public immutable domainNFT;

    // ─── Primary domain storage ───────────────────────────────────────────────

    /// @dev wallet → preferred tokenId  (0 = not set)
    mapping(address => uint256) private _primaryToken;

    // ─── Future record storage (reserved — NOT YET IMPLEMENTED) ──────────────
    // These mappings are declared now to anchor the storage layout.
    // Future versions of the contract will write into them.

    /// @dev tokenId → key → value  (text records, e.g. "avatar", "email")
    mapping(uint256 => mapping(string => string)) private _textRecords;

    /// @dev tokenId → SLIP-44 coinType → encoded address bytes
    mapping(uint256 => mapping(uint256 => bytes)) private _addressRecords;

    /// @dev tokenId → raw content hash (IPFS CID, ENS contenthash encoding)
    mapping(uint256 => bytes) private _contentHash;

    /// @dev tokenId → avatar IPFS hash
    mapping(uint256 => string) private _avatarHash;

    /// @dev reserved storage gap — 20 slots for future expansion
    uint256[20] private __gap;

    // ─── Constructor ──────────────────────────────────────────────────────────

    /**
     * @param _domainNFT Address of the already-deployed DomainNFT contract.
     */
    constructor(address _domainNFT) {
        require(_domainNFT != address(0), "RobResolver: zero address");
        domainNFT = IDomainNFT(_domainNFT);
    }

    // ─── Primary domain — write ───────────────────────────────────────────────

    /**
     * @inheritdoc IResolver
     * @dev Reverts with a descriptive message when the caller does not own the token.
     */
    function setPrimaryDomain(uint256 tokenId) external override {
        require(
            domainNFT.ownerOf(tokenId) == msg.sender,
            "RobResolver: caller does not own this token"
        );
        _primaryToken[msg.sender] = tokenId;
        emit PrimaryDomainChanged(msg.sender, tokenId);
    }

    /**
     * @inheritdoc IResolver
     */
    function clearPrimaryDomain() external override {
        delete _primaryToken[msg.sender];
        emit PrimaryDomainCleared(msg.sender);
    }

    // ─── Primary domain — read ────────────────────────────────────────────────

    /**
     * @inheritdoc IResolver
     */
    function getPrimaryToken(address wallet) external view override returns (uint256) {
        return _primaryToken[wallet];
    }

    /**
     * @inheritdoc IResolver
     * @dev Returns an empty string if no primary is set or ownership has changed.
     */
    function getPrimaryDomain(address wallet) external view override returns (string memory) {
        uint256 tokenId = _primaryToken[wallet];
        if (tokenId == 0) return "";
        // Verify current ownership — never return stale data
        try domainNFT.ownerOf(tokenId) returns (address currentOwner) {
            if (currentOwner != wallet) return "";
        } catch {
            return "";
        }
        return domainNFT.getNameByTokenId(tokenId);
    }

    /**
     * @inheritdoc IResolver
     */
    function hasPrimaryDomain(address wallet) external view override returns (bool) {
        uint256 tokenId = _primaryToken[wallet];
        if (tokenId == 0) return false;
        try domainNFT.ownerOf(tokenId) returns (address currentOwner) {
            return currentOwner == wallet;
        } catch {
            return false;
        }
    }

    /**
     * @inheritdoc IResolver
     */
    function isPrimaryOwner(address wallet, uint256 tokenId) external view override returns (bool) {
        if (_primaryToken[wallet] != tokenId) return false;
        try domainNFT.ownerOf(tokenId) returns (address currentOwner) {
            return currentOwner == wallet;
        } catch {
            return false;
        }
    }

    // ─── Resolution ───────────────────────────────────────────────────────────

    /**
     * @inheritdoc IResolver
     * @dev Ownership is re-verified on every call.  If the wallet transferred
     *      the token after setting it as primary, empty values are returned.
     */
    function reverseResolve(address wallet)
        external
        view
        override
        returns (
            uint256 tokenId,
            string memory domainName,
            string memory fullDomain
        )
    {
        tokenId = _primaryToken[wallet];
        if (tokenId == 0) return (0, "", "");

        // Ownership check — never return stale data
        try domainNFT.ownerOf(tokenId) returns (address currentOwner) {
            if (currentOwner != wallet) return (0, "", "");
        } catch {
            return (0, "", "");
        }

        domainName = domainNFT.getNameByTokenId(tokenId);
        fullDomain  = domainNFT.getFullDomainName(tokenId);
    }

    /**
     * @inheritdoc IResolver
     */
    function resolve(string calldata domain)
        external
        view
        override
        returns (
            address owner,
            uint256 tokenId,
            string memory fullDomain
        )
    {
        try domainNFT.getTokenIdByName(domain) returns (uint256 tid) {
            tokenId = tid;
        } catch {
            return (address(0), 0, "");
        }

        if (tokenId == 0) return (address(0), 0, "");

        try domainNFT.ownerOf(tokenId) returns (address currentOwner) {
            owner = currentOwner;
        } catch {
            return (address(0), 0, "");
        }

        fullDomain = domainNFT.getFullDomainName(tokenId);
    }

    // ─── Future records — stubs (reserved interface, returns safe defaults) ────

    /**
     * @inheritdoc IResolver
     * @dev Text records are reserved for a future upgrade.
     *      Returns an empty string — does not revert.
     */
    function getTextRecord(uint256 tokenId, string calldata key)
        external
        view
        override
        returns (string memory)
    {
        return _textRecords[tokenId][key];
        // When text records are enabled, this mapping will be populated
        // by a new `setTextRecord(uint256,string,string)` function.
    }

    /**
     * @inheritdoc IResolver
     * @dev Address records are reserved for a future upgrade.
     *      Returns address(0) — does not revert.
     *
     *      Supported coin types (SLIP-44):
     *        0   = BTC
     *        60  = ETH / EVM
     *        501 = SOL
     */
    function getAddressRecord(uint256 tokenId, uint256 coinType)
        external
        view
        override
        returns (address)
    {
        bytes memory raw = _addressRecords[tokenId][coinType];
        if (raw.length == 0) return address(0);
        // EVM addresses are stored as 20 bytes
        if (raw.length == 20) {
            address addr;
            assembly {
                addr := mload(add(raw, 20))
            }
            return addr;
        }
        return address(0);
    }

    /**
     * @inheritdoc IResolver
     * @dev Content hashes are reserved for a future upgrade.
     *      Returns empty bytes — does not revert.
     */
    function getContentHash(uint256 tokenId)
        external
        view
        override
        returns (bytes memory)
    {
        return _contentHash[tokenId];
    }
}
