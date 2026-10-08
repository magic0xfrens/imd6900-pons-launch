// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IMD6900PonsLaunch} from "../src/IMD6900PonsLaunch.sol";
import {PonsPredict} from "./PonsPredict.sol";

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManagerLite {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

struct PonsLaunchedToken {
    address token;
    address curve;
    address deployer;
    address creatorFeeRecipient;
    address pairToken;
    uint256 graduationThreshold;
    uint24 poolFee;
    int24 tickSpacing;
    uint16 creatorTaxBps;
    bool buybackEnabled;
    uint8 phase;
    uint256 sweptQuote;
    uint256 sweptTokens;
    uint256 sweptAt;
    bool exists;
}

interface IPonsFactoryLite {
    function createGraduatedPool(address token) external returns (uint256 positionId);
    function getLaunchedToken(address token) external view returns (PonsLaunchedToken memory);
    function memeHook() external view returns (address);
}

interface IMemeHookLite {
    function feeSweepOperator() external view returns (address);
    function pendingFees(bytes32 poolId, address currency) external view returns (uint256);
    function pendingCreatorTax(bytes32 poolId, address currency) external view returns (uint256);
}

/// @dev Pons' fee sweep operator: anyone may run a pool's sweep, inside its price guard (a TWAP of observations
///      across 300 s, the last under 300 s old, the conversion within the guard's slippage)
interface IFeeSweepOperator {
    function observe(bytes32 poolId) external;
    function sweepPool(bytes32 poolId) external;
}

interface ICurveLite {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function graduated() external view returns (bool);
}

/// @dev Buys the coin with ETH on its graduated Uniswap v4 pool, straight through the PoolManager
contract EthBuyer {
    IPoolManagerLite internal immutable pm;

    constructor(IPoolManagerLite pm_) {
        pm = pm_;
    }

    function buy(PoolKey memory key, uint256 ethIn) external payable {
        pm.unlock(abi.encode(key, ethIn, msg.sender));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 ethIn, address to) = abi.decode(data, (PoolKey, uint256, address));
        int256 d = pm.swap(key, SwapParams(true, -int256(ethIn), 4295128740), "");
        pm.settle{value: uint256(uint128(-int128(d >> 128)))}();
        pm.take(key.currency1, to, uint256(uint128(int128(d))));
        return "";
    }

    receive() external payable {}
}

/// @notice After graduation the coin trades on Pons' Uniswap v4 pool and the meme hook books its fees, part in ETH,
///         part in the coin. Turning the coin part into ETH is Pons' fee sweep operator's job (a creator's own
///         sweepPoolFees reverts InternalSwapRequiresOperator); anyone may run the operator's sweepPool inside its
///         price guard, and it books the creator's ETH into Pons' escrow, where {harvest} claims it for the
///         distributor like the curve's fees. On a Robinhood fork against Pons itself.
contract GraduatedForkTest is Test {
    address constant FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant IMDSTR = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F;
    address constant TIMELOCK = 0x16D3f65B708883DF042d98E1C7a49B32A33E2A14;
    address constant TEAM = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059;
    IPoolManagerLite constant PM = IPoolManagerLite(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    IMD6900PonsLaunch l;
    address coin;
    PoolKey key;
    bytes32 poolId;
    EthBuyer buyer;
    address whale = makeAddr("whale");

    function setUp() public {
        string memory rpc_ = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc_).length == 0) vm.skip(true);
        vm.createSelectFork(rpc_);
        l = new IMD6900PonsLaunch(TEAM, FACTORY, IMDSTR, TIMELOCK);
        vm.deal(TEAM, 5 ether);
        (, bytes32 salt, address predicted,) = PonsPredict.mine(l, bytes("69"), 0, 5_000);
        vm.prank(TEAM);
        (coin,) = l.launch{value: 2.8 ether}(salt, predicted, 0, 0);

        // a buyer takes the curve past 4.2 ETH: it graduates, and anyone creates the Pons pool
        vm.deal(whale, 50 ether);
        vm.warp(block.timestamp + 60);
        vm.prank(whale, whale); // the curve refunds what graduation didn't take to the origin
        ICurveLite(l.curve()).buy{value: 5 ether}(5 ether, 0, whale);
        assertTrue(ICurveLite(l.curve()).graduated(), "graduated");
        IPonsFactoryLite(FACTORY).createGraduatedPool(coin);
        PonsLaunchedToken memory t = IPonsFactoryLite(FACTORY).getLaunchedToken(coin);
        assertEq(t.phase, 2, "the pool exists");
        assertEq(t.creatorFeeRecipient, address(l), "still the distributor's fees");
        assertEq(t.creatorTaxBps, 590, "the tax carries over, unchanged");
        key = PoolKey(address(0), coin, t.poolFee, t.tickSpacing, IPonsFactoryLite(FACTORY).memeHook());
        poolId = keccak256(abi.encode(key));
        buyer = new EthBuyer(PM);
        l.harvest(poolId); // everything booked up to graduation (the curve's fees), out of the way
    }

    function _operator() internal view returns (IFeeSweepOperator) {
        return IFeeSweepOperator(IMemeHookLite(key.hooks).feeSweepOperator());
    }

    /// @dev The operator's guard wants a TWAP across its 300 s window, from observations it records at most every
    ///      ~100 s (Robinhood runs ~10 blocks a second): as Pons' keeper does it on chain, four ~110 s apart
    function _observe() internal {
        _advance(0, 0);
        for (uint256 i; i < 4; ++i) {
            _advance(110, 1_100);
            _operator().observe(poolId);
        }
    }

    /// @dev Time and blocks kept here: under via-IR block.timestamp is read once per function, so a loop of
    ///      vm.warp(block.timestamp + x) would set the same time over and over
    uint256 internal now_;
    uint256 internal block_;

    function _advance(uint256 secs, uint256 blocks_) internal {
        if (now_ == 0) (now_, block_) = (vm.getBlockTimestamp(), vm.getBlockNumber());
        (now_, block_) = (now_ + secs, block_ + blocks_);
        vm.warp(now_);
        vm.roll(block_);
    }

    function test_fork_GraduatedPoolFees_reachTheDistributor_throughPonsOperator() public {
        vm.prank(whale);
        buyer.buy{value: 0.5 ether}(key, 0.5 ether);
        uint256 waitingEth = IMemeHookLite(key.hooks).pendingCreatorTax(poolId, address(0))
            + IMemeHookLite(key.hooks).pendingFees(poolId, address(0));
        emit log_named_decimal_uint("creator's ETH waiting in the meme hook", waitingEth, 18);

        // the creator's own sweep can't convert the coin part: harvest says so and claims what it can
        vm.recordLogs();
        l.harvest(poolId);
        assertTrue(_sweepFailed(), "a creator's sweep needs Pons' operator");

        // anyone runs Pons' operator, inside its guard (a pool sweeps at most once an hour, from its graduation on);
        // the ETH lands in the escrow for the distributor
        _advance(2 hours, 72_000);
        _observe();
        address anyone = makeAddr("anyone at all");
        vm.prank(anyone, anyone);
        _operator().sweepPool(poolId);

        address pot = l.POT_BRIDGE();
        (uint256 potBefore, uint256 teamBefore) = (pot.balance, TEAM.balance);
        uint256 split = l.harvest(poolId);
        emit log_named_decimal_uint("harvested from 0.5 ETH of graduated pool buys", split, 18);
        assertGt(split, 0, "the graduated pool's fees reach the distributor");
        assertEq(pot.balance - potBefore, split * 7_000 / 10_000, "70% to the NFT pot's bridge");
        assertEq(TEAM.balance - teamBefore, split * 3_000 / 10_000, "30% ops");
    }

    function _sweepFailed() internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) if (logs[i].topics[0] == IMD6900PonsLaunch.SweepFailed.selector) return true;
        return false;
    }

    receive() external payable {}
}
