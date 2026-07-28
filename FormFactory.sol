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
 * @title FormFactory
 * @notice On-chain registry for Gateway Forms.
 *         Stores form metadata only — responses are stored off-chain (encrypted JSON files).
 *         Form IDs are incremental: 1, 2, 3, …
 */
contract FormFactory {
    // ─────────────────────────────────────────────────────────────────────────
    //  Enums
    // ─────────────────────────────────────────────────────────────────────────

    enum FormStatus { Active, Closed, Archived }

    // ─────────────────────────────────────────────────────────────────────────
    //  Structs
    // ─────────────────────────────────────────────────────────────────────────

    struct Form {
        uint256 id;
        address owner;
        uint256 createdAt;
        FormStatus status;
        string schemaHash;   // keccak256 of the JSON schema, for integrity checks
        string title;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────────────────

    uint256 private _nextId = 1;

    mapping(uint256 => Form) private _forms;

    /// @dev All form IDs owned by an address
    mapping(address => uint256[]) private _ownerForms;

    // ─────────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────────

    event FormCreated(uint256 indexed id, address indexed owner, string title);
    event FormClosed(uint256 indexed id);
    event FormArchived(uint256 indexed id);
    event FormSchemaUpdated(uint256 indexed id, string newHash);
    event FormActivated(uint256 indexed id);

    // ─────────────────────────────────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyOwner(uint256 formId) {
        require(_forms[formId].owner == msg.sender, "FormFactory: not owner");
        _;
    }

    modifier formExists(uint256 formId) {
        require(_forms[formId].owner != address(0), "FormFactory: form not found");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Write functions
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Create a new form. Returns the new form ID.
     * @param title       Human-readable title stored on-chain.
     * @param schemaHash  keccak256 hash of the form schema JSON (stored off-chain).
     */
    function createForm(string calldata title, string calldata schemaHash)
        external
        returns (uint256 formId)
    {
        formId = _nextId++;

        _forms[formId] = Form({
            id:         formId,
            owner:      msg.sender,
            createdAt:  block.timestamp,
            status:     FormStatus.Active,
            schemaHash: schemaHash,
            title:      title
        });

        _ownerForms[msg.sender].push(formId);

        emit FormCreated(formId, msg.sender, title);
    }

    /**
     * @notice Close a form — no new responses accepted.
     */
    function closeForm(uint256 formId)
        external
        formExists(formId)
        onlyOwner(formId)
    {
        _forms[formId].status = FormStatus.Closed;
        emit FormClosed(formId);
    }

    /**
     * @notice Archive a form.
     */
    function archiveForm(uint256 formId)
        external
        formExists(formId)
        onlyOwner(formId)
    {
        _forms[formId].status = FormStatus.Archived;
        emit FormArchived(formId);
    }

    /**
     * @notice Re-activate a closed/archived form.
     */
    function activateForm(uint256 formId)
        external
        formExists(formId)
        onlyOwner(formId)
    {
        _forms[formId].status = FormStatus.Active;
        emit FormActivated(formId);
    }

    /**
     * @notice Update the schema hash (e.g. after editing the form fields).
     */
    function updateSchemaHash(uint256 formId, string calldata newHash)
        external
        formExists(formId)
        onlyOwner(formId)
    {
        _forms[formId].schemaHash = newHash;
        emit FormSchemaUpdated(formId, newHash);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Read functions
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Get a form by ID.
     */
    function getForm(uint256 formId)
        external
        view
        formExists(formId)
        returns (Form memory)
    {
        return _forms[formId];
    }

    /**
     * @notice Get all form IDs owned by an address.
     */
    function getFormsByOwner(address owner)
        external
        view
        returns (uint256[] memory)
    {
        return _ownerForms[owner];
    }

    /**
     * @notice Total number of forms created (≡ last issued ID).
     */
    function totalForms() external view returns (uint256) {
        return _nextId - 1;
    }
}
