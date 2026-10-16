// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SilentCat} from "../src/SilentCat.sol";

/// @notice Stands in for the launch factory: deploys the token with CREATE2 in a single call, holds
///         the supply, and pays it out the way the launch does (swarm share to the distributor, pool
///         seed to the pool manager, remainder to the requester). Only the test may drive it.
contract FactoryProbe {
    address private immutable controller = msg.sender;

    modifier onlyController() {
        require(msg.sender == controller, "not the test");
        _;
    }

    function deploy(bytes32 salt) external onlyController returns (address deployed) {
        deployed = _deploy(salt);
    }

    function _deploy(bytes32 salt) internal returns (address deployed) {
        bytes memory code = type(SilentCat).creationCode;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    /// @dev Deploys and pays out all three launch flows in one transaction, as `launchCustom` does.
    function deployAndDistribute(bytes32 salt, address distributor, address pool, address requester, uint256 poolBps)
        external
        onlyController
        returns (SilentCat token)
    {
        token = SilentCat(_deploy(salt));
        uint256 supply = token.totalSupply();
        uint256 swarm = (supply * 1_000) / 10_000;
        uint256 seed = (supply * poolBps) / 10_000;
        require(token.transfer(distributor, swarm), "swarm transfer returned false");
        require(token.transfer(pool, seed), "seed transfer returned false");
        require(token.transfer(requester, supply - swarm - seed), "remainder transfer returned false");
    }

    function move(SilentCat token, address to, uint256 amount) external onlyController returns (bool) {
        return token.transfer(to, amount);
    }

    function exec(address target, bytes calldata data) external onlyController returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call(data);
    }
}

/// @notice The launch flows and the post-launch guarantees, driven from a factory contract rather
///         than from an EOA, with exact-delivery assertions on every leg. Mirrors what the launch
///         floor checks, without the pool manager: the token makes no external calls and has no
///         exemptions, so what reaches the pool is a plain transfer like any other.
contract SilentCatLaunchFlowTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 internal constant SWARM_BPS = 1_000;
    uint256 internal constant POOL_BPS = 8_000;

    FactoryProbe internal factory;
    SilentCat internal token;

    address internal distributor = makeAddr("distributor");
    address internal pool = makeAddr("pool");
    address internal requester = makeAddr("requester");
    address internal claimant = makeAddr("claimant");
    address internal holder = makeAddr("holder");
    address internal other = makeAddr("other");
    address internal trader = makeAddr("trader");

    function setUp() public {
        factory = new FactoryProbe();
        token = SilentCat(factory.deploy(bytes32(uint256(1))));
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment through a factory
    // ---------------------------------------------------------------------------------------------

    function test_create2DeploymentMintsWholeSupplyToFactory() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(tx.origin), 0);
    }

    function test_create2AddressIsPredictableFromCreationCodeAlone() public {
        bytes32 salt = bytes32(uint256(42));
        bytes32 codeHash = keccak256(type(SilentCat).creationCode);
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, codeHash)))));
        address deployed = factory.deploy(salt);
        assertEq(deployed, predicted, "creation code is not deterministic");
        assertEq(SilentCat(deployed).balanceOf(address(factory)), SUPPLY);
    }

    function test_redeployingWithSameSaltFails() public {
        vm.expectRevert(bytes("constructor failed"));
        factory.deploy(bytes32(uint256(1)));
    }

    function test_twoDeploymentsAreIndependentTokens() public {
        SilentCat second = SilentCat(factory.deploy(bytes32(uint256(2))));
        assertTrue(address(second) != address(token));
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        // Burning on one does not touch the other.
        vm.prank(address(factory));
        second.burn(1e18);
        assertEq(second.totalSupply(), SUPPLY - 1e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Launch flows: exact delivery on every leg, in one transaction
    // ---------------------------------------------------------------------------------------------

    function test_allThreeLaunchFlowsArriveWholeInOneTransaction() public {
        SilentCat launched = factory.deployAndDistribute(bytes32(uint256(7)), distributor, pool, requester, POOL_BPS);
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 seed = (SUPPLY * POOL_BPS) / 10_000;
        uint256 remainder = SUPPLY - swarm - seed;

        assertEq(launched.balanceOf(distributor), swarm, "swarm share arrived short");
        assertEq(launched.balanceOf(pool), seed, "pool seed arrived short");
        assertEq(launched.balanceOf(requester), remainder, "remainder arrived short");
        assertEq(launched.balanceOf(address(factory)), 0, "factory kept something back");
        assertEq(launched.totalSupply(), SUPPLY, "launch flows changed the supply");
        assertEq(swarm + seed + remainder, SUPPLY);
        assertEq(swarm, 100_000_000e18);
        assertEq(seed, 800_000_000e18);
        assertEq(remainder, 100_000_000e18);
    }

    function test_swarmShareIsClaimableWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        assertTrue(factory.move(token, distributor, swarm));
        assertEq(token.balanceOf(distributor), swarm);

        vm.prank(distributor);
        assertTrue(token.transfer(claimant, swarm));
        assertEq(token.balanceOf(claimant), swarm, "claim arrived short");
        assertEq(token.balanceOf(distributor), 0, "distributor kept something back");
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Many claimants: equal shares plus the dust to the last one must empty the distributor
    ///      exactly. A fee or rounding on transfer would leave the last claimant short.
    function testFuzz_manyClaimsEmptyTheDistributorExactly(uint8 claimants) public {
        uint256 n = bound(claimants, 1, 64);
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        factory.move(token, distributor, swarm);

        uint256 each = swarm / n;
        uint256 paid;
        for (uint256 i; i < n; ++i) {
            address who = address(uint160(0x1000 + i));
            uint256 amount = i == n - 1 ? swarm - paid : each;
            vm.prank(distributor);
            assertTrue(token.transfer(who, amount));
            assertEq(token.balanceOf(who), amount, "a claim arrived short");
            paid += amount;
        }
        assertEq(paid, swarm);
        assertEq(token.balanceOf(distributor), 0, "the distributor kept dust");
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev A trader buys from the pool and sells everything back: both legs exact, pool whole again.
    function testFuzz_traderBuysAndSellsBackExactly(uint256 bought) public {
        uint256 seed = (SUPPLY * POOL_BPS) / 10_000;
        factory.move(token, pool, seed);
        bought = bound(bought, 1, seed);

        vm.prank(pool);
        assertTrue(token.transfer(trader, bought));
        assertEq(token.balanceOf(trader), bought, "the trader received short");
        assertEq(token.balanceOf(pool), seed - bought);

        vm.prank(trader);
        assertTrue(token.transfer(pool, bought));
        assertEq(token.balanceOf(trader), 0, "the trader could not sell everything");
        assertEq(token.balanceOf(pool), seed, "the pool is not whole again");
    }

    /// @dev The pool manager pulls with transferFrom after an approval, as v4 settlement does
    ///      through a router: exact, and the allowance is spent exactly.
    function testFuzz_pullThroughAllowanceIsExact(uint256 approved, uint256 pulled) public {
        uint256 seed = (SUPPLY * POOL_BPS) / 10_000;
        factory.move(token, trader, seed);
        approved = bound(approved, 1, seed);
        pulled = bound(pulled, 1, approved);

        vm.prank(trader);
        token.approve(pool, approved);
        vm.prank(pool);
        assertTrue(token.transferFrom(trader, pool, pulled));
        assertEq(token.balanceOf(pool), pulled);
        assertEq(token.balanceOf(trader), seed - pulled);
        assertEq(token.allowance(trader, pool), approved - pulled);
    }

    /// @dev Any split of the supply among the three launch recipients conserves it exactly.
    function testFuzz_anySplitConservesSupply(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        uint256 c = SUPPLY - a - b;
        assertTrue(factory.move(token, distributor, a));
        assertTrue(factory.move(token, pool, b));
        assertTrue(factory.move(token, requester, c));
        assertEq(token.balanceOf(distributor) + token.balanceOf(pool) + token.balanceOf(requester), SUPPLY);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev A round trip through several hands returns everyone to where they started.
    function testFuzz_roundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        factory.move(token, holder, amount);
        vm.prank(holder);
        token.transfer(other, amount);
        vm.prank(other);
        token.transfer(trader, amount);
        vm.prank(trader);
        token.transfer(holder, amount);
        assertEq(token.balanceOf(holder), amount);
        assertEq(token.balanceOf(other), 0);
        assertEq(token.balanceOf(trader), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // The factory, the most plausibly trusted address, has no power over holders after launch
    // ---------------------------------------------------------------------------------------------

    function test_factoryCannotMoveOrFreezeAHolder() public {
        uint256 held = SUPPLY / 1_000;
        factory.move(token, holder, held);

        string[13] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "renounceOwnership()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = factory.exec(address(token), abi.encodeWithSignature(signatures[i], holder, true));
            assertFalse(ok, signatures[i]);
        }
        (bool moved,) = factory.exec(
            address(token), abi.encodeWithSelector(IERC20.transferFrom.selector, holder, address(factory), 1)
        );
        assertFalse(moved, "the factory pulled from a holder without allowance");
        assertEq(token.balanceOf(holder), held, "a privileged call moved the holder's balance");

        vm.prank(holder);
        assertTrue(token.transfer(other, held / 2), "the holder can no longer transfer");
        assertEq(token.balanceOf(other), held / 2);
    }

    function test_factoryCannotMintAfterLaunch() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setMinter(address)",
            "_mint(address,uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = factory.exec(
                address(token), abi.encodeWithSignature(signatures[i], address(factory), type(uint128).max)
            );
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_unknownSelectorsAndEmptyCalldataRevert() public {
        (bool ok,) = factory.exec(address(token), "");
        assertFalse(ok, "empty calldata did not revert");
        (ok,) = factory.exec(address(token), hex"deadbeef");
        assertFalse(ok, "unknown selector did not revert");
        (ok,) = factory.exec(address(token), hex"a9");
        assertFalse(ok, "short calldata did not revert");
    }

    /// @dev A constructor that reads anything from the chain, or calls out, would differ here.
    function test_constructorMakesNoExternalCallsAndNeedsNoState() public {
        // Deploy on a fresh, bare address space: the only state the constructor touches is its own.
        vm.record();
        SilentCat fresh = new SilentCat();
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(fresh));
        // OZ ERC20 layout: _balances (0), _allowances (1), _totalSupply (2), _name (3), _symbol (4).
        // The constructor writes exactly name, symbol, totalSupply and the deployer's balance.
        assertEq(writes.length, 4, "constructor wrote an unexpected number of slots");
        bool sawName;
        bool sawSymbol;
        bool sawSupply;
        bool sawBalance;
        bytes32 balanceSlot = keccak256(abi.encode(address(this), uint256(0)));
        for (uint256 i; i < writes.length; ++i) {
            if (writes[i] == bytes32(uint256(3))) sawName = true;
            else if (writes[i] == bytes32(uint256(4))) sawSymbol = true;
            else if (writes[i] == bytes32(uint256(2))) sawSupply = true;
            else if (writes[i] == balanceSlot) sawBalance = true;
            else assertTrue(false, "constructor wrote an unexpected slot");
        }
        assertTrue(sawName && sawSymbol && sawSupply && sawBalance, "constructor missed a slot");
        // It reads nothing it did not just write (no oracle, no registry, no factory call).
        for (uint256 i; i < reads.length; ++i) {
            assertTrue(
                reads[i] == bytes32(uint256(2)) || reads[i] == balanceSlot || reads[i] == bytes32(uint256(3))
                    || reads[i] == bytes32(uint256(4)),
                "constructor read an unexpected slot"
            );
        }
        assertEq(fresh.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Edge cases around the boundaries of the supply
    // ---------------------------------------------------------------------------------------------

    function test_burnWholeSupplyThenZeroValueOperationsStillWork() public {
        vm.prank(address(factory));
        token.burn(SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(address(factory)), 0);

        vm.prank(address(factory));
        assertTrue(token.transfer(holder, 0));
        vm.prank(address(factory));
        token.burn(0);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0, 1));
        token.transfer(other, 1);
        assertEq(token.totalSupply(), 0);
    }

    function test_burnZeroEmitsTransferToZero() public {
        vm.prank(holder);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(holder, address(0), 0);
        token.burn(0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnOneWeiAtATimeIsExact() public {
        factory.move(token, holder, 3);
        for (uint256 i; i < 3; ++i) {
            vm.prank(holder);
            token.burn(1);
        }
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.totalSupply(), SUPPLY - 3);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0, 1));
        token.burn(1);
    }

    function test_burnDoesNotRequireOrConsumeAllowance() public {
        factory.move(token, holder, 10e18);
        vm.prank(holder);
        token.approve(other, 5e18);
        vm.prank(holder);
        token.burn(10e18);
        assertEq(token.allowance(holder, other), 5e18, "burn touched an allowance");
        // The allowance outlives the balance but cannot be spent.
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0, 1));
        token.transferFrom(holder, other, 1);
    }

    function test_burnedTokensCannotBeRecoveredByAnyone() public {
        vm.prank(address(factory));
        token.burn(1e18);
        // No selector gives them back; the supply is permanently lower.
        (bool ok,) =
            factory.exec(address(token), abi.encodeWithSignature("mint(address,uint256)", address(factory), 1e18));
        assertFalse(ok);
        assertEq(token.totalSupply(), SUPPLY - 1e18);
        assertEq(token.balanceOf(address(0)), 0, "burned tokens sit at the zero address");
    }

    function test_transferToTokenContractIsAllowedAndStranded() public {
        // Nothing in the token forbids it and nothing can recover it: documented, so asserted.
        assertTrue(factory.move(token, address(token), 1e18));
        assertEq(token.balanceOf(address(token)), 1e18);
        (bool ok,) =
            factory.exec(address(token), abi.encodeWithSignature("recover(address,uint256)", address(factory), 1e18));
        assertFalse(ok);
        (ok,) = factory.exec(
            address(token), abi.encodeWithSignature("rescueTokens(address,uint256)", address(token), 1e18)
        );
        assertFalse(ok);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowance semantics
    // ---------------------------------------------------------------------------------------------

    function test_approveOverwritesRatherThanAccumulates() public {
        vm.startPrank(holder);
        token.approve(other, 100);
        token.approve(other, 50);
        assertEq(token.allowance(holder, other), 50);
        token.approve(other, 0);
        assertEq(token.allowance(holder, other), 0);
        vm.stopPrank();
    }

    function test_ownerNeedsSelfAllowanceForTransferFrom() public {
        factory.move(token, holder, 10e18);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, holder, 0, 1e18));
        token.transferFrom(holder, other, 1e18);

        vm.prank(holder);
        token.approve(holder, 1e18);
        vm.prank(holder);
        assertTrue(token.transferFrom(holder, other, 1e18));
        assertEq(token.allowance(holder, holder), 0);
        assertEq(token.balanceOf(other), 1e18);
    }

    function test_allowanceIsPerSpenderNotShared() public {
        factory.move(token, holder, 10e18);
        vm.prank(holder);
        token.approve(other, 10e18);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, trader, 0, 1));
        token.transferFrom(holder, trader, 1);
        assertEq(token.allowance(holder, other), 10e18);
    }

    function test_allowanceSurvivesBalanceChangesAndSpendsAcrossCalls() public {
        factory.move(token, holder, 10e18);
        vm.prank(holder);
        token.approve(other, 6e18);
        vm.prank(other);
        token.transferFrom(holder, other, 4e18);
        assertEq(token.allowance(holder, other), 2e18);
        vm.prank(other);
        token.transferFrom(holder, trader, 2e18);
        assertEq(token.allowance(holder, other), 0);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, other, 0, 1));
        token.transferFrom(holder, trader, 1);
        assertEq(token.balanceOf(holder), 4e18);
    }

    function test_transferFromToZeroAddressReverts() public {
        factory.move(token, holder, 1e18);
        vm.prank(holder);
        token.approve(other, 1e18);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(holder, address(0), 1e18);
        assertEq(token.allowance(holder, other), 1e18, "a failed transferFrom spent the allowance");
    }

    function test_transferFromZeroAddressRevertsEvenWithNothingToMove() public {
        // Nobody can hold an allowance from the zero address, so the allowance check rejects it
        // before OZ's own zero-sender check is reached. Either way nothing moves.
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, other, 0, 1));
        token.transferFrom(address(0), other, 1);
    }

    function testFuzz_infiniteAllowanceNeverDecrements(uint256 pulled) public {
        factory.move(token, holder, SUPPLY);
        pulled = bound(pulled, 0, SUPPLY);
        vm.prank(holder);
        token.approve(other, type(uint256).max);
        vm.prank(other);
        token.transferFrom(holder, trader, pulled);
        assertEq(token.allowance(holder, other), type(uint256).max);
        assertEq(token.balanceOf(trader), pulled);
    }

    function testFuzz_maxMinusOneAllowanceDoesDecrement(uint256 pulled) public {
        factory.move(token, holder, SUPPLY);
        pulled = bound(pulled, 0, SUPPLY);
        vm.prank(holder);
        token.approve(other, type(uint256).max - 1);
        vm.prank(other);
        token.transferFrom(holder, trader, pulled);
        assertEq(token.allowance(holder, other), type(uint256).max - 1 - pulled);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: no caller, no amount, no selector ever changes the supply upward
    // ---------------------------------------------------------------------------------------------

    function testFuzz_randomCalldataNeverRaisesSupplyOrCreatesBalance(
        uint256 callerSeed,
        bytes4 selector,
        bytes32 a,
        bytes32 b
    ) public {
        address caller = address(uint160(bound(callerSeed, 1, type(uint160).max)));
        bytes memory data = abi.encodePacked(selector, a, b);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        ok;
        assertLe(token.totalSupply(), SUPPLY, "random call grew the supply");
        if (caller != address(factory)) {
            assertEq(token.balanceOf(caller), 0, "random call credited the caller");
        }
    }
}
