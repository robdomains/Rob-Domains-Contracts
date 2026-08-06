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
 * @title RobBuilderRegistry
 * @notice Fully on-chain reputation registry for Web3 freelancers building on Robinhood.
 *
 * ─── Architecture ────────────────────────────────────────────────────────────
 *
 * The existing CollectionFactory, TokenFactory, and FormFactory contracts are
 * FROZEN and NOT modified in any way. This registry reads their state via the
 * view functions they already expose:
 *
 *   CollectionFactory.getCollectionsByOwner(address) → uint256[]
 *   TokenFactory.getTokensByOwner(address)           → uint256[]
 *   FormFactory.getFormsByOwner(address)             → uint256[]
 *
 * Points, level, and stats are computed dynamically from these live counts.
 * No callbacks. No factory modifications. No event scanning.
 *
 * The only state this contract owns:
 *   • claimedBadge mapping — whether a builder has claimed their badge
 *   • registeredBuilders list — for global ranking (opt-in via register())
 *
 * Builders register by calling register() (gas-cheap) or auto-register when
 * they call claimBadge(). The dashboard frontend calls register() on first load
 * if the wallet is not yet registered.
 *
 * ─── Points formula ──────────────────────────────────────────────────────────
 *
 *   points = (collections × pointsPerCollection)
 *           + (tokens      × pointsPerToken)
 *           + (forms        × pointsPerForm)
 *
 * Values are admin-configurable. Defaults: Collection = 50, Token = 100, Form = 25.
 *
 * ─── Levels ──────────────────────────────────────────────────────────────────
 *
 *   Bronze  ≥    0 pts
 *   Silver  ≥  500 pts
 *   Gold    ≥ 1500 pts
 *   Diamond ≥ 3000 pts
 *   Legend  ≥ 6000 pts
 *
 * Configurable via setLevels() without changing storage layout.
 *
 * ─── Badge claim eligibility ─────────────────────────────────────────────────
 *
 *   Eligible when points ≥ levels[1].minPoints (Silver threshold, default 500).
 *   The Badge Contract is never touched. Only claimed = true is recorded here.
 *
 * ─── Ranking ─────────────────────────────────────────────────────────────────
 *
 *   getBuilderRank(address) iterates registered builders, computing each one's
 *   points dynamically. Rank 1 = most points.
 *   getTopBuilders(limit) returns the top N sorted descending.
 *
 * Constructor args:
 *   domainContract_    — DomainNFT address (balanceOf, for domain check)
 *   collectionFactory_ — CollectionFactory address (read-only)
 *   tokenFactory_      — TokenFactory address       (read-only)
 *   formsFactory_      — FormFactory address         (read-only)
 */

// ─────────────────────────────────────────────────────────────────────────────
//  Read-only interfaces for the FROZEN factory contracts
// ─────────────────────────────────────────────────────────────────────────────

interface ICollectionFactory {
    function getCollectionsByOwner(address owner) external view returns (uint256[] memory);
}

interface ITokenFactory {
    function getTokensByOwner(address owner) external view returns (uint256[] memory);
}

interface IFormFactory {
    function getFormsByOwner(address owner) external view returns (uint256[] memory);
}

interface IDomainNFT {
    function balanceOf(address owner) external view returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Contract
// ─────────────────────────────────────────────────────────────────────────────

contract RobBuilderRegistry {

    // ─────────────────────────────────────────────────────────────────────────
    //  Admin
    // ─────────────────────────────────────────────────────────────────────────

    address public immutable admin;

    // ─────────────────────────────────────────────────────────────────────────
    //  Immutable references to the frozen factory contracts (read-only)
    // ─────────────────────────────────────────────────────────────────────────

    IDomainNFT         public immutable domainContract;
    ICollectionFactory public immutable collectionFactory;
    ITokenFactory      public immutable tokenFactory;
    IFormFactory       public immutable formsFactory;

    // ─────────────────────────────────────────────────────────────────────────
    //  Configurable point values
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public pointsPerCollection = 50;
    uint256 public pointsPerToken      = 30;
    uint256 public pointsPerForm       = 20;

    // ─────────────────────────────────────────────────────────────────────────
    //  Configurable levels (sorted ascending by minPoints)
    // ─────────────────────────────────────────────────────────────────────────

    struct LevelConfig {
        string  name;
        uint256 minPoints;
    }

    LevelConfig[] public levels;

    // ─────────────────────────────────────────────────────────────────────────
    //  Per-builder state (only what cannot be derived from the factories)
    // ─────────────────────────────────────────────────────────────────────────

    mapping(address => bool) private _claimedBadge;
    mapping(address => bool) private _isRegistered;
    address[]                private _allBuilders;

    // ─────────────────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────────────────

    event BuilderRegistered   (address indexed builder);
    event BadgeClaimed        (address indexed builder);
    event PointsConfigUpdated (uint256 collectionPoints, uint256 tokenPoints, uint256 formPoints);
    event LevelsUpdated       (uint256 levelCount);

    // ─────────────────────────────────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        require(msg.sender == admin, "RobBuilderRegistry: not admin");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(
        address domainContract_,
        address collectionFactory_,
        address tokenFactory_,
        address formsFactory_
    ) {
        require(domainContract_    != address(0), "RobBuilderRegistry: zero domain");
        require(collectionFactory_ != address(0), "RobBuilderRegistry: zero collection factory");
        require(tokenFactory_      != address(0), "RobBuilderRegistry: zero token factory");
        require(formsFactory_      != address(0), "RobBuilderRegistry: zero forms factory");

        admin             = msg.sender;
        domainContract    = IDomainNFT(domainContract_);
        collectionFactory = ICollectionFactory(collectionFactory_);
        tokenFactory      = ITokenFactory(tokenFactory_);
        formsFactory      = IFormFactory(formsFactory_);

        // Default levels — configurable via setLevels()
        levels.push(LevelConfig({ name: "Bronze",  minPoints: 0    }));
        levels.push(LevelConfig({ name: "Silver",  minPoints: 500  }));
        levels.push(LevelConfig({ name: "Gold",    minPoints: 1500 }));
        levels.push(LevelConfig({ name: "Diamond", minPoints: 3000 }));
        levels.push(LevelConfig({ name: "Legend",  minPoints: 6000 }));
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Compute total points for any address by reading the frozen factories.
    function _pointsFor(address builder) internal view returns (uint256) {
        uint256 collections = collectionFactory.getCollectionsByOwner(builder).length;
        uint256 tokens      = tokenFactory.getTokensByOwner(builder).length;
        uint256 forms       = formsFactory.getFormsByOwner(builder).length;
        return (collections * pointsPerCollection)
             + (tokens      * pointsPerToken)
             + (forms        * pointsPerForm);
    }

    /// @dev Returns the level index (0-based) for a given point total.
    function _levelIndexFor(uint256 pts) internal view returns (uint256 idx) {
        idx = 0;
        for (uint256 i = 1; i < levels.length; i++) {
            if (pts >= levels[i].minPoints) {
                idx = i;
            } else {
                break;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Write — registration
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Opt-in to the global ranking system.
     *         The frontend calls this on first visit so the builder appears in leaderboards.
     *         Safe to call multiple times — idempotent.
     */
    function register() external {
        if (!_isRegistered[msg.sender]) {
            _isRegistered[msg.sender] = true;
            _allBuilders.push(msg.sender);
            emit BuilderRegistered(msg.sender);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Write — badge claim
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Claim the Builder Badge once the Silver threshold is reached.
     *         Eligibility = points ≥ levels[1].minPoints (default 500).
     *         Auto-registers the builder in the ranking system.
     *         The Badge Contract is never touched — only claimed = true is stored here.
     */
    function claimBadge() external {
        require(!_claimedBadge[msg.sender], "RobBuilderRegistry: badge already claimed");

        uint256 pts       = _pointsFor(msg.sender);
        uint256 threshold = levels.length > 1 ? levels[1].minPoints : 500;
        require(pts >= threshold, "RobBuilderRegistry: not eligible yet");

        _claimedBadge[msg.sender] = true;

        // Auto-register for ranking
        if (!_isRegistered[msg.sender]) {
            _isRegistered[msg.sender] = true;
            _allBuilders.push(msg.sender);
            emit BuilderRegistered(msg.sender);
        }

        emit BadgeClaimed(msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Read — builder stats (all computed from factory view reads)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Full live stats for a builder, computed by reading the frozen factories.
     */
    function getBuilderStats(address builder)
        external
        view
        returns (
            uint256 collectionsCreated,
            uint256 tokensCreated,
            uint256 formsCreated,
            uint256 points,
            bool    claimedBadge,
            bool    registered
        )
    {
        collectionsCreated = collectionFactory.getCollectionsByOwner(builder).length;
        tokensCreated      = tokenFactory.getTokensByOwner(builder).length;
        formsCreated       = formsFactory.getFormsByOwner(builder).length;
        points             = (collectionsCreated * pointsPerCollection)
                           + (tokensCreated      * pointsPerToken)
                           + (formsCreated        * pointsPerForm);
        claimedBadge       = _claimedBadge[builder];
        registered         = _isRegistered[builder];
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Read — level
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Current level name and index for a builder.
    function getCurrentLevel(address builder)
        external
        view
        returns (string memory levelName, uint256 levelIndex)
    {
        uint256 pts = _pointsFor(builder);
        levelIndex  = _levelIndexFor(pts);
        levelName   = levels[levelIndex].name;
    }

    /// @notice Points needed for the next level, and whether the builder is at max.
    function getNextLevelThreshold(address builder)
        external
        view
        returns (uint256 nextPoints, bool isMaxLevel)
    {
        uint256 pts = _pointsFor(builder);
        uint256 idx = _levelIndexFor(pts);

        if (idx >= levels.length - 1) {
            return (levels[levels.length - 1].minPoints, true);
        }
        return (levels[idx + 1].minPoints, false);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Read — global ranking
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Total number of registered builders.
    function getBuilderCount() external view returns (uint256) {
        return _allBuilders.length;
    }

    /**
     * @notice 1-based global rank of a builder (rank 1 = most points).
     *         Points are computed live from the frozen factories.
     */
    function getBuilderRank(address builder) external view returns (uint256 rank) {
        uint256 pts = _pointsFor(builder);
        rank = 1;
        uint256 len = _allBuilders.length;
        for (uint256 i = 0; i < len; i++) {
            address b = _allBuilders[i];
            if (b != builder && _pointsFor(b) > pts) {
                rank++;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Read — top builders
    // ─────────────────────────────────────────────────────────────────────────

    struct BuilderInfo {
        address builder;
        uint256 points;
        uint256 collectionsCreated;
        uint256 tokensCreated;
        uint256 formsCreated;
        bool    claimedBadge;
    }

    /**
     * @notice Returns the top `limit` builders sorted by points descending.
     *         Points are computed live from the frozen factories.
     *         Uses selection sort — suitable for registries up to a few thousand addresses.
     */
    function getTopBuilders(uint256 limit)
        external
        view
        returns (BuilderInfo[] memory result)
    {
        uint256 total = _allBuilders.length;
        if (limit > total) limit = total;
        if (limit == 0) return result;

        // Copy addresses and precompute points into parallel arrays
        address[] memory addrs  = new address[](total);
        uint256[] memory pts    = new uint256[](total);
        for (uint256 i = 0; i < total; i++) {
            addrs[i] = _allBuilders[i];
            pts[i]   = _pointsFor(_allBuilders[i]);
        }

        // Selection sort top `limit` entries
        for (uint256 i = 0; i < limit; i++) {
            uint256 maxIdx = i;
            for (uint256 j = i + 1; j < total; j++) {
                if (pts[j] > pts[maxIdx]) maxIdx = j;
            }
            if (maxIdx != i) {
                address tmpA = addrs[i]; addrs[i] = addrs[maxIdx]; addrs[maxIdx] = tmpA;
                uint256 tmpP = pts[i];   pts[i]   = pts[maxIdx];   pts[maxIdx]   = tmpP;
            }
        }

        result = new BuilderInfo[](limit);
        for (uint256 i = 0; i < limit; i++) {
            address b = addrs[i];
            uint256 c = collectionFactory.getCollectionsByOwner(b).length;
            uint256 t = tokenFactory.getTokensByOwner(b).length;
            uint256 f = formsFactory.getFormsByOwner(b).length;
            result[i] = BuilderInfo({
                builder:            b,
                points:             pts[i],
                collectionsCreated: c,
                tokensCreated:      t,
                formsCreated:       f,
                claimedBadge:       _claimedBadge[b]
            });
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Read — domain ownership (used by UI for badge visibility)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns true if `wallet` currently owns at least one .rob domain.
    function hasDomain(address wallet) external view returns (bool) {
        return domainContract.balanceOf(wallet) > 0;
    }

    /// @notice Returns true if `wallet` has claimed the badge AND currently owns a domain.
    function builderBadgeVisible(address wallet) external view returns (bool) {
        return _claimedBadge[wallet] && domainContract.balanceOf(wallet) > 0;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Read — levels
    // ─────────────────────────────────────────────────────────────────────────

    function getLevelCount() external view returns (uint256) {
        return levels.length;
    }

    function getLevel(uint256 index)
        external
        view
        returns (string memory name, uint256 minPoints)
    {
        require(index < levels.length, "RobBuilderRegistry: out of bounds");
        return (levels[index].name, levels[index].minPoints);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Admin — configure points
    // ─────────────────────────────────────────────────────────────────────────

    function setPointsConfig(
        uint256 collectionPoints_,
        uint256 tokenPoints_,
        uint256 formPoints_
    ) external onlyAdmin {
        require(collectionPoints_ > 0, "RobBuilderRegistry: zero collection points");
        require(tokenPoints_      > 0, "RobBuilderRegistry: zero token points");
        require(formPoints_       > 0, "RobBuilderRegistry: zero form points");
        pointsPerCollection = collectionPoints_;
        pointsPerToken      = tokenPoints_;
        pointsPerForm       = formPoints_;
        emit PointsConfigUpdated(collectionPoints_, tokenPoints_, formPoints_);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Admin — configure levels
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Replace the entire level table.
     *         `names` and `minPoints_` must have equal length, sorted ascending.
     *         Storage layout is unchanged — only the dynamic `levels` array is rewritten.
     */
    function setLevels(
        string[]  calldata names,
        uint256[] calldata minPoints_
    ) external onlyAdmin {
        require(names.length == minPoints_.length, "RobBuilderRegistry: length mismatch");
        require(names.length > 0,                  "RobBuilderRegistry: empty levels");
        uint256 existing = levels.length;
        for (uint256 i = 0; i < existing; i++) levels.pop();
        for (uint256 i = 0; i < names.length; i++) {
            levels.push(LevelConfig({ name: names[i], minPoints: minPoints_[i] }));
        }
        emit LevelsUpdated(names.length);
    }
}
