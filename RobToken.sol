// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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
 * @title RobToken
 * @notice Standard ERC20 token deployed by TokenFactory.
 *
 * Design rules (enforced, not optional):
 *   - Fixed 18 decimals (ERC20 default).
 *   - Entire supply minted to the creator wallet at deploy time — no further minting.
 *   - No owner, no admin, no upgradeability, no proxy.
 *   - No taxes, no fees, no burn logic, no liquidity hooks.
 *   - Fully compatible with any wallet, DEX, or exchange that supports ERC20.
 */
contract RobToken is ERC20 {
    /**
     * @param name_        Human-readable token name (e.g. "My Token").
     * @param symbol_      Ticker symbol (e.g. "MTK").
     * @param totalSupply_ Supply in whole tokens (e.g. 1_000_000_000).
     *                     Internally multiplied by 10^18 to account for decimals.
     * @param creator      Address that receives the entire minted supply.
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address creator
    ) ERC20(name_, symbol_) {
        // Multiply by decimals factor so the user-facing number stays clean.
        _mint(creator, totalSupply_ * (10 ** decimals()));
    }
}
