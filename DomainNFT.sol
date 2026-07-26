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
 * @dev Interface that contract receivers must implement to accept ERC-721 tokens
 *      via safeTransferFrom. Defined here so DomainNFT has no external imports.
 */
interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

/**
 * @title DomainNFT
 * @notice ERC-721 domain name registry. Each domain is minted as an NFT.
 *         Profile metadata is stored per token (not per wallet).
 *         One wallet may own unlimited domains.
 *         The domain name is permanently locked after minting.
 */
contract DomainNFT {
    // ─────────────────────────────────────────────
    //  ERC-165
    // ─────────────────────────────────────────────
    bytes4 private constant _INTERFACE_ID_ERC165   = 0x01ffc9a7;
    bytes4 private constant _INTERFACE_ID_ERC721   = 0x80ac58cd;
    bytes4 private constant _INTERFACE_ID_ERC721MD = 0x5b5e139f;

    // Magic value returned by a correct IERC721Receiver implementation.
    bytes4 private constant _ERC721_RECEIVED = 0x150b7a02;

    // ─────────────────────────────────────────────
    //  ERC-721 storage
    // ─────────────────────────────────────────────
    string private _name;
    string private _symbol;

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;
    mapping(uint256 => string)  private _tokenURIs;

    // ─────────────────────────────────────────────
    //  Domain-specific storage
    // ─────────────────────────────────────────────
    address public admin;
    address public treasury;
    uint256 public mintFee = 0.0005 ether;
    uint256 private _tokenIdCounter;
    uint256 private _totalMinted;

    // default metadata URI applied to every newly minted token
    string public defaultTokenURI;

    // domain name → token ID (0 = unminted)
    mapping(string => uint256)  private _nameToTokenId;
    // token ID → domain name
    mapping(uint256 => string)  private _tokenIdToName;
    // owner address → array of owned token IDs
    mapping(address => uint256[]) private _ownedTokens;
    // token ID → index within owner's array (used for O(1) removal)
    mapping(uint256 => uint256) private _ownedTokensIndex;

    // ─────────────────────────────────────────────
    //  Profile storage (per token)
    // ─────────────────────────────────────────────
    struct SocialLink {
        string platform;
        string url;
        string icon;
    }

    struct CustomLink {
        string title;
        string url;
    }

    struct Profile {
        string profilePicture; // URL
        string coverImage;     // URL
        string bio;
        string background;
        SocialLink[] socialLinks;
        CustomLink[] customLinks;
    }

    mapping(uint256 => Profile) private _profiles;

    // ─────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event DomainMinted(address indexed owner, uint256 indexed tokenId, string domainName);
    event ProfileUpdated(uint256 indexed tokenId, string domainName);
    event TokenURIUpdated(uint256 indexed tokenId, string newURI);
    event MintFeeUpdated(uint256 newFee);
    event TreasuryUpdated(address newTreasury);
    event DefaultTokenURIUpdated(string newURI);

    // ─────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────
    constructor(address _treasury, string memory _defaultTokenURI) {
        require(_treasury != address(0), "DomainNFT: zero treasury");
        _name         = "Rob Domain Names";
        _symbol       = "ROB";
        admin         = msg.sender;
        treasury      = _treasury;
        defaultTokenURI = _defaultTokenURI;
    }

    // ─────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────
    modifier onlyAdmin() {
        require(msg.sender == admin, "DomainNFT: not admin");
        _;
    }

    modifier onlyTokenOwner(uint256 tokenId) {
        require(_owners[tokenId] == msg.sender, "DomainNFT: not token owner");
        _;
    }

    // ─────────────────────────────────────────────
    //  ERC-165
    // ─────────────────────────────────────────────
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == _INTERFACE_ID_ERC165 ||
               interfaceId == _INTERFACE_ID_ERC721 ||
               interfaceId == _INTERFACE_ID_ERC721MD;
    }

    // ─────────────────────────────────────────────
    //  Base64 encoding (for on-chain tokenURI)
    // ─────────────────────────────────────────────
    string private constant _B64_TABLE =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    /**
     * @dev Encodes `data` using Base64. Adapted from OpenZeppelin's Base64.sol.
     */
    function _base64Encode(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";

        string memory table = _B64_TABLE;
        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        // Add 32 bytes for the length slot; assembly will set the real length.
        string memory result = new string(encodedLen + 32);

        assembly {
            let tablePtr  := add(table, 1)
            let dataPtr   := data
            let endPtr    := add(dataPtr, mload(data))
            let resultPtr := add(result, 32)

            for { } lt(dataPtr, endPtr) { } {
                dataPtr := add(dataPtr, 3)
                let input := mload(dataPtr)

                mstore8(resultPtr,      mload(add(tablePtr, and(shr(18, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr,      mload(add(tablePtr, and(shr(12, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr,      mload(add(tablePtr, and(shr( 6, input), 0x3F))))
                resultPtr := add(resultPtr, 1)
                mstore8(resultPtr,      mload(add(tablePtr, and(      input,    0x3F))))
                resultPtr := add(resultPtr, 1)
            }

            // Add padding
            switch mod(mload(data), 3)
            case 1 { mstore(sub(resultPtr, 2), shl(240, 0x3d3d)) }
            case 2 { mstore(sub(resultPtr, 1), shl(248, 0x3d))   }

            mstore(result, encodedLen)
        }

        return result;
    }

    // ─────────────────────────────────────────────
    //  ERC-721 Metadata
    // ─────────────────────────────────────────────
    function name()   public view returns (string memory) { return _name;   }
    function symbol() public view returns (string memory) { return _symbol; }

    /**
     * @notice Returns the metadata URI for `tokenId`.
     *
     * If the owner has uploaded custom IPFS metadata (via `updateTokenURI`),
     * that URI is returned as-is — it already contains the domain name.
     *
     * Otherwise an on-chain data URI is generated so that every token
     * immediately shows its domain name (e.g. "john.rob") on OpenSea,
     * blockchain explorers, and any other ERC-721 metadata reader,
     * even before the owner uploads a profile image.
     */
    function tokenURI(uint256 tokenId) public view returns (string memory) {
        require(_exists(tokenId), "DomainNFT: nonexistent token");

        // If a custom IPFS URI has been set, use it — it contains the full
        // profile metadata with the correct "name" field already.
        string memory uri = _tokenURIs[tokenId];
        if (bytes(uri).length > 0) return uri;

        // No custom URI yet: generate on-chain metadata so marketplaces
        // display the domain name instead of a generic "#<tokenId>".
        string memory domain   = _tokenIdToName[tokenId];
        string memory fullName = string(abi.encodePacked(domain, ".rob"));

        bytes memory json = abi.encodePacked(
            '{"name":"',        fullName, '",'
            '"description":"Domain names built on Robinhood Chain.",'
            '"image":"',        defaultTokenURI, '",'
            '"attributes":['
                '{"trait_type":"Domain","value":"', fullName, '"}'
            ']}'
        );

        return string(abi.encodePacked(
            "data:application/json;base64,",
            _base64Encode(json)
        ));
    }

    // ─────────────────────────────────────────────
    //  ERC-721 Core
    // ─────────────────────────────────────────────
    function balanceOf(address owner) public view returns (uint256) {
        require(owner != address(0), "DomainNFT: zero address");
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "DomainNFT: nonexistent token");
        return owner;
    }

    function approve(address to, uint256 tokenId) public {
        address owner = ownerOf(tokenId);
        require(to != owner, "DomainNFT: approval to current owner");
        require(
            msg.sender == owner || isApprovedForAll(owner, msg.sender),
            "DomainNFT: not owner nor approved for all"
        );
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function getApproved(uint256 tokenId) public view returns (address) {
        require(_exists(tokenId), "DomainNFT: nonexistent token");
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) public {
        require(operator != msg.sender, "DomainNFT: approve to caller");
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner, address operator) public view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(_isApprovedOrOwner(msg.sender, tokenId), "DomainNFT: not owner nor approved");
        _transfer(from, to, tokenId);
    }

    /**
     * @notice Safe transfer that checks receiver compatibility.
     * @dev If `to` is a contract, calls onERC721Received and reverts if it
     *      does not return the ERC-721 magic value. EOAs always pass.
     */
    function safeTransferFrom(address from, address to, uint256 tokenId) public {
        safeTransferFrom(from, to, tokenId, "");
    }

    /**
     * @notice Safe transfer with additional data payload.
     * @dev If `to` is a contract, calls onERC721Received with `data` and
     *      reverts if the receiver does not return the ERC-721 magic value,
     *      preventing domains from being permanently locked inside non-receiver
     *      contracts. EOAs are unaffected.
     */
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        require(_isApprovedOrOwner(msg.sender, tokenId), "DomainNFT: not owner nor approved");
        _transfer(from, to, tokenId);
        _checkOnERC721Received(msg.sender, from, to, tokenId, data);
    }

    // ─────────────────────────────────────────────
    //  Domain minting
    // ─────────────────────────────────────────────

    /**
     * @notice Check whether a domain name is available to mint.
     * @param domainName The name without suffix (e.g. "alex").
     */
    function isAvailable(string memory domainName) public view returns (bool) {
        _validateName(domainName);
        return _nameToTokenId[domainName] == 0;
    }

    /**
     * @notice Mint a domain NFT.
     * @param domainName The desired name (e.g. "alex" → "alex.rob").
     *        Must be unique, non-empty, and alphanumeric/hyphen.
     */
    function mintDomain(string memory domainName) external payable returns (uint256) {
        _validateName(domainName);
        require(_nameToTokenId[domainName] == 0, "DomainNFT: domain already minted");
        require(msg.value >= mintFee, "DomainNFT: insufficient mint fee");

        // Forward fee to treasury
        (bool sent, ) = treasury.call{value: msg.value}("");
        require(sent, "DomainNFT: fee transfer failed");

        _tokenIdCounter++;
        uint256 newTokenId = _tokenIdCounter;
        _totalMinted++;

        _mint(msg.sender, newTokenId);

        _nameToTokenId[domainName]   = newTokenId;
        _tokenIdToName[newTokenId]   = domainName;

        // Token URI defaults to defaultTokenURI; no explicit storage needed.

        emit DomainMinted(msg.sender, newTokenId, domainName);
        return newTokenId;
    }

    // ─────────────────────────────────────────────
    //  Profile management (per token, owner only)
    // ─────────────────────────────────────────────

    /**
     * @notice Update the profile metadata for a domain the caller owns.
     *         Domain name is NOT updatable.
     */
    function updateProfile(
        uint256 tokenId,
        string memory profilePicture,
        string memory coverImage,
        string memory bio,
        string memory background
    ) external onlyTokenOwner(tokenId) {
        Profile storage p = _profiles[tokenId];
        p.profilePicture = profilePicture;
        p.coverImage     = coverImage;
        p.bio            = bio;
        p.background     = background;
        emit ProfileUpdated(tokenId, _tokenIdToName[tokenId]);
    }

    function setSocialLink(
        uint256 tokenId,
        string memory platform,
        string memory url,
        string memory icon
    ) public onlyTokenOwner(tokenId) {
        Profile storage p = _profiles[tokenId];
        bool found = false;
        for (uint256 i = 0; i < p.socialLinks.length; i++) {
            if (keccak256(bytes(p.socialLinks[i].platform)) == keccak256(bytes(platform))) {
                if (bytes(url).length == 0) {
                    // Remove by shifting
                    for (uint256 j = i; j < p.socialLinks.length - 1; j++) {
                        p.socialLinks[j] = p.socialLinks[j + 1];
                    }
                    p.socialLinks.pop();
                } else {
                    p.socialLinks[i].url  = url;
                    p.socialLinks[i].icon = icon;
                }
                found = true;
                break;
            }
        }
        if (!found && bytes(url).length > 0) {
            p.socialLinks.push(SocialLink(platform, url, icon));
        }
    }

    function batchSetSocialLinks(
        uint256 tokenId,
        string[] memory platforms,
        string[] memory urls,
        string[] memory icons
    ) external onlyTokenOwner(tokenId) {
        require(
            platforms.length == urls.length && urls.length == icons.length,
            "DomainNFT: length mismatch"
        );
        for (uint256 i = 0; i < platforms.length; i++) {
            setSocialLink(tokenId, platforms[i], urls[i], icons[i]);
        }
    }

    function removeSocialLink(uint256 tokenId, string memory platform) external onlyTokenOwner(tokenId) {
        Profile storage p = _profiles[tokenId];
        for (uint256 i = 0; i < p.socialLinks.length; i++) {
            if (keccak256(bytes(p.socialLinks[i].platform)) == keccak256(bytes(platform))) {
                for (uint256 j = i; j < p.socialLinks.length - 1; j++) {
                    p.socialLinks[j] = p.socialLinks[j + 1];
                }
                p.socialLinks.pop();
                return;
            }
        }
        revert("DomainNFT: social link not found");
    }

    function addCustomLink(
        uint256 tokenId,
        string memory title,
        string memory url
    ) public onlyTokenOwner(tokenId) {
        _profiles[tokenId].customLinks.push(CustomLink(title, url));
    }

    function batchAddCustomLinks(
        uint256 tokenId,
        string[] memory titles,
        string[] memory urls
    ) external onlyTokenOwner(tokenId) {
        require(titles.length == urls.length, "DomainNFT: length mismatch");
        for (uint256 i = 0; i < titles.length; i++) {
            addCustomLink(tokenId, titles[i], urls[i]);
        }
    }

    function updateCustomLink(
        uint256 tokenId,
        uint256 index,
        string memory title,
        string memory url
    ) external onlyTokenOwner(tokenId) {
        Profile storage p = _profiles[tokenId];
        require(index < p.customLinks.length, "DomainNFT: invalid index");
        p.customLinks[index].title = title;
        p.customLinks[index].url   = url;
    }

    function removeCustomLink(uint256 tokenId, uint256 index) external onlyTokenOwner(tokenId) {
        Profile storage p = _profiles[tokenId];
        require(index < p.customLinks.length, "DomainNFT: invalid index");
        for (uint256 i = index; i < p.customLinks.length - 1; i++) {
            p.customLinks[i] = p.customLinks[i + 1];
        }
        p.customLinks.pop();
    }

    /**
     * @notice Update the IPFS metadata URI for a token (called after Pinata upload).
     */
    function updateTokenURI(uint256 tokenId, string memory uri) external onlyTokenOwner(tokenId) {
        _tokenURIs[tokenId] = uri;
        emit TokenURIUpdated(tokenId, uri);
    }

    // ─────────────────────────────────────────────
    //  View helpers
    // ─────────────────────────────────────────────

    function getProfile(uint256 tokenId) external view returns (
        string memory domainName,
        address owner,
        string memory profilePicture,
        string memory coverImage,
        string memory bio,
        string memory background,
        SocialLink[] memory socialLinks,
        CustomLink[] memory customLinks
    ) {
        require(_exists(tokenId), "DomainNFT: nonexistent token");
        Profile storage p = _profiles[tokenId];
        return (
            _tokenIdToName[tokenId],
            _owners[tokenId],
            p.profilePicture,
            p.coverImage,
            p.bio,
            p.background,
            p.socialLinks,
            p.customLinks
        );
    }

    function getTokenIdByName(string memory domainName) external view returns (uint256) {
        uint256 tokenId = _nameToTokenId[domainName];
        require(tokenId != 0, "DomainNFT: domain not found");
        return tokenId;
    }

    function getNameByTokenId(uint256 tokenId) external view returns (string memory) {
        require(_exists(tokenId), "DomainNFT: nonexistent token");
        return _tokenIdToName[tokenId];
    }

    function getDomainsOfOwner(address owner) external view returns (uint256[] memory) {
        return _ownedTokens[owner];
    }

    function getTotalMinted() external view returns (uint256) {
        return _totalMinted;
    }

    function getFullDomainName(uint256 tokenId) external view returns (string memory) {
        require(_exists(tokenId), "DomainNFT: nonexistent token");
        return string(abi.encodePacked(_tokenIdToName[tokenId], ".rob"));
    }

    // ─────────────────────────────────────────────
    //  Admin
    // ─────────────────────────────────────────────

    function updateMintFee(uint256 newFee) external onlyAdmin {
        mintFee = newFee;
        emit MintFeeUpdated(newFee);
    }

    function updateTreasury(address newTreasury) external onlyAdmin {
        require(newTreasury != address(0), "DomainNFT: zero address");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function updateDefaultTokenURI(string memory uri) external onlyAdmin {
        defaultTokenURI = uri;
        emit DefaultTokenURIUpdated(uri);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "DomainNFT: zero address");
        admin = newAdmin;
    }

    // ─────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────

    function _exists(uint256 tokenId) internal view returns (bool) {
        return _owners[tokenId] != address(0);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        require(_exists(tokenId), "DomainNFT: nonexistent token");
        address owner = _owners[tokenId];
        return (spender == owner ||
                getApproved(tokenId) == spender ||
                isApprovedForAll(owner, spender));
    }

    function _mint(address to, uint256 tokenId) internal {
        require(to != address(0), "DomainNFT: mint to zero address");
        require(!_exists(tokenId), "DomainNFT: already minted");

        _balances[to]    += 1;
        _owners[tokenId]  = to;

        // Track owned tokens
        _ownedTokensIndex[tokenId] = _ownedTokens[to].length;
        _ownedTokens[to].push(tokenId);

        emit Transfer(address(0), to, tokenId);
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        require(ownerOf(tokenId) == from, "DomainNFT: incorrect owner");
        require(to != address(0), "DomainNFT: zero address");

        delete _tokenApprovals[tokenId];

        // Remove from sender's list
        uint256 lastIndex = _ownedTokens[from].length - 1;
        uint256 tokenIndex = _ownedTokensIndex[tokenId];
        if (tokenIndex != lastIndex) {
            uint256 lastTokenId = _ownedTokens[from][lastIndex];
            _ownedTokens[from][tokenIndex] = lastTokenId;
            _ownedTokensIndex[lastTokenId] = tokenIndex;
        }
        _ownedTokens[from].pop();

        // Add to receiver's list
        _ownedTokensIndex[tokenId] = _ownedTokens[to].length;
        _ownedTokens[to].push(tokenId);

        _balances[from] -= 1;
        _balances[to]   += 1;
        _owners[tokenId] = to;

        emit Transfer(from, to, tokenId);
    }

    /**
     * @dev Checks that `to` can receive ERC-721 tokens if it is a contract.
     *      Calls onERC721Received on contract receivers and reverts if the
     *      return value is not the ERC-721 magic value (0x150b7a02).
     *      EOAs (code length == 0) always pass without any call.
     *
     * @param operator The address that initiated the transfer (msg.sender).
     * @param from     The address that previously owned the token.
     * @param to       The recipient address to check.
     * @param tokenId  The token being transferred.
     * @param data     Optional data to forward to onERC721Received.
     */
    function _checkOnERC721Received(
        address operator,
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) internal {
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(operator, from, tokenId, data) returns (bytes4 retval) {
                require(
                    retval == _ERC721_RECEIVED,
                    "DomainNFT: transfer to non ERC721Receiver implementer"
                );
            } catch {
                revert("DomainNFT: transfer to non ERC721Receiver implementer");
            }
        }
    }

    function _validateName(string memory domainName) internal pure {
        bytes memory b = bytes(domainName);
        require(b.length >= 1 && b.length <= 63, "DomainNFT: invalid name length");
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            require(
                (c >= 0x30 && c <= 0x39) || // 0-9
                (c >= 0x61 && c <= 0x7A) || // a-z
                c == 0x2D,                   // hyphen
                "DomainNFT: invalid character (use lowercase a-z, 0-9, hyphen)"
            );
        }
        // Cannot start or end with hyphen
        require(b[0] != 0x2D && b[b.length - 1] != 0x2D, "DomainNFT: name cannot start/end with hyphen");
    }
}
