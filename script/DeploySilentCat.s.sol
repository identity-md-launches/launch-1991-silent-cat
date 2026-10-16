// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SilentCat} from "../src/SilentCat.sol";

/// @title Deploy script for Silent Cat (SCAT)
/// @notice Reference deployment for local or self-hosted use. The IdentityMD launch does not run
///         this script: its factory deploys the token from the built bytecode. The token takes no
///         constructor arguments, so there is no configuration to read from the environment.
/// @dev `deploy()` is the unit tests' entry point. `run()` is the broadcast wrapper.
contract DeploySilentCat is Script {
    /// @notice Deploys a fresh `SilentCat`. The caller of this function's creation receives the supply.
    function deploy() public returns (SilentCat token) {
        token = new SilentCat();
    }

    /// @notice Broadcast entry point: `forge script script/DeploySilentCat.s.sol --broadcast`.
    function run() external returns (SilentCat token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
