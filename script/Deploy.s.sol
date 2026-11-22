// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {InvoicePayments} from "../src/InvoicePayments.sol";

/// @notice Minimal cheatcode interface (no forge-std dependency).
interface Vm {
    function startBroadcast() external;
    function stopBroadcast() external;
    function envOr(string calldata name, address defaultValue) external view returns (address);
}

/// @notice Deploy InvoicePayments against the real tUSD8 on Aevum testnet.
///         Run (once the deployer wallet holds tQDAY from the faucet):
///           forge script script/Deploy.s.sol:Deploy \
///             --rpc-url aevum --broadcast --legacy \
///             --account <foundry-keystore-account>
///         Aevum uses legacy (type 0) transactions. Override the token with
///         env TUSD8=0x... only for local anvil runs with MockUSD8.
contract Deploy {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address internal constant REAL_TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;

    function run() external returns (address payments) {
        address token = vm.envOr("TUSD8", REAL_TUSD8);
        vm.startBroadcast();
        payments = address(new InvoicePayments(token));
        vm.stopBroadcast();
    }
}
