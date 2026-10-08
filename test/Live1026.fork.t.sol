// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IMD6900PonsLaunch} from "../src/IMD6900PonsLaunch.sol";
import {PonsTokenParams} from "../src/IPons.sol";
import {PonsPredict} from "./PonsPredict.sol";

/// @dev The swarm's version (launch #1026) adds these to ours
interface ILaunch1026 {
    function setMeta(PonsTokenParams calldata m) external;
    function meta() external view returns (PonsTokenParams memory);
    function setClaimSupplyCeiling(uint256 supply) external;
    function launch(bytes32 salt, address expectedToken, uint256 buyEth, uint256 minTokensOut) external payable returns (address, uint256);
    function harvest(bytes32 graduatedPoolId) external returns (uint256);
    function claim(uint256 amount) external;
    function releasable() external view returns (uint256);
    function release(uint256 amount, address to) external;
    function pons() external view returns (address);
    function curve() external view returns (address);
    function launchBought() external view returns (uint256);
}

interface IFactoryEcon {
    function previewLaunchEconomics(uint256, address) external view returns (bytes32);
}

interface IERC20R {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

interface ICurveB {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
}

/// @notice The launcher the IMD swarm deployed (launch #1026, 0xe0abb21f…), rehearsed on a Robinhood fork exactly as
///         the team will run it: pin the economics, set the claim ceiling, send the ETH, launch at the mined 0x6900
///         address, harvest, open claims, release the excess.
contract Live1026ForkTest is Test {
    address constant LAUNCH = 0xE0aBb21F15766BE162429f46F494617eB5EF6Ba0;
    address constant FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant IMDSTR = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F;
    address constant TIMELOCK = 0x16D3f65B708883DF042d98E1C7a49B32A33E2A14;
    address constant TEAM = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059;

    function test_fork_mine6900_forTheDeployedLauncher() public {
        string memory rpc_ = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc_).length == 0) vm.skip(true);
        vm.createSelectFork(rpc_);
        ILaunch1026 l = ILaunch1026(LAUNCH);

        // 1. pin the economics (setMeta with the brand as it is)
        PonsTokenParams memory m = l.meta();
        m.expectedEconomics = IFactoryEcon(FACTORY).previewLaunchEconomics(0, address(0));
        vm.prank(TEAM);
        l.setMeta(m);

        // 2. mine 0x6900 for this contract and these details
        (bool found, bytes32 salt, address coin,) = PonsPredict.mine(IMD6900PonsLaunch(payable(LAUNCH)), bytes("6900"), 0, 600_000);
        assertTrue(found, "0x6900 mined");
        console2.log("coin", coin);
        console2.log("salt");
        console2.logBytes32(salt);
        console2.log("economics");
        console2.logBytes32(m.expectedEconomics);

        // 3. the claim ceiling: Robinhood's IMDSTR today (the bridge in from Ethereum must be closed for this to hold)
        uint256 ceiling = IERC20R(IMDSTR).totalSupply();
        vm.prank(TEAM);
        l.setClaimSupplyCeiling(ceiling);

        // 4. the ETH (the pulled pool's), 5. the launch
        vm.deal(TEAM, 3 ether);
        vm.prank(TEAM);
        (bool ok,) = LAUNCH.call{value: 2.83 ether}("");
        assertTrue(ok);
        vm.prank(TEAM);
        (address got, uint256 bought) = l.launch(salt, coin, 0, 0);
        assertEq(got, coin);
        assertEq(uint160(coin) >> 144, 0x6900, "0x6900");
        assertEq(IERC20R(coin).name(), "Identity.MD 6900");
        assertEq(IERC20R(coin).symbol(), "IMD6900");
        console2.log("bought (millions)", bought / 1e24);
        assertEq(LAUNCH.balance, 0, "every wei bought");

        // a trade, then anyone harvests: 70% pot, 30% ops
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 60);
        vm.prank(buyer, buyer);
        ICurveB(l.curve()).buy{value: 0.5 ether}(0.5 ether, 0, buyer);
        uint256 potBefore = address(0xc39e650a24985C2bBA9FD83C81041B8f3E3f9EDd).balance;
        uint256 split = l.harvest(bytes32(0));
        console2.log("harvested (wei)", split);
        assertGt(address(0xc39e650a24985C2bBA9FD83C81041B8f3E3f9EDd).balance - potBefore, 0, "the pot got its share");

        // claims open once the timelock makes it a distributor
        vm.prank(TIMELOCK);
        (ok,) = IMDSTR.call(abi.encodeWithSignature("setDistributor(address,bool)", LAUNCH, true));
        assertTrue(ok);
        vm.startPrank(TEAM);
        IERC20R(IMDSTR).approve(LAUNCH, 1_000_000e18);
        l.claim(1_000_000e18);
        vm.stopPrank();
        assertEq(IERC20R(coin).balanceOf(TEAM), 1_000_000e18, "1:1");

        // the excess over the ceiling is the owner's
        uint256 free = l.releasable();
        console2.log("releasable (millions)", free / 1e24);
        vm.prank(TEAM);
        l.release(free, TEAM);
    }
}
