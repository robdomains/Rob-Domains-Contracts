// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

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
 * @title RobCollection
 * @notice Fully on-chain ERC721 collection deployed by CollectionFactory.
 *
 * All metadata is stored inside this contract. No IPFS. No Pinata.
 * contractURI() and tokenURI() generate JSON dynamically and return it
 * as data:application/json;base64,... — compatible with OpenSea, Blur,
 * Rainbow, MetaMask and all standard ERC721 indexers.
 *
 * Key properties:
 * - Sequential token IDs (1, 2, 3, …)
 * - Mint payment forwarded immediately to creator — no treasury, no withdraw
 * - One deployment transaction — no metadata upload, no setMetadataUri call
 */

contract RobCollection is ERC721, Ownable {
    using Strings for uint256;

    // ─────────────────────────────────────────────────────────────────────────
    //  Immutable mint config (set in constructor, never changes)
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public immutable maxSupply;
    uint256 public immutable mintPrice; // in wei
    uint256 public immutable maxPerWallet;
    uint256 public immutable startTime; // unix seconds
    uint256 public immutable endTime;   // unix seconds
    address public immutable creator;

    // ─────────────────────────────────────────────────────────────────────────
    //  On-chain metadata (stored in constructor, never changes)
    // ─────────────────────────────────────────────────────────────────────────

    string private _description;
    string private _imageUrl;
    string private _bannerUrl;
    string private _website;
    string private _twitter;
    string private _discord;
    string private _telegram;

    // ─────────────────────────────────────────────────────────────────────────
    //  Mutable state
    // ─────────────────────────────────────────────────────────────────────────

    uint256 private _totalMinted;
    mapping(address => uint256) public mintedBy;

    // ─────────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────────

    event Minted(address indexed to, uint256 quantity, uint256 totalMinted);

    // ─────────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 _maxSupply,
        uint256 _mintPrice,
        uint256 _maxPerWallet,
        uint256 _startTime,
        uint256 _endTime,
        address _creator,
        string memory description_,
        string memory imageUrl_,
        string memory bannerUrl_,
        string memory website_,
        string memory twitter_,
        string memory discord_,
        string memory telegram_
    ) ERC721(name_, symbol_) Ownable(_creator) {
        require(_creator != address(0), "RobCollection: zero creator");
        require(_maxSupply > 0, "RobCollection: zero supply");
        require(_maxPerWallet > 0, "RobCollection: zero max per wallet");
        require(_endTime > _startTime, "RobCollection: end before start");

        maxSupply    = _maxSupply;
        mintPrice    = _mintPrice;
        maxPerWallet = _maxPerWallet;
        startTime    = _startTime;
        endTime      = _endTime;
        creator      = _creator;

        _description = description_;
        _imageUrl    = imageUrl_;
        _bannerUrl   = bannerUrl_;
        _website     = website_;
        _twitter     = twitter_;
        _discord     = discord_;
        _telegram    = telegram_;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Mint
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Mint `quantity` NFTs. Payment is forwarded directly to the creator.
     *         No treasury, no locked funds, no owner withdrawal.
     */
    function mint(uint256 quantity) external payable {
        require(block.timestamp >= startTime, "RobCollection: mint not started");
        require(block.timestamp <= endTime, "RobCollection: mint ended");
        require(_totalMinted + quantity <= maxSupply, "RobCollection: exceeds max supply");
        require(mintedBy[msg.sender] + quantity <= maxPerWallet, "RobCollection: exceeds max per wallet");
        require(msg.value >= mintPrice * quantity, "RobCollection: insufficient payment");

        mintedBy[msg.sender] += quantity;

        for (uint256 i = 0; i < quantity; i++) {
            _totalMinted++;
            _safeMint(msg.sender, _totalMinted);
        }

        // Forward payment immediately to creator — no treasury, no locked funds
        if (msg.value > 0) {
            (bool success, ) = creator.call{value: msg.value}("");
            require(success, "RobCollection: payment transfer failed");
        }

        emit Minted(msg.sender, quantity, _totalMinted);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Metadata reads
    // ─────────────────────────────────────────────────────────────────────────

    function totalMinted() external view returns (uint256) {
        return _totalMinted;
    }

    /// @notice Public getters for each on-chain metadata field.
    function description() external view returns (string memory) { return _description; }
    function imageUrl()    external view returns (string memory) { return _imageUrl; }
    function bannerUrl()   external view returns (string memory) { return _bannerUrl; }
    function website()     external view returns (string memory) { return _website; }
    function twitter()     external view returns (string memory) { return _twitter; }
    function discord()     external view returns (string memory) { return _discord; }
    function telegram()    external view returns (string memory) { return _telegram; }

    /**
     * @notice OpenSea / marketplace collection metadata URI.
     *         Returns a fully on-chain data URI — no IPFS, no Pinata.
     *         Compatible with OpenSea contractURI standard.
     */
    function contractURI() external view returns (string memory) {
        bytes memory json = abi.encodePacked(
            '{"name":"',        _escapeJson(name()),        '"',
            ',"description":"', _escapeJson(_description),  '"',
            ',"image":"',       _imageUrl,                  '"',
            ',"banner_image_url":"', _bannerUrl,            '"',
            ',"symbol":"',      _escapeJson(symbol()),      '"'
        );

        if (bytes(_website).length > 0) {
            json = abi.encodePacked(json, ',"external_link":"', _website, '"');
        }
        if (bytes(_twitter).length > 0) {
            json = abi.encodePacked(json, ',"twitter":"', _twitter, '"');
        }
        if (bytes(_discord).length > 0) {
            json = abi.encodePacked(json, ',"discord":"', _discord, '"');
        }
        if (bytes(_telegram).length > 0) {
            json = abi.encodePacked(json, ',"telegram":"', _telegram, '"');
        }

        json = abi.encodePacked(json, '}');

        return string(
            abi.encodePacked(
                'data:application/json;base64,',
                Base64.encode(json)
            )
        );
    }

    /**
     * @notice Per-token metadata URI.
     *         Each token shares the collection image. Only the name includes the token ID.
     *         Returns a fully on-chain data URI — no IPFS, no Pinata.
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(tokenId >= 1 && tokenId <= _totalMinted, "RobCollection: token does not exist");

        string memory tokenName = string(
            abi.encodePacked(_escapeJson(name()), ' #', tokenId.toString())
        );

        bytes memory json = abi.encodePacked(
            '{"name":"',        tokenName,                 '"',
            ',"description":"', _escapeJson(_description), '"',
            ',"image":"',       _imageUrl,                 '"',
            '}'
        );

        return string(
            abi.encodePacked(
                'data:application/json;base64,',
                Base64.encode(json)
            )
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Escapes double-quotes and backslashes so the value is safe inside a JSON string.
     */
    function _escapeJson(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 extraChars = 0;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == '"' || b[i] == '\\') extraChars++;
        }
        if (extraChars == 0) return s;

        bytes memory result = new bytes(b.length + extraChars);
        uint256 j = 0;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == '"' || b[i] == '\\') {
                result[j++] = '\\';
            }
            result[j++] = b[i];
        }
        return string(result);
    }
}
