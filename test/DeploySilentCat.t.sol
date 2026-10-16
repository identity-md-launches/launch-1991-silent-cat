// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeploySilentCat} from "../script/DeploySilentCat.s.sol";
import {SilentCat} from "../src/SilentCat.sol";

contract DeploySilentCatTest is Test {
    function test_deployMintsSupplyToTheScriptContract() public {
        DeploySilentCat deployer = new DeploySilentCat();
        SilentCat token = deployer.deploy();
        assertEq(token.name(), "Silent Cat");
        assertEq(token.symbol(), "SCAT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 * 1e18);
        // Whoever creates the contract holds the supply: here the script contract itself.
        assertEq(token.balanceOf(address(deployer)), 1_000_000_000 * 1e18);
    }
}
