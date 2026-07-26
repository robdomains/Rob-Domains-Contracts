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
 * @notice Minimal interface for the existing DomainNFT contract.
 */
interface IDomainNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getTokenIdByName(string memory name) external view returns (uint256);
    function getDomainsOfOwner(address owner) external view returns (uint256[] memory);
    function getNameByTokenId(uint256 tokenId) external view returns (string memory);
}

/**
 * @title DomainChat
 * @notice On-chain messaging for .rob domain profiles.
 *
 * Conversation model
 * ──────────────────
 * Every pair of participants (A, B) shares a single deterministic conversation:
 *
 *   conversationId = keccak256(abi.encodePacked(min(A,B), max(A,B)))
 *
 * This means Conversation(A,B) == Conversation(B,A) always.  Both A and B send
 * their messages under the SAME conversationId, so the entire thread is
 * reconstructed with a single indexed query.
 *
 * A conversation is always anchored to a .rob domain: one of the two
 * participants must be the domain owner.  This lets the domain owner manage
 * block / read-receipt state and lets the frontend scope conversations to a
 * profile page.
 *
 * Indexing strategy
 * ─────────────────
 * All three events carry three indexed parameters:
 *   [messageId]     → look up a specific message (edit / delete)
 *   [conversationId] → fetch the full two-way thread (frontend message view)
 *   [domainTokenId] → fetch every conversation for a domain (owner inbox)
 */
contract DomainChat {
    // ─────────────────────────────────────────────
    //  Immutables
    // ─────────────────────────────────────────────

    /// @notice The DomainNFT contract used to verify ownership.
    IDomainNFT public immutable domainNFT;

    // ─────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────

    /// @dev Auto-incrementing message ID counter.
    uint256 private _messageCount;

    /// @dev messageId → original sender address (for edit/delete auth).
    mapping(uint256 => address) private _messageSender;

    /// @dev messageId → soft-delete flag.
    mapping(uint256 => bool) public messageDeleted;

    /// @dev blocked[domainTokenId][senderAddress] → true if blocked.
    mapping(uint256 => mapping(address => bool)) public blocked;

    /// @dev conversationReadAt[domainTokenId][peerAddress] → unix timestamp of last read.
    mapping(uint256 => mapping(address => uint256)) public conversationReadAt;

    // ─────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────

    /**
     * @notice Emitted when a message is sent in a conversation.
     * @param messageId      Unique, monotonically increasing message ID.
     * @param conversationId Deterministic ID for the (sender, peer) pair —
     *                       keccak256(abi.encodePacked(min(sender,peer), max(sender,peer))).
     *                       Identical for both directions of the same conversation.
     * @param domainTokenId  Token ID of the .rob domain this conversation belongs to.
     * @param sender         Address of the message sender.
     * @param peer           Address of the other conversation participant.
     * @param encryptedContent AES-GCM ciphertext (base64); plaintext never stored.
     * @param timestamp      Block timestamp at send time.
     */
    event MessageSent(
        uint256 indexed messageId,
        bytes32 indexed conversationId,
        uint256 indexed domainTokenId,
        address sender,
        address peer,
        string encryptedContent,
        uint256 timestamp
    );

    /**
     * @notice Emitted when a sender edits one of their own messages.
     * @param messageId      The ID of the message being edited.
     * @param conversationId Conversation this message belongs to.
     * @param domainTokenId  Domain token for index queries.
     * @param sender         Must be the original sender.
     * @param encryptedContent New AES-GCM ciphertext.
     * @param timestamp      Block timestamp of the edit.
     */
    event MessageEdited(
        uint256 indexed messageId,
        bytes32 indexed conversationId,
        uint256 indexed domainTokenId,
        address sender,
        string encryptedContent,
        uint256 timestamp
    );

    /**
     * @notice Emitted on soft-delete.
     * @param messageId      The ID of the deleted message.
     * @param conversationId Conversation this message belongs to.
     * @param domainTokenId  Domain token for index queries.
     * @param timestamp      Block timestamp of the deletion.
     */
    event MessageDeleted(
        uint256 indexed messageId,
        bytes32 indexed conversationId,
        uint256 indexed domainTokenId,
        uint256 timestamp
    );

    /**
     * @notice Emitted when a domain owner marks a conversation as read.
     */
    event ConversationRead(
        uint256 indexed domainTokenId,
        address indexed reader,
        address indexed conversationWith,
        uint256 timestamp
    );

    /**
     * @notice Emitted when a domain owner blocks a sender.
     */
    event UserBlocked(
        uint256 indexed domainTokenId,
        address indexed blockedUser,
        uint256 timestamp
    );

    /**
     * @notice Emitted when a domain owner unblocks a previously blocked sender.
     */
    event UserUnblocked(
        uint256 indexed domainTokenId,
        address indexed unblockedUser,
        uint256 timestamp
    );

    // ─────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────

    constructor(address _domainNFT) {
        require(_domainNFT != address(0), "DomainChat: zero NFT address");
        domainNFT = IDomainNFT(_domainNFT);
    }

    // ─────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────

    /**
     * @dev Deterministic conversation ID for any ordered or unordered (a, b) pair.
     *      Conversation(A,B) == Conversation(B,A) always.
     */
    function _conversationId(address a, address b) internal pure returns (bytes32) {
        return a < b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }

    // ─────────────────────────────────────────────
    //  Public write functions
    // ─────────────────────────────────────────────

    /**
     * @notice Send an encrypted message in a conversation anchored to a .rob domain.
     *
     * @dev  Rules:
     *       1. The domain must exist (ownerOf reverts if not).
     *       2. One of (msg.sender, peer) must be the domain owner — conversations
     *          are always anchored to a domain owner.
     *       3. msg.sender and peer must be different addresses.
     *       4. Non-owner senders must not be blocked by the domain owner.
     *       5. encryptedContent is AES-GCM base64, max 4 096 bytes.
     *
     * @param domainTokenId    Token ID of the .rob domain this conversation belongs to.
     * @param peer             The other conversation participant.
     * @param encryptedContent Base64-encoded AES-GCM ciphertext.
     * @return messageId       The ID assigned to the new message.
     */
    function sendMessage(
        uint256 domainTokenId,
        address peer,
        string calldata encryptedContent
    ) external returns (uint256 messageId) {
        address domainOwner = domainNFT.ownerOf(domainTokenId); // reverts if token doesn't exist

        require(msg.sender != peer, "DomainChat: cannot message yourself");

        // Conversations must involve the domain owner as one of the two participants.
        require(
            msg.sender == domainOwner || peer == domainOwner,
            "DomainChat: conversation must involve the domain owner"
        );

        // Block check applies to non-owners (visitors) only.
        if (msg.sender != domainOwner) {
            require(
                !blocked[domainTokenId][msg.sender],
                "DomainChat: sender is blocked by this domain"
            );
        }

        require(bytes(encryptedContent).length > 0,    "DomainChat: empty message");
        require(bytes(encryptedContent).length <= 4096, "DomainChat: message exceeds 4096 bytes");

        bytes32 convId = _conversationId(msg.sender, peer);

        _messageCount++;
        messageId = _messageCount;
        _messageSender[messageId] = msg.sender;

        emit MessageSent(
            messageId,
            convId,
            domainTokenId,
            msg.sender,
            peer,
            encryptedContent,
            block.timestamp
        );
    }

    /**
     * @notice Edit a previously sent message (only the original sender may call this).
     *
     * @param messageId        The ID of the message to edit.
     * @param conversationId   The conversation this message belongs to (for indexing).
     * @param domainTokenId    The domain token (for indexing).
     * @param encryptedContent New base64-encoded AES-GCM ciphertext.
     */
    function editMessage(
        uint256 messageId,
        bytes32 conversationId,
        uint256 domainTokenId,
        string calldata encryptedContent
    ) external {
        require(
            _messageSender[messageId] == msg.sender,
            "DomainChat: caller is not the original sender"
        );
        require(!messageDeleted[messageId], "DomainChat: message already deleted");
        require(bytes(encryptedContent).length > 0,    "DomainChat: empty message");
        require(bytes(encryptedContent).length <= 4096, "DomainChat: message exceeds 4096 bytes");

        emit MessageEdited(
            messageId,
            conversationId,
            domainTokenId,
            msg.sender,
            encryptedContent,
            block.timestamp
        );
    }

    /**
     * @notice Soft-delete a message (only the original sender may call this).
     *
     * @param messageId      The ID of the message to delete.
     * @param conversationId The conversation this message belongs to (for indexing).
     * @param domainTokenId  The domain token (for indexing).
     */
    function deleteMessage(
        uint256 messageId,
        bytes32 conversationId,
        uint256 domainTokenId
    ) external {
        require(
            _messageSender[messageId] == msg.sender,
            "DomainChat: caller is not the original sender"
        );
        require(!messageDeleted[messageId], "DomainChat: already deleted");

        messageDeleted[messageId] = true;

        emit MessageDeleted(messageId, conversationId, domainTokenId, block.timestamp);
    }

    /**
     * @notice Mark a conversation as read. Only the domain owner may call this.
     *
     * @param domainTokenId   Token ID of the caller's own domain.
     * @param conversationWith Address of the other participant in the conversation.
     */
    function markAsRead(
        uint256 domainTokenId,
        address conversationWith
    ) external {
        require(
            domainNFT.ownerOf(domainTokenId) == msg.sender,
            "DomainChat: caller does not own this domain"
        );
        conversationReadAt[domainTokenId][conversationWith] = block.timestamp;

        emit ConversationRead(
            domainTokenId,
            msg.sender,
            conversationWith,
            block.timestamp
        );
    }

    /**
     * @notice Block a sender from messaging the caller's domain.
     *
     * @param tokenId Token ID of the caller's own domain.
     * @param user    Address to block.
     */
    function blockUser(uint256 tokenId, address user) external {
        require(
            domainNFT.ownerOf(tokenId) == msg.sender,
            "DomainChat: caller does not own this domain"
        );
        require(user != address(0), "DomainChat: cannot block zero address");
        require(!blocked[tokenId][user], "DomainChat: user is already blocked");

        blocked[tokenId][user] = true;

        emit UserBlocked(tokenId, user, block.timestamp);
    }

    /**
     * @notice Unblock a previously blocked sender.
     *
     * @param tokenId Token ID of the caller's own domain.
     * @param user    Address to unblock.
     */
    function unblockUser(uint256 tokenId, address user) external {
        require(
            domainNFT.ownerOf(tokenId) == msg.sender,
            "DomainChat: caller does not own this domain"
        );
        require(blocked[tokenId][user], "DomainChat: user is not blocked");

        blocked[tokenId][user] = false;

        emit UserUnblocked(tokenId, user, block.timestamp);
    }

    // ─────────────────────────────────────────────
    //  View helpers
    // ─────────────────────────────────────────────

    /**
     * @notice Check whether `user` is blocked from messaging `tokenId`.
     */
    function isBlocked(uint256 tokenId, address user) external view returns (bool) {
        return blocked[tokenId][user];
    }

    /**
     * @notice Get the unix timestamp of when the domain owner last marked
     *         the conversation with `conversationWith` as read.
     *         Returns 0 if never read.
     */
    function getReadTimestamp(
        uint256 tokenId,
        address conversationWith
    ) external view returns (uint256) {
        return conversationReadAt[tokenId][conversationWith];
    }

    /**
     * @notice Total number of messages ever sent (including deleted ones).
     */
    function getMessageCount() external view returns (uint256) {
        return _messageCount;
    }

    /**
     * @notice Address of the original sender for a given message ID.
     *         Returns address(0) for IDs that don't exist yet.
     */
    function getMessageSender(uint256 messageId) external view returns (address) {
        return _messageSender[messageId];
    }

    /**
     * @notice Compute the deterministic conversation ID for two participants.
     *         Convenience view so the frontend can verify its own derivation.
     */
    function getConversationId(address a, address b) external pure returns (bytes32) {
        return _conversationId(a, b);
    }
}
