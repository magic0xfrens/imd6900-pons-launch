// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IMD6900PonsLaunch} from "../src/IMD6900PonsLaunch.sol";
import {PonsTokenParams} from "../src/IPons.sol";
import {PonsPredict} from "../test/PonsPredict.sol";

interface ILaunch1026 {
    function setMeta(PonsTokenParams calldata m) external;
    function meta() external view returns (PonsTokenParams memory);
    function launchConfigId() external view returns (uint256);
    function setClaimSupplyCeiling(uint256 supply) external;
    function launch(bytes32 salt, address expectedToken, uint256 buyEth, uint256 minTokensOut) external payable returns (address, uint256);
}

interface IFactoryEcon {
    function previewLaunchEconomics(uint256, address) external view returns (bytes32);
}

/// @notice The owner's steps on the launcher the IMD swarm deployed (launch #1026), from the team wallet:
///   forge script script/Owner.s.sol --sig "pin()" --rpc-url <robinhood> --account imdstr-deployer --broadcast
///   forge script script/Owner.s.sol --sig "ceiling(uint256)" <supply> --rpc-url <robinhood> --account imdstr-deployer --broadcast
///   forge script script/Owner.s.sol --sig "launch(bytes32,address,uint256)" <salt> <coin> <minOut> --rpc-url <robinhood> --account imdstr-deployer --broadcast
contract Owner is Script {
    ILaunch1026 constant L = ILaunch1026(0xE0aBb21F15766BE162429f46F494617eB5EF6Ba0);
    address constant OWNER = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059;
    address constant FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;

    /// @notice Pins Pons' launch economics as they are now, with the brand unchanged (the launch requires both)
    function pin() external {
        PonsTokenParams memory m = L.meta();
        m.expectedEconomics = IFactoryEcon(FACTORY).previewLaunchEconomics(L.launchConfigId(), address(0));
        vm.broadcast(OWNER);
        L.setMeta(m);
        console2.log("pinned economics");
        console2.logBytes32(m.expectedEconomics);
        console2.log("brand", m.name, m.symbol, m.logo);
    }

    /// @notice The most IMDSTR that can ever claim (frozen at the launch; nothing is releasable until it is set)
    function ceiling(uint256 supply) external {
        vm.broadcast(OWNER);
        L.setClaimSupplyCeiling(supply);
        console2.log("claim ceiling", supply);
    }

    /// @notice Launches at the mined address, buying first with all the ETH the launcher holds. Checks first that the
    ///         salt still lands at `coin` for the details stored now (any setMeta after mining moves it).
    function launch(bytes32 salt, address coin, uint256 minTokensOut) external {
        (address predicted,) = PonsPredict.predict(IMD6900PonsLaunch(payable(address(L))), salt);
        require(predicted == coin, "the salt doesn't land at that address for these details: mine again");
        require(address(L).balance > 0.001 ether, "send the ETH to the launcher first");
        console2.log("launching at", coin, "with ETH", address(L).balance);
        vm.broadcast(OWNER);
        (address got, uint256 bought) = L.launch(salt, coin, 0, minTokensOut);
        console2.log("coin", got);
        console2.log("bought", bought);
    }
}
