// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SilentCat} from "../src/SilentCat.sol";

/// @notice A deployer that is a contract, to show the supply goes to `msg.sender` of the
///         constructor (the launch factory), not to any EOA or `tx.origin`.
contract FactoryStandIn {
    function deploy() external returns (SilentCat) {
        return new SilentCat();
    }

    function send(SilentCat token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract SilentCatTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    SilentCat internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.prank(deployer);
        token = new SilentCat();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Silent Cat");
        assertEq(token.symbol(), "SCAT");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Silent Cat");
        assertEq(token.TOKEN_SYMBOL(), "SCAT");
        assertEq(token.DECIMALS(), 18);
    }

    function test_totalSupplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.SUPPLY_WHOLE_TOKENS(), 1_000_000_000);
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), deployer, EXPECTED_SUPPLY);
        vm.prank(deployer);
        new SilentCat();
    }

    /// @dev The launch factory is a contract; the supply must land on it, not on tx.origin.
    function test_contractDeployerReceivesSupplyNotTxOrigin() public {
        FactoryStandIn factory = new FactoryStandIn();
        address origin = makeAddr("origin");
        vm.prank(origin, origin);
        SilentCat deployed = factory.deploy();
        assertEq(deployed.balanceOf(address(factory)), EXPECTED_SUPPLY);
        assertEq(deployed.balanceOf(origin), 0);
        assertEq(deployed.totalSupply(), EXPECTED_SUPPLY);
        // The factory can then pay the supply out whole.
        assertTrue(factory.send(deployed, alice, EXPECTED_SUPPLY / 10));
        assertEq(deployed.balanceOf(alice), EXPECTED_SUPPLY / 10);
    }

    function test_creationCodeHasNoConstructorArguments() public {
        // Deploying the raw creation code with nothing appended succeeds and mints the same supply.
        bytes memory code = type(SilentCat).creationCode;
        address created;
        assembly ("memory-safe") {
            created := create(0, add(code, 32), mload(code))
        }
        assertTrue(created != address(0));
        assertEq(SilentCat(created).totalSupply(), EXPECTED_SUPPLY);
        assertEq(SilentCat(created).balanceOf(address(this)), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers (success)
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        uint256 amount = 1_234e18;
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, amount);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, EXPECTED_SUPPLY));
        assertEq(token.balanceOf(alice), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5e18));
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_approveAndTransferFrom() public {
        uint256 amount = 100e18;
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, alice, amount);
        assertTrue(token.approve(alice, amount));
        assertEq(token.allowance(deployer, alice), amount);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, amount));
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.allowance(deployer, alice), 0);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1e18);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers (failure)
    // ---------------------------------------------------------------------------------------------

    function test_transferRevertsWhenBalanceInsufficient() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferRevertsOnOneMoreThanBalance() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, deployer, EXPECTED_SUPPLY, EXPECTED_SUPPLY + 1
            )
        );
        token.transfer(alice, EXPECTED_SUPPLY + 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFromRevertsWhenAllowanceTooSmall() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 10, 11));
        token.transferFrom(deployer, bob, 11);
    }

    function test_transferFromRevertsWhenOwnerBalanceInsufficient() public {
        vm.prank(alice);
        token.approve(bob, 100);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 100));
        token.transferFrom(alice, bob, 100);
    }

    function test_approveZeroSpenderReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Burn
    // ---------------------------------------------------------------------------------------------

    function test_burnReducesHolderBalanceAndSupply() public {
        uint256 amount = 42e18;
        vm.prank(deployer);
        token.transfer(alice, amount);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(alice, address(0), amount);
        token.burn(amount);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY - amount);
    }

    function test_burnRevertsWhenBalanceInsufficient() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.burn(1);
    }

    function test_burnOnlyAffectsCaller() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(deployer);
        token.burn(1e18);
        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 11e18);
    }

    // ---------------------------------------------------------------------------------------------
    // No privileged surface: no mint, no owner, no pause, no blacklist, no burnFrom
    // ---------------------------------------------------------------------------------------------

    function test_noAdminSelectorIncreasesSupplyOrMovesBalances() public {
        vm.prank(deployer);
        token.transfer(alice, 1_000e18);
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 supplyBefore = token.totalSupply();

        string[20] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "owner()"
        ];
        address[2] memory callers = [deployer, address(0xBEEF)];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < signatures.length; ++i) {
                bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.balanceOf(alice), aliceBefore);
        assertEq(token.balanceOf(address(0xBEEF)), 0);

        // Alice can still move her tokens afterwards.
        vm.prank(alice);
        assertTrue(token.transfer(bob, aliceBefore));
        assertEq(token.balanceOf(bob), aliceBefore);
    }

    function test_deployerCannotPullFromHolderWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 50e18);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_noEtherAccepted() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: conservation of supply and exact delivery
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferDeliversExactly(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 amount) public {
        amount = bound(amount, EXPECTED_SUPPLY + 1, type(uint256).max);
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, EXPECTED_SUPPLY, amount)
        );
        token.transfer(alice, amount);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 spent) public {
        allowed = bound(allowed, 0, EXPECTED_SUPPLY);
        spent = bound(spent, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        if (spent > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowed, spent)
            );
            token.transferFrom(deployer, bob, spent);
        } else {
            assertTrue(token.transferFrom(deployer, bob, spent));
            assertEq(token.balanceOf(bob), spent);
            assertEq(token.allowance(deployer, alice), allowed - spent);
        }
    }

    function testFuzz_burnConservesOtherBalances(uint256 give, uint256 burnAmount) public {
        give = bound(give, 0, EXPECTED_SUPPLY);
        burnAmount = bound(burnAmount, 0, give);
        vm.prank(deployer);
        token.transfer(alice, give);
        vm.prank(alice);
        token.burn(burnAmount);
        assertEq(token.balanceOf(alice), give - burnAmount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - give);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY - burnAmount);
    }
}
