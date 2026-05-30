// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import { BeamPayRouter } from "../src/BeamPayRouter.sol";

interface ICreateX {
    function deployCreate3(bytes32 salt, bytes calldata initCode) external payable returns (address);
    function computeCreate3Address(bytes32 guardedSalt) external view returns (address);
}

/// @notice Deploy BeamPayRouter via CreateX CREATE3 → SAME address on every chain (testnet + all mainnets).
/// @dev Cross-chain identity requires the guarded-salt formula to exclude block.chainid. That holds only when:
///        - salt[0:20]  == deployer  (sender-protected, anti front-run)
///        - salt[20]    == 0x00      (redeploy-protection OFF — chainid NOT mixed in)
///      Guard formula (CreateX): keccak256(abi.encodePacked(bytes32(uint160(deployer)), salt)).
///      Mine the salt with script/MineSalt.s.sol. Constructor args may differ per chain (CREATE3 ignores
///      bytecode + args for addressing) — so per-chain INITIAL_TOKENS does NOT break same-address.
contract DeployCreate3 is Script {
    ICreateX constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address governance = vm.envOr("GOVERNANCE", deployer);
        uint256 initialFeeRate = vm.envUint("INITIAL_FEE_RATE");
        address[] memory initialTokens = vm.envAddress("INITIAL_TOKENS", ",");
        address[] memory initialRecipients = vm.envAddress("INITIAL_RECIPIENTS", ",");
        bytes32 salt = vm.envBytes32("SALT");

        // --- salt invariants for cross-chain SAME address ---
        require(address(bytes20(salt)) == deployer, "salt[0:20] != deployer (sender-protection)");
        require(salt[20] == 0x00, "salt[20] != 0x00 (redeploy-protection must be OFF for multichain)");

        require(initialFeeRate <= 10, "fee > hard limit (10 bps)");
        require(initialRecipients.length >= 1 && initialRecipients.length <= 20, "recipients out of range");

        bytes32 guarded = keccak256(abi.encodePacked(bytes32(uint256(uint160(deployer))), salt));
        address predicted = CREATEX.computeCreate3Address(guarded);

        console.log("Deployer:          %s", deployer);
        console.log("Governance:        %s", governance);
        console.log("Initial fee (bps): %s", initialFeeRate);
        console.log("Initial tokens:    %s", initialTokens.length);
        console.log("Initial recipients:%s", initialRecipients.length);
        console.log("ChainId:           %s", block.chainid);
        console.log("Predicted (CREATE3): %s", predicted);

        bytes memory initCode = abi.encodePacked(
            type(BeamPayRouter).creationCode, abi.encode(governance, initialTokens, initialRecipients, initialFeeRate)
        );

        vm.startBroadcast(pk);
        address deployed = CREATEX.deployCreate3(salt, initCode);
        vm.stopBroadcast();

        require(deployed == predicted, "ADDRESS_MISMATCH");
        console.log("BeamPayRouter deployed: %s", deployed);
    }
}
