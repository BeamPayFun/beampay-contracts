// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import { BeamPayRouter } from "../src/BeamPayRouter.sol";

/// @notice One-shot deploy of the non-upgradeable BeamPayRouter.
/// @dev BeamPayRouter is intentionally NOT a UUPS proxy — once deployed it cannot be replaced
///      (CLAUDE.md invariant #3). All parameter changes flow through the 7-day Timelock baked
///      into the contract itself, not a proxy admin.
contract BeamPayRouterScript is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address governance = vm.envOr("GOVERNANCE", deployer);
        uint256 initialFeeRate = vm.envUint("INITIAL_FEE_RATE");

        address[] memory initialTokens = vm.envAddress("INITIAL_TOKENS", ",");
        address[] memory initialRecipients = vm.envAddress("INITIAL_RECIPIENTS", ",");

        console.log("Deployer:        %s", deployer);
        console.log("Governance:      %s", governance);
        console.log("Initial fee rate (bps): %s", initialFeeRate);
        console.log("Initial tokens:  %s", initialTokens.length);
        console.log("Initial recipients: %s", initialRecipients.length);

        require(initialFeeRate <= 10, "fee > hard limit (10 bps)");
        require(initialRecipients.length >= 1 && initialRecipients.length <= 20, "recipients out of range");

        vm.startBroadcast(deployerPrivateKey);
        BeamPayRouter router = new BeamPayRouter(governance, initialTokens, initialRecipients, initialFeeRate);
        vm.stopBroadcast();

        console.log("BeamPayRouter:      %s", address(router));
    }
}
