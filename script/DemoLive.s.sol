// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {InvoicePayments} from "../src/InvoicePayments.sol";

/// @notice Minimal cheatcode interface (no forge-std dependency).
interface Vm {
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
    function envAddress(string calldata name) external view returns (address);
    function envUint(string calldata name) external view returns (uint256);
    function addr(uint256 privateKey) external pure returns (address);
    function sign(uint256 privateKey, bytes32 digest) external pure returns (uint8 v, bytes32 r, bytes32 s);
}

interface IERC20Demo {
    function approve(address spender, uint256 amount) external returns (bool);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @notice Live demo variant sized for the Discord faucet grant (5 tUSD8):
///         invoice A = 2 tUSD8 (standard), invoice B = 1 tUSD8 (gasless).
///         Same flow as Demo.s.sol. Env: PAYMENTS, TOKEN, MERCHANT_PK, PAYER_PK.
///         Run: forge script script/DemoLive.s.sol:DemoLive \
///           --rpc-url aevum --broadcast --legacy
contract DemoLive {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    bytes32 internal constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    uint256 internal constant AMOUNT_A = 2_000_000; // 2 tUSD8
    uint256 internal constant AMOUNT_B = 1_000_000; // 1 tUSD8

    function run()
        external
        returns (bytes32 invoiceA, bytes32 invoiceB, InvoicePayments.Status statusA, InvoicePayments.Status statusB)
    {
        InvoicePayments payments = InvoicePayments(vm.envAddress("PAYMENTS"));
        uint256 merchantPk = vm.envUint("MERCHANT_PK");
        uint256 payerPk = vm.envUint("PAYER_PK");

        invoiceA = keccak256(abi.encode("demo-live-invoice-A", block.timestamp));
        invoiceB = keccak256(abi.encode("demo-live-invoice-B", block.timestamp));

        _createInvoices(payments, merchantPk, invoiceA, invoiceB);
        _payStandard(payments, payerPk, invoiceA);
        _payGasless(payments, merchantPk, payerPk, invoiceB);

        (statusA,,,,,,) = payments.invoiceStatus(invoiceA);
        (statusB,,,,,,) = payments.invoiceStatus(invoiceB);
    }

    function _createInvoices(InvoicePayments payments, uint256 merchantPk, bytes32 invoiceA, bytes32 invoiceB)
        internal
    {
        uint64 expiry = uint64(block.timestamp + 7 days);
        vm.startBroadcast(merchantPk);
        payments.createInvoice(invoiceA, AMOUNT_A, keccak256("demo-live: invoice A"), expiry);
        payments.createInvoice(invoiceB, AMOUNT_B, keccak256("demo-live: invoice B"), expiry);
        vm.stopBroadcast();
    }

    function _payStandard(InvoicePayments payments, uint256 payerPk, bytes32 invoiceA) internal {
        IERC20Demo token = IERC20Demo(vm.envAddress("TOKEN"));
        vm.startBroadcast(payerPk);
        token.approve(address(payments), AMOUNT_A);
        payments.payInvoice(invoiceA);
        vm.stopBroadcast();
    }

    function _payGasless(InvoicePayments payments, uint256 merchantPk, uint256 payerPk, bytes32 invoiceB) internal {
        address payer = vm.addr(payerPk);
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _sign(payments, payerPk, payer, invoiceB, validAfter, validBefore);
        vm.startBroadcast(merchantPk);
        payments.payInvoiceWithAuthorization(invoiceB, payer, validAfter, validBefore, v, r, s);
        vm.stopBroadcast();
    }

    function _sign(
        InvoicePayments payments,
        uint256 payerPk,
        address payer,
        bytes32 invoiceB,
        uint256 validAfter,
        uint256 validBefore
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        IERC20Demo token = IERC20Demo(vm.envAddress("TOKEN"));
        bytes32 nonce = payments.authorizationNonce(invoiceB);
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_TYPEHASH, payer, address(payments), AMOUNT_B, validAfter, validBefore, nonce)
        );
        bytes32 domainSeparator = token.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        return vm.sign(payerPk, digest);
    }
}
