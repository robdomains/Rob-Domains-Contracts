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
 * @title IResolver
 * @notice Public interface for the RobResolver contract.
 *         External integrators (wallets, block explorers, dApps) should depend
 *         on this interface rather than the concrete implementation so future
 *         upgrades remain backward compatible.
 */
interface IResolver {
    // ─── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted when a wallet sets or changes its primary domain.
    /// @param wallet  The wallet address that called setPrimaryDomain.
    /// @param tokenId The token ID of the newly chosen primary domain.
    event PrimaryDomainChanged(address indexed wallet, uint256 indexed tokenId);

    /// @notice Emitted when a wallet clears its primary domain.
    /// @param wallet  The wallet address that called clearPrimaryDomain.
    event PrimaryDomainCleared(address indexed wallet);

    // ─── Primary domain write ─────────────────────────────────────────────────

    /**
     * @notice Designates `tokenId` as the caller's primary .rob domain.
     * @dev    Reverts if the caller does not own `tokenId` according to the
     *         DomainNFT contract.
     * @param tokenId The ERC-721 token ID to set as primary.
     */
    function setPrimaryDomain(uint256 tokenId) external;

    /**
     * @notice Removes the caller's primary domain designation.
     * @dev    Emits PrimaryDomainCleared even if no primary was set (idempotent).
     */
    function clearPrimaryDomain() external;

    // ─── Primary domain read ──────────────────────────────────────────────────

    /// @notice Returns the primary token ID for `wallet`, or 0 if none is set.
    function getPrimaryToken(address wallet) external view returns (uint256 tokenId);

    /**
     * @notice Returns the primary domain name for `wallet` (without ".rob").
     * @dev    Returns an empty string when no valid primary domain is set or
     *         when the wallet no longer owns the previously set token.
     */
    function getPrimaryDomain(address wallet) external view returns (string memory domainName);

    /// @notice Returns true if `wallet` has a valid, still-owned primary domain.
    function hasPrimaryDomain(address wallet) external view returns (bool);

    /**
     * @notice Returns true if `wallet` currently owns `tokenId` and it is their
     *         registered primary domain.
     */
    function isPrimaryOwner(address wallet, uint256 tokenId) external view returns (bool);

    // ─── Resolution ───────────────────────────────────────────────────────────

    /**
     * @notice Reverse resolution — maps a wallet address to its primary domain.
     * @dev    Always verifies current on-chain ownership before returning data.
     *         Returns zeroed values if ownership has changed since the primary
     *         was registered.
     * @param wallet The wallet address to resolve.
     * @return tokenId    The primary token ID (0 if none).
     * @return domainName The name without TLD (empty if none).
     * @return fullDomain The full name with ".rob" suffix (empty if none).
     */
    function reverseResolve(address wallet)
        external
        view
        returns (
            uint256 tokenId,
            string memory domainName,
            string memory fullDomain
        );

    /**
     * @notice Forward resolution — maps a domain name to its current owner.
     * @dev    Delegates to the DomainNFT contract for all lookups so the result
     *         always reflects the current on-chain state.
     * @param domain The plain domain name without ".rob" suffix.
     * @return owner      Current owner address (address(0) if not minted).
     * @return tokenId    The token ID for this domain.
     * @return fullDomain The full domain with ".rob" suffix.
     */
    function resolve(string calldata domain)
        external
        view
        returns (
            address owner,
            uint256 tokenId,
            string memory fullDomain
        );

    // ─── Future text records (reserved interface) ─────────────────────────────

    /**
     * @notice Returns a text record by key for a given token.
     * @dev    Not yet implemented — reserved for future upgrade.
     *         Implementors MUST return an empty string rather than reverting.
     */
    function getTextRecord(uint256 tokenId, string calldata key)
        external
        view
        returns (string memory value);

    /**
     * @notice Returns an address record for a given token and coin type.
     * @dev    Not yet implemented — reserved for future upgrade.
     *         Implementors MUST return address(0) rather than reverting.
     * @param coinType SLIP-44 coin type (60 = ETH, 0 = BTC, 501 = SOL).
     */
    function getAddressRecord(uint256 tokenId, uint256 coinType)
        external
        view
        returns (address addr);

    /**
     * @notice Returns the content hash for a given token (e.g. IPFS CID).
     * @dev    Not yet implemented — reserved for future upgrade.
     */
    function getContentHash(uint256 tokenId) external view returns (bytes memory contenthash);
}
