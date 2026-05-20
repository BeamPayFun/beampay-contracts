// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import { BeamMockERC20 } from "../src/mocks/BeamMockERC20.sol";

/// @notice Deploys testnet faucet stablecoins tUSDT and tUSDC (6 decimals each).
/// @dev    TESTNET ONLY. BeamMockERC20 allows permissionless minting.
contract DeployMocksScript is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer: %s", deployer);
        console.log("ChainId:  %s", block.chainid);
        require(block.chainid != 1 && block.chainid != 56, "mocks: mainnet forbidden");

        vm.startBroadcast(deployerPrivateKey);
        BeamMockERC20 tUSDT = new BeamMockERC20("Beam Test USDT", "tUSDT", 6);
        BeamMockERC20 tUSDC = new BeamMockERC20("Beam Test USDC", "tUSDC", 6);
        vm.stopBroadcast();

        console.log("tUSDT: %s", address(tUSDT));
        console.log("tUSDC: %s", address(tUSDC));
    }
}
