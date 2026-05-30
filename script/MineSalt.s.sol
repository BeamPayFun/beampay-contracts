// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";

/// @notice Mine a CreateX vanity salt for BeamPayRouter so the CREATE3 address
///         starts with a chosen hex prefix and is IDENTICAL on every chain.
/// @dev Sender-protected, redeploy-protection OFF (byte[20]=0x00) → guard formula
///      `keccak256(abi.encodePacked(bytes32(uint160(deployer)), salt))` has NO chainid,
///      so the predicted address is the same on testnet + all mainnets.
///      Run against any chain that has CreateX (read-only, no broadcast):
///        forge script script/MineSalt.s.sol:MineSalt --rpc-url "$NODEREAL_BSC_RPC_URL"
contract MineSalt is Script {
    address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    function computeCreate3(bytes32 guardedSalt) internal view returns (address) {
        // CreateX.computeCreate3Address(bytes32) — view, deployer = CreateX (_SELF)
        (bool ok, bytes memory ret) =
            CREATEX.staticcall(abi.encodeWithSignature("computeCreate3Address(bytes32)", guardedSalt));
        require(ok, "computeCreate3Address failed");
        return abi.decode(ret, (address));
    }

    function run() public view {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        uint256 prefix = vm.envOr("VANITY_PREFIX", uint256(0xBEA)); // top 3 nibbles
        uint256 maxIter = vm.envOr("MINE_MAX_ITER", uint256(2_000_000));

        console.log("Deployer:    %s", deployer);
        console.log("Vanity top-3-nibbles target: 0x%x", prefix);

        bytes20 dep = bytes20(deployer);
        for (uint256 i = 0; i < maxIter; i++) {
            // salt = deployer(20) ++ 0x00 (redeploy-protect OFF) ++ entropy(11)
            bytes32 salt = bytes32(abi.encodePacked(dep, bytes1(0x00), bytes11(uint88(i))));
            // sender-protected, no chainid → cross-chain identical
            bytes32 guarded = keccak256(abi.encodePacked(bytes32(uint256(uint160(deployer))), salt));
            address predicted = computeCreate3(guarded);
            if (uint256(uint160(predicted)) >> 148 == prefix) {
                console.log("FOUND at iter %s", i);
                console.log("  salt:      %s", vm.toString(salt));
                console.log("  predicted: %s", predicted);
                return;
            }
        }
        console.log("No match within %s iterations", maxIter);
    }
}
