// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SilentCat} from "../src/SilentCat.sol";

/// @notice Drives `SilentCat` with random, bounded calls from a small set of actors and keeps ghost
///         books of what every actor should hold and what every allowance should be. Every call that
///         is expected to succeed must succeed (the suite runs with fail-on-revert), and every call
///         that is expected to fail is asserted to fail with the exact ERC-6093 error and to leave
///         state untouched.
contract SilentCatHandler is Test {
    SilentCat public immutable token;
    uint256 public immutable initialSupply;

    /// @dev Actors: the deployer (the factory at launch), the distributor, the pool, the requester
    ///      and two ordinary holders. All tokens stay among them, so the sum of their balances is
    ///      the whole supply at all times.
    address[] public actors;
    mapping(address => bool) public isActor;

    // Ghost books ---------------------------------------------------------------------------------
    uint256 public ghost_burned;
    mapping(address => uint256) public ghost_in;
    mapping(address => uint256) public ghost_out;
    mapping(address => uint256) public ghost_burnedBy;
    mapping(address => mapping(address => uint256)) public ghost_allowance;

    // Call counters, so a reviewer can see the handler was exercised on every path.
    mapping(bytes32 => uint256) public calls;

    string[20] internal adminSignatures = [
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
        "renounceOwnership()"
    ];

    constructor(SilentCat token_, address deployer) {
        token = token_;
        initialSupply = token_.totalSupply();

        actors.push(deployer);
        actors.push(makeAddr("distributor"));
        actors.push(makeAddr("pool"));
        actors.push(makeAddr("requester"));
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        for (uint256 i; i < actors.length; ++i) {
            isActor[actors[i]] = true;
        }
        // The constructor's mint is the deployer's only inflow that is not a transfer.
        ghost_in[deployer] = initialSupply;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    modifier countCall(bytes32 key) {
        calls[key]++;
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Happy paths
    // ---------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external countCall("transfer") {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        assertTrue(ok, "transfer returned false");

        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer changed balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender debited wrong amount");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver credited wrong amount");
        }
        ghost_out[from] += amount;
        ghost_in[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external countCall("approve") {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Occasionally grant an infinite allowance so the non-decrementing path is exercised.
        if (amount % 7 == 0) amount = type(uint256).max;

        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        assertEq(token.allowance(owner, spender), amount, "approve did not overwrite the allowance");
        ghost_allowance[owner][spender] = amount;
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount)
        external
        countCall("transferFrom")
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 cap = allowed < token.balanceOf(owner) ? allowed : token.balanceOf(owner);
        amount = bound(amount, 0, cap);

        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");

        if (owner == to) {
            assertEq(token.balanceOf(owner), ownerBefore, "self transferFrom changed balance");
        } else {
            assertEq(token.balanceOf(owner), ownerBefore - amount, "owner debited wrong amount");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver credited wrong amount");
        }
        if (allowed != type(uint256).max) {
            ghost_allowance[owner][spender] = allowed - amount;
        }
        assertEq(token.allowance(owner, spender), ghost_allowance[owner][spender], "allowance not spent exactly");
        ghost_out[owner] += amount;
        ghost_in[to] += amount;
    }

    function burn(uint256 actorSeed, uint256 amount) external countCall("burn") {
        address actor = _actor(actorSeed);
        amount = bound(amount, 0, token.balanceOf(actor));
        uint256 before = token.balanceOf(actor);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(actor);
        token.burn(amount);

        assertEq(token.balanceOf(actor), before - amount, "burn debited wrong amount");
        assertEq(token.totalSupply(), supplyBefore - amount, "burn changed supply by wrong amount");
        ghost_burned += amount;
        ghost_burnedBy[actor] += amount;
    }

    // ---------------------------------------------------------------------------------------------
    // Failure paths: each must revert with the exact error and leave every balance untouched
    // ---------------------------------------------------------------------------------------------

    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excess)
        external
        countCall("transferAboveBalance")
    {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - balance);
        uint256 amount = balance + excess;

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        token.transfer(to, amount);
        assertEq(token.balanceOf(from), balance, "failed transfer changed the sender's balance");
    }

    function transferFromAboveAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
        countCall("transferFromAboveAllowance")
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) {
            // Nothing is above an infinite allowance; make it finite first so the path is exercised.
            vm.prank(owner);
            token.approve(spender, 0);
            ghost_allowance[owner][spender] = 0;
            allowed = 0;
        }
        excess = bound(excess, 1, type(uint256).max - allowed);
        uint256 amount = allowed + excess;
        uint256 ownerBefore = token.balanceOf(owner);

        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        token.transferFrom(owner, to, amount);
        assertEq(token.balanceOf(owner), ownerBefore, "failed transferFrom changed the owner's balance");
        assertEq(token.allowance(owner, spender), allowed, "failed transferFrom changed the allowance");
    }

    function transferFromAboveBalance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
        countCall("transferFromAboveBalance")
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 balance = token.balanceOf(owner);
        excess = bound(excess, 1, type(uint256).max - balance);
        uint256 amount = balance + excess;

        // Allowance is ample; only the balance is short.
        vm.prank(owner);
        token.approve(spender, type(uint256).max);
        ghost_allowance[owner][spender] = type(uint256).max;

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        token.transferFrom(owner, to, amount);
        assertEq(token.balanceOf(owner), balance, "failed transferFrom changed the owner's balance");
    }

    function burnAboveBalance(uint256 actorSeed, uint256 excess) external countCall("burnAboveBalance") {
        address actor = _actor(actorSeed);
        uint256 balance = token.balanceOf(actor);
        excess = bound(excess, 1, type(uint256).max - balance);
        uint256 amount = balance + excess;
        uint256 supplyBefore = token.totalSupply();

        vm.prank(actor);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, actor, balance, amount));
        token.burn(amount);
        assertEq(token.balanceOf(actor), balance, "failed burn changed the balance");
        assertEq(token.totalSupply(), supplyBefore, "failed burn changed the supply");
    }

    function transferToZeroAddress(uint256 fromSeed, uint256 amount) external countCall("transferToZeroAddress") {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 before = token.balanceOf(from);

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        assertEq(token.balanceOf(from), before, "failed transfer to zero changed the balance");
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external countCall("approveZeroSpender") {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
    }

    /// @dev A stranger with no allowance can never pull from an actor, whatever the amount above zero.
    function strangerPulls(uint256 ownerSeed, uint256 amount) external countCall("strangerPulls") {
        address owner = _actor(ownerSeed);
        address stranger = makeAddr("stranger");
        amount = bound(amount, 1, type(uint256).max);
        uint256 before = token.balanceOf(owner);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        token.transferFrom(owner, stranger, amount);
        assertEq(token.balanceOf(owner), before, "a stranger moved an actor's balance");
    }

    /// @dev No admin-shaped selector exists, from any caller, including the deployer.
    function adminCall(uint256 callerSeed, uint256 sigSeed, uint256 targetSeed) external countCall("adminCall") {
        address caller = _actor(callerSeed);
        address target = _actor(targetSeed);
        string memory sig = adminSignatures[bound(sigSeed, 0, adminSignatures.length - 1)];
        uint256 supplyBefore = token.totalSupply();
        uint256 targetBefore = token.balanceOf(target);

        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodeWithSignature(sig, target, type(uint128).max));
        assertFalse(ok, string.concat("admin selector did not revert: ", sig));
        assertEq(token.totalSupply(), supplyBefore, "admin selector changed supply");
        assertEq(token.balanceOf(target), targetBefore, "admin selector changed a balance");
    }

    function sendEther(uint256 fromSeed, uint256 value) external countCall("sendEther") {
        address from = _actor(fromSeed);
        value = bound(value, 1, 100 ether);
        vm.deal(from, value);
        vm.prank(from);
        (bool ok,) = address(token).call{value: value}("");
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0, "the token holds ether");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SilentCatInvariantTest is StdInvariant, Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;

    SilentCat internal token;
    SilentCatHandler internal handler;
    address internal deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new SilentCat();
        handler = new SilentCatHandler(token, deployer);

        targetContract(address(handler));
    }

    /// @dev The supply only ever shrinks, and by exactly what was burned.
    function invariant_supplyIsInitialMinusBurned() public view {
        assertEq(token.totalSupply(), INITIAL_SUPPLY - handler.ghost_burned(), "supply != initial - burned");
    }

    function invariant_supplyNeverGrows() public view {
        assertLe(token.totalSupply(), INITIAL_SUPPLY, "supply grew after deployment");
    }

    /// @dev The token owes exactly what the actors hold: no balance appears or disappears.
    function invariant_sumOfBalancesEqualsSupply() public view {
        uint256 sum;
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply(), "sum of actor balances != totalSupply");
    }

    /// @dev Each actor holds exactly what flowed in, minus what flowed out, minus what it burned.
    function invariant_eachBalanceMatchesNetFlows() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            address a = handler.actors(i);
            uint256 expected = handler.ghost_in(a) - handler.ghost_out(a) - handler.ghost_burnedBy(a);
            assertEq(token.balanceOf(a), expected, "actor balance != in - out - burned");
            assertLe(token.balanceOf(a), token.totalSupply(), "actor holds more than the supply");
        }
    }

    /// @dev Allowances are exactly what was approved minus what was spent (infinite ones never move).
    function invariant_allowancesMatchGhost() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghost_allowance(owner, spender), "allowance drift");
            }
        }
    }

    function invariant_zeroAddressAndTokenHoldNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "zero address holds tokens");
        assertEq(token.balanceOf(address(token)), 0, "the token holds its own tokens");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    function invariant_metadataIsConstant() public view {
        assertEq(token.name(), "Silent Cat");
        assertEq(token.symbol(), "SCAT");
        assertEq(token.decimals(), 18);
        assertEq(token.TOTAL_SUPPLY(), INITIAL_SUPPLY);
    }
}
