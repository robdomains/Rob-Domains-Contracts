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
 * @title IDomainNFT
 * @notice Minimal interface for the deployed RobDomains DomainNFT contract.
 *         The Resolver reads ownership and name data through this interface
 *         without touching the NFT contract storage or logic.
 *
 * DO NOT modify DomainNFT.sol — this interface interacts with the already-
 * deployed contract at a fixed address.
 */
interface IDomainNFT {
    // ─── ERC-721 ──────────────────────────────────────────────────────────────

    /// @notice Returns the owner of the given token.
    function ownerOf(uint256 tokenId) external view returns (address owner);

    /// @notice Returns the number of tokens owned by `owner`.
    function balanceOf(address owner) external view returns (uint256 balance);

    // ─── Domain name resolution ───────────────────────────────────────────────

    /// @notice Resolves a domain name to its token ID.
    /// @param domainName The plain name without the ".rob" suffix (e.g. "alice").
    function getTokenIdByName(string calldata domainName) external view returns (uint256 tokenId);

    /// @notice Resolves a token ID to its domain name (without ".rob" suffix).
    function getNameByTokenId(uint256 tokenId) external view returns (string memory domainName);

    /// @notice Returns the full domain including TLD (e.g. "alice.rob").
    function getFullDomainName(uint256 tokenId) external view returns (string memory fullDomain);

    /// @notice Returns all token IDs owned by `owner`.
    function getDomainsOfOwner(address owner) external view returns (uint256[] memory tokenIds);

    /// @notice Returns the total number of minted domains.
    function getTotalMinted() external view returns (uint256 total);

    // ─── Profile data ─────────────────────────────────────────────────────────

    /// @notice Returns on-chain profile data for a given token.
    function getProfile(uint256 tokenId)
        external
        view
        returns (
            string memory domainName,
            address owner,
            string memory profilePicture,
            string memory coverImage,
            string memory bio,
            string memory background,
            ProfileSocialLink[] memory socialLinks,
            ProfileCustomLink[] memory customLinks
        );

    // ─── Availability ─────────────────────────────────────────────────────────

    /// @notice Returns true if the domain name has not been minted yet.
    function isAvailable(string calldata domainName) external view returns (bool available);

    // ─── Structs (must mirror DomainNFT) ─────────────────────────────────────

    struct ProfileSocialLink {
        string platform;
        string url;
        string icon;
    }

    struct ProfileCustomLink {
        string title;
        string url;
    }
}
