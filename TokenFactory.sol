// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "./RobToken.sol";

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
 * @title TokenFactory
 * @notice Allows .rob domain owners to deploy standard ERC20 tokens.
 *
 * Access control:
 *   - Only addresses that own at least one .rob domain NFT may call createToken.
 *   - Checked on-chain via IDomainNFT.getDomainsOfOwner — calling from an
 *     explorer without owning a domain will always revert.
 *
 * Storage:
 *   - All token metadata (name, symbol, logoUrl, description, supply) is stored
 *     on-chain in the factory mapping — no IPFS, no Pinata.
 *   - Sequential integer IDs starting from 1.
 */

interface IDomainNFT {
    function getDomainsOfOwner(address owner) external view returns (uint256[] memory);
}

contract TokenFactory {
    // ─────────────────────────────────────────────────────────────────────────
    //  Storage types
    // ─────────────────────────────────────────────────────────────────────────

    struct TokenInfo {
        uint256 id;
        address owner;
        address token;          // deployed ERC20 contract address
        string  name;
        string  symbol;
        string  logoUrl;
        string  description;
        uint256 supply;         // whole-token amount (not wei)
        uint256 createdAt;      // block.timestamp (seconds)
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────────────────

    IDomainNFT public immutable domainNFT;

    uint256 public tokenCount;
    mapping(uint256 => TokenInfo)   private _tokens;
    mapping(address => uint256[])   private _tokensByOwner;

    // ─────────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────────

    event TokenCreated(
        uint256 indexed id,
        address indexed owner,
        address indexed token
    );

    // ─────────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @param domainNFT_ Address of the DomainNFT contract used for ownership checks.
     */
    constructor(address domainNFT_) {
        require(domainNFT_ != address(0), "TokenFactory: zero address");
        domainNFT = IDomainNFT(domainNFT_);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Write
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Deploy a new ERC20 token. Caller must own at least one .rob domain.
     * @param name_        Token name.
     * @param symbol_      Token symbol (ticker).
     * @param logoUrl_     URL of the token logo image (stored as-is).
     * @param description_ Optional description.
     * @param supply_      Total supply in whole tokens (fixed 18 decimals applied internally).
     * @return id          Sequential token ID.
     * @return tokenAddr   Address of the deployed ERC20 contract.
     */
    function createToken(
        string calldata name_,
        string calldata symbol_,
        string calldata logoUrl_,
        string calldata description_,
        uint256 supply_
    ) external returns (uint256 id, address tokenAddr) {
        require(
            domainNFT.getDomainsOfOwner(msg.sender).length > 0,
            "TokenFactory: must own a .rob domain"
        );
        require(bytes(name_).length   > 0, "TokenFactory: name required");
        require(bytes(symbol_).length > 0, "TokenFactory: symbol required");
        require(supply_ > 0,               "TokenFactory: supply must be > 0");

        tokenCount++;
        id = tokenCount;

        RobToken token = new RobToken(name_, symbol_, supply_, msg.sender);
        tokenAddr = address(token);

        _tokens[id] = TokenInfo({
            id:          id,
            owner:       msg.sender,
            token:       tokenAddr,
            name:        name_,
            symbol:      symbol_,
            logoUrl:     logoUrl_,
            description: description_,
            supply:      supply_,
            createdAt:   block.timestamp
        });

        _tokensByOwner[msg.sender].push(id);

        emit TokenCreated(id, msg.sender, tokenAddr);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Read
    // ─────────────────────────────────────────────────────────────────────────

    function getToken(uint256 id) external view returns (TokenInfo memory) {
        return _tokens[id];
    }

    function getTokenCount() external view returns (uint256) {
        return tokenCount;
    }

    function getTokensByOwner(address owner) external view returns (uint256[] memory) {
        return _tokensByOwner[owner];
    }

    function getAllTokens() external view returns (TokenInfo[] memory) {
        TokenInfo[] memory all = new TokenInfo[](tokenCount);
        for (uint256 i = 1; i <= tokenCount; i++) {
            all[i - 1] = _tokens[i];
        }
        return all;
    }
}
