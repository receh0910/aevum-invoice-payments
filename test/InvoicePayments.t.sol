// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {InvoicePayments} from "../src/InvoicePayments.sol";
import {MockUSD8} from "../src/mocks/MockUSD8.sol";

/// @notice Minimal cheatcode interface (no forge-std dependency).
interface Vm {
    function prank(address msgSender) external;
    function warp(uint256 newTimestamp) external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function sign(uint256 privateKey, bytes32 digest) external pure returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 privateKey) external pure returns (address keyAddr);
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;
}

contract InvoicePaymentsTest {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // Re-declared for expectEmit comparisons.
    event InvoiceCreated(
        bytes32 indexed invoiceId, address indexed merchant, uint256 amount, uint64 expiry, bytes32 memoHash
    );
    event InvoicePaid(
        bytes32 indexed invoiceId, address indexed payer, address indexed merchant, uint256 amount, uint64 timestamp
    );
    event InvoiceCancelled(bytes32 indexed invoiceId, address indexed merchant);

    MockUSD8 internal token;
    InvoicePayments internal payments;

    uint256 internal constant PAYER_PK = 0xA11CE;
    uint256 internal constant RELAYER_PK = 0xB0B;
    address internal payer;
    address internal relayer;
    address internal merchant = address(0xCAFE);
    address internal stranger = address(0xDEAD);

    uint256 internal constant AMOUNT = 25_000_000; // 25 tUSD8 (6 decimals)
    bytes32 internal constant ID1 = keccak256("invoice-1-secret");
    bytes32 internal constant ID2 = keccak256("invoice-2-secret");
    bytes32 internal constant MEMO = keccak256("2x design work, due Friday");

    function setUp() public {
        vm.warp(1_700_000_000);
        payer = vm.addr(PAYER_PK);
        relayer = vm.addr(RELAYER_PK);
        token = new MockUSD8();
        payments = new InvoicePayments(address(token));
        token.mint(payer, 1_000_000_000); // 1,000 tUSD8
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _create(bytes32 id, uint256 amount, uint64 expiry) internal {
        vm.prank(merchant);
        payments.createInvoice(id, amount, MEMO, expiry);
    }

    function _expiry() internal view returns (uint64) {
        return uint64(block.timestamp + 7 days);
    }

    function _signReceive(
        uint256 pk,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash = keccak256(
            abi.encode(token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), from, to, value, validAfter, validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        return vm.sign(pk, digest);
    }

    function _assertEq(uint256 a, uint256 b, string memory what) internal pure {
        require(a == b, what);
    }

    function _assertEq(address a, address b, string memory what) internal pure {
        require(a == b, what);
    }

    function _assertTrue(bool cond, string memory what) internal pure {
        require(cond, what);
    }

    // ------------------------------------------------------------------
    // Standard payment
    // ------------------------------------------------------------------

    function test_CreateAndPayStandard() public {
        _create(ID1, AMOUNT, _expiry());

        vm.prank(payer);
        token.approve(address(payments), AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit InvoicePaid(ID1, payer, merchant, AMOUNT, uint64(block.timestamp));
        vm.prank(payer);
        payments.payInvoice(ID1);

        _assertEq(token.balanceOf(merchant), AMOUNT, "merchant paid exact");
        _assertEq(token.balanceOf(payer), 1_000_000_000 - AMOUNT, "payer debited exact");
        _assertEq(token.balanceOf(address(payments)), 0, "contract holds nothing");
        _assertTrue(payments.isPaid(ID1), "isPaid");

        (InvoicePayments.Status st,,,,, address p, uint64 paidAt) = payments.invoiceStatus(ID1);
        _assertTrue(st == InvoicePayments.Status.Paid, "status paid");
        _assertEq(p, payer, "payer recorded");
        _assertEq(uint256(paidAt), block.timestamp, "paidAt recorded");
    }

    function test_PayRequiresFullApproval() public {
        _create(ID1, AMOUNT, _expiry());
        vm.prank(payer);
        token.approve(address(payments), AMOUNT - 1); // one base unit short
        vm.expectRevert(MockUSD8.InsufficientAllowance.selector);
        vm.prank(payer);
        payments.payInvoice(ID1);
        _assertTrue(!payments.isPaid(ID1), "not paid on failed transfer");
    }

    function test_DoublePayReverts() public {
        _create(ID1, AMOUNT, _expiry());
        vm.prank(payer);
        token.approve(address(payments), AMOUNT * 2);
        vm.prank(payer);
        payments.payInvoice(ID1);

        vm.expectRevert(abi.encodeWithSelector(InvoicePayments.InvoiceNotOpen.selector, ID1));
        vm.prank(payer);
        payments.payInvoice(ID1);
    }

    function test_PayNonexistentReverts() public {
        vm.expectRevert(abi.encodeWithSelector(InvoicePayments.InvoiceNotFound.selector, ID1));
        vm.prank(payer);
        payments.payInvoice(ID1);
    }

    function test_ExpiredInvoiceCannotBePaid() public {
        uint64 exp = _expiry();
        _create(ID1, AMOUNT, exp);
        vm.prank(payer);
        token.approve(address(payments), AMOUNT);

        vm.warp(uint256(exp) + 1);
        (InvoicePayments.Status st,,,,,,) = payments.invoiceStatus(ID1);
        _assertTrue(st == InvoicePayments.Status.Expired, "view reports expired");

        vm.expectRevert(abi.encodeWithSelector(InvoicePayments.InvoiceExpired.selector, ID1));
        vm.prank(payer);
        payments.payInvoice(ID1);
    }

    function test_PayAtExactExpirySucceeds() public {
        uint64 exp = _expiry();
        _create(ID1, AMOUNT, exp);
        vm.prank(payer);
        token.approve(address(payments), AMOUNT);
        vm.warp(uint256(exp));
        vm.prank(payer);
        payments.payInvoice(ID1);
        _assertTrue(payments.isPaid(ID1), "paid at expiry boundary");
    }

    // ------------------------------------------------------------------
    // Creation guards + cancel
    // ------------------------------------------------------------------

    function test_CreateGuards() public {
        vm.expectRevert(InvoicePayments.ZeroAmount.selector);
        vm.prank(merchant);
        payments.createInvoice(ID1, 0, MEMO, _expiry());

        vm.expectRevert(InvoicePayments.ExpiryInPast.selector);
        vm.prank(merchant);
        payments.createInvoice(ID1, AMOUNT, MEMO, uint64(block.timestamp));

        _create(ID1, AMOUNT, _expiry());
        vm.expectRevert(abi.encodeWithSelector(InvoicePayments.InvoiceExists.selector, ID1));
        vm.prank(merchant);
        payments.createInvoice(ID1, AMOUNT, MEMO, _expiry());
    }

    function test_CancelByMerchantOnly() public {
        _create(ID1, AMOUNT, _expiry());

        vm.expectRevert(abi.encodeWithSelector(InvoicePayments.NotMerchant.selector, ID1));
        vm.prank(stranger);
        payments.cancelInvoice(ID1);

        vm.expectEmit(true, true, false, true);
        emit InvoiceCancelled(ID1, merchant);
        vm.prank(merchant);
        payments.cancelInvoice(ID1);

        vm.prank(payer);
        token.approve(address(payments), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(InvoicePayments.InvoiceNotOpen.selector, ID1));
        vm.prank(payer);
        payments.payInvoice(ID1);
    }

    function test_CancelPaidInvoiceReverts() public {
        _create(ID1, AMOUNT, _expiry());
        vm.prank(payer);
        token.approve(address(payments), AMOUNT);
        vm.prank(payer);
        payments.payInvoice(ID1);

        vm.expectRevert(abi.encodeWithSelector(InvoicePayments.InvoiceNotOpen.selector, ID1));
        vm.prank(merchant);
        payments.cancelInvoice(ID1);
    }

    // ------------------------------------------------------------------
    // Gasless payment (EIP-3009)
    // ------------------------------------------------------------------

    function test_PayGaslessHappyPath() public {
        _create(ID1, AMOUNT, _expiry());
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = payments.authorizationNonce(ID1);
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive(PAYER_PK, payer, address(payments), AMOUNT, validAfter, validBefore, nonce);

        vm.expectEmit(true, true, true, true);
        emit InvoicePaid(ID1, payer, merchant, AMOUNT, uint64(block.timestamp));
        vm.prank(relayer); // anyone may relay; payer needs no gas token
        payments.payInvoiceWithAuthorization(ID1, payer, validAfter, validBefore, v, r, s);

        _assertEq(token.balanceOf(merchant), AMOUNT, "merchant paid exact");
        _assertEq(token.balanceOf(payer), 1_000_000_000 - AMOUNT, "payer debited exact");
        _assertEq(token.balanceOf(address(payments)), 0, "contract holds nothing after forward");
        _assertTrue(token.authorizationState(payer, nonce), "authorization consumed");
        _assertTrue(payments.isPaid(ID1), "isPaid");
    }

    function test_GaslessSignatureBoundToInvoice() public {
        _create(ID1, AMOUNT, _expiry());
        _create(ID2, AMOUNT, _expiry());
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        // Sign for ID2, try to spend it on ID1: nonce differs -> invalid.
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive(PAYER_PK, payer, address(payments), AMOUNT, validAfter, validBefore, payments.authorizationNonce(ID2));

        vm.expectRevert(MockUSD8.InvalidSignature.selector);
        vm.prank(relayer);
        payments.payInvoiceWithAuthorization(ID1, payer, validAfter, validBefore, v, r, s);
        _assertTrue(!payments.isPaid(ID1), "ID1 not paid");
    }

    function test_GaslessWrongValueSignatureReverts() public {
        _create(ID1, AMOUNT, _expiry());
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        // Payer signed 1 base unit; contract always requests the invoice amount.
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive(PAYER_PK, payer, address(payments), 1, validAfter, validBefore, payments.authorizationNonce(ID1));

        vm.expectRevert(MockUSD8.InvalidSignature.selector);
        vm.prank(relayer);
        payments.payInvoiceWithAuthorization(ID1, payer, validAfter, validBefore, v, r, s);
    }

    function test_GaslessReplayReverts() public {
        _create(ID1, AMOUNT, _expiry());
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive(PAYER_PK, payer, address(payments), AMOUNT, validAfter, validBefore, payments.authorizationNonce(ID1));

        vm.prank(relayer);
        payments.payInvoiceWithAuthorization(ID1, payer, validAfter, validBefore, v, r, s);

        vm.expectRevert(abi.encodeWithSelector(InvoicePayments.InvoiceNotOpen.selector, ID1));
        vm.prank(relayer);
        payments.payInvoiceWithAuthorization(ID1, payer, validAfter, validBefore, v, r, s);
    }

    function test_GaslessExpiredAuthorizationReverts() public {
        _create(ID1, AMOUNT, _expiry());
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 10 minutes;
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive(PAYER_PK, payer, address(payments), AMOUNT, validAfter, validBefore, payments.authorizationNonce(ID1));

        vm.warp(validBefore + 1);
        vm.expectRevert(MockUSD8.AuthorizationExpired.selector);
        vm.prank(relayer);
        payments.payInvoiceWithAuthorization(ID1, payer, validAfter, validBefore, v, r, s);
    }

    function test_GaslessOnExpiredInvoiceReverts() public {
        uint64 exp = _expiry();
        _create(ID1, AMOUNT, exp);
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 30 days;
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive(PAYER_PK, payer, address(payments), AMOUNT, validAfter, validBefore, payments.authorizationNonce(ID1));

        vm.warp(uint256(exp) + 1);
        vm.expectRevert(abi.encodeWithSelector(InvoicePayments.InvoiceExpired.selector, ID1));
        vm.prank(relayer);
        payments.payInvoiceWithAuthorization(ID1, payer, validAfter, validBefore, v, r, s);
    }

    function test_GaslessWrongSignerReverts() public {
        _create(ID1, AMOUNT, _expiry());
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        // Signed by relayer's key but claims `from` = payer.
        (uint8 v, bytes32 r, bytes32 s) =
            _signReceive(RELAYER_PK, payer, address(payments), AMOUNT, validAfter, validBefore, payments.authorizationNonce(ID1));

        vm.expectRevert(MockUSD8.InvalidSignature.selector);
        vm.prank(relayer);
        payments.payInvoiceWithAuthorization(ID1, payer, validAfter, validBefore, v, r, s);
    }

    // ------------------------------------------------------------------
    // Mock sanity (permit), so the mock itself is trustworthy
    // ------------------------------------------------------------------

    function test_MockPermit() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash =
            keccak256(abi.encode(token.PERMIT_TYPEHASH(), payer, address(payments), AMOUNT, token.nonces(payer), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(PAYER_PK, digest);
        token.permit(payer, address(payments), AMOUNT, deadline, v, r, s);
        _assertEq(token.allowance(payer, address(payments)), AMOUNT, "permit sets allowance");
    }
}
