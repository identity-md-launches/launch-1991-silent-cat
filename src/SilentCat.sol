// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Silent Cat (SCAT)
/// @notice A plain, fixed-supply ERC-20. The whole supply of 1,000,000,000 SCAT (18 decimals) is
///         minted once, in the constructor, to the deployer (`msg.sender`). Nothing can mint
///         afterwards, and there is no owner, pause, blacklist, tax or any other privileged power.
/// @dev The deployer is the launch factory, which distributes the supply (swarm share, pool seed,
///      remainder) according to the launch manifest. The constructor takes no arguments and makes
///      no external calls, so it deploys on an empty chain. Holders may burn their own tokens.
contract SilentCat is ERC20 {
    /// @notice Human-readable token name returned by `name()`.
    string public constant TOKEN_NAME = "Silent Cat";

    /// @notice Ticker returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "SCAT";

    /// @notice Number of decimals returned by `decimals()`.
    uint8 public constant DECIMALS = 18;

    /// @notice Total supply in whole tokens, before scaling by `DECIMALS`.
    uint256 public constant SUPPLY_WHOLE_TOKENS = 1_000_000_000;

    /// @notice The fixed total supply in minor units: 1,000,000,000 * 10^18.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_TOKENS * 10 ** uint256(DECIMALS);

    /// @notice Mints `TOTAL_SUPPLY` to the deployer. Called exactly once; no other mint path exists.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice Destroys `amount` of the caller's own tokens, reducing the total supply.
    /// @dev Only the caller's balance can be burned. There is no `burnFrom` and no allowance-based
    ///      burn, so nobody can reduce another holder's balance.
    /// @param amount The number of minor units to burn from `msg.sender`.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
