// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-20 surface used by InvoicePayments.
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice EIP-3009 surface of tUSD8 (verified on Aevum testnet, chain 44005).
interface IEIP3009 {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}

/// @title InvoicePayments
/// @notice On-chain invoices for tUSD8 on Aevum testnet with two payment modes:
///         standard (approve + pay) and gasless (EIP-3009 signed authorization,
///         relayed by anyone). The exact invoice amount is enforced by the
///         contract, invoices expire, and every payment emits a public receipt
///         event that anyone can verify on-chain. The contract never custodies
///         funds: standard payments go payer -> merchant directly; gasless
///         payments pass through this contract atomically in the same
///         transaction (required by EIP-3009 receiveWithAuthorization, where
///         the caller must be the payee) and are forwarded to the merchant
///         immediately.
contract InvoicePayments {
    enum Status {
        None,
        Open,
        Paid,
        Cancelled,
        Expired
    }

    struct Invoice {
        address merchant;
        uint256 amount; // exact amount in token base units (tUSD8: 6 decimals)
        uint64 expiry; // unix timestamp; payment must happen at or before this
        bytes32 memoHash; // hash of off-chain invoice details (items, note, ...)
        Status status; // stored status; Expired is derived in views
        address payer;
        uint64 paidAt;
    }

    IERC20 public immutable token;
    IEIP3009 public immutable token3009;

    mapping(bytes32 invoiceId => Invoice) private _invoices;

    event InvoiceCreated(
        bytes32 indexed invoiceId, address indexed merchant, uint256 amount, uint64 expiry, bytes32 memoHash
    );
    event InvoicePaid(
        bytes32 indexed invoiceId, address indexed payer, address indexed merchant, uint256 amount, uint64 timestamp
    );
    event InvoiceCancelled(bytes32 indexed invoiceId, address indexed merchant);

    error InvoiceExists(bytes32 invoiceId);
    error InvoiceNotFound(bytes32 invoiceId);
    error InvoiceNotOpen(bytes32 invoiceId);
    error InvoiceExpired(bytes32 invoiceId);
    error NotMerchant(bytes32 invoiceId);
    error ZeroAmount();
    error ExpiryInPast();
    error TransferFailed();

    constructor(address token_) {
        token = IERC20(token_);
        token3009 = IEIP3009(token_);
    }

    // ------------------------------------------------------------------
    // Merchant
    // ------------------------------------------------------------------

    /// @notice Create an invoice. `invoiceId` must be unguessable (e.g. a
    ///         random bytes32 or a hash of merchant + invoice number + salt);
    ///         sequential ids could be claimed in advance by a third party.
    function createInvoice(bytes32 invoiceId, uint256 amount, bytes32 memoHash, uint64 expiry) external {
        if (amount == 0) revert ZeroAmount();
        if (expiry <= block.timestamp) revert ExpiryInPast();
        if (_invoices[invoiceId].status != Status.None) revert InvoiceExists(invoiceId);

        _invoices[invoiceId] = Invoice({
            merchant: msg.sender,
            amount: amount,
            expiry: expiry,
            memoHash: memoHash,
            status: Status.Open,
            payer: address(0),
            paidAt: 0
        });
        emit InvoiceCreated(invoiceId, msg.sender, amount, expiry, memoHash);
    }

    /// @notice Cancel an unpaid invoice. Only the merchant, only while open.
    function cancelInvoice(bytes32 invoiceId) external {
        Invoice storage inv = _getOpen(invoiceId);
        if (msg.sender != inv.merchant) revert NotMerchant(invoiceId);
        inv.status = Status.Cancelled;
        emit InvoiceCancelled(invoiceId, inv.merchant);
    }

    // ------------------------------------------------------------------
    // Payer — standard mode
    // ------------------------------------------------------------------

    /// @notice Pay an invoice with a prior ERC-20 approval. Funds move
    ///         directly from payer to merchant; the amount is taken from the
    ///         stored invoice, so underpayment is impossible.
    function payInvoice(bytes32 invoiceId) external {
        Invoice storage inv = _getPayable(invoiceId);
        inv.status = Status.Paid;
        inv.payer = msg.sender;
        inv.paidAt = uint64(block.timestamp);
        if (!token.transferFrom(msg.sender, inv.merchant, inv.amount)) revert TransferFailed();
        emit InvoicePaid(invoiceId, msg.sender, inv.merchant, inv.amount, uint64(block.timestamp));
    }

    // ------------------------------------------------------------------
    // Payer — gasless mode (EIP-3009)
    // ------------------------------------------------------------------

    /// @notice The nonce a payer must sign for this invoice. Binding the
    ///         authorization to one invoice id (and to this contract) means a
    ///         relayer cannot replay the signature against a different invoice.
    function authorizationNonce(bytes32 invoiceId) public view returns (bytes32) {
        return keccak256(abi.encode(invoiceId, address(this)));
    }

    /// @notice Pay an invoice with an EIP-3009 ReceiveWithAuthorization
    ///         signature. Anyone may relay the call; the payer needs no gas
    ///         token. The signed `to` must be this contract (EIP-3009 requires
    ///         the caller to be the payee); funds are forwarded to the
    ///         merchant in the same transaction.
    function payInvoiceWithAuthorization(
        bytes32 invoiceId,
        address from,
        uint256 validAfter,
        uint256 validBefore,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        Invoice storage inv = _getPayable(invoiceId);
        inv.status = Status.Paid;
        inv.payer = from;
        inv.paidAt = uint64(block.timestamp);

        token3009.receiveWithAuthorization(
            from, address(this), inv.amount, validAfter, validBefore, authorizationNonce(invoiceId), v, r, s
        );
        if (!token.transfer(inv.merchant, inv.amount)) revert TransferFailed();
        emit InvoicePaid(invoiceId, from, inv.merchant, inv.amount, uint64(block.timestamp));
    }

    // ------------------------------------------------------------------
    // Views — public verification
    // ------------------------------------------------------------------

    /// @notice Full invoice state. `status` reports Expired for open invoices
    ///         past their expiry, so verifiers never need to trust a backend.
    function invoiceStatus(bytes32 invoiceId)
        external
        view
        returns (
            Status status,
            address merchant,
            uint256 amount,
            uint64 expiry,
            bytes32 memoHash,
            address payer,
            uint64 paidAt
        )
    {
        Invoice storage inv = _invoices[invoiceId];
        status = inv.status;
        if (status == Status.Open && block.timestamp > inv.expiry) status = Status.Expired;
        return (status, inv.merchant, inv.amount, inv.expiry, inv.memoHash, inv.payer, inv.paidAt);
    }

    function isPaid(bytes32 invoiceId) external view returns (bool) {
        return _invoices[invoiceId].status == Status.Paid;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _getOpen(bytes32 invoiceId) internal view returns (Invoice storage inv) {
        inv = _invoices[invoiceId];
        if (inv.status == Status.None) revert InvoiceNotFound(invoiceId);
        if (inv.status != Status.Open) revert InvoiceNotOpen(invoiceId);
    }

    function _getPayable(bytes32 invoiceId) internal view returns (Invoice storage inv) {
        inv = _getOpen(invoiceId);
        if (block.timestamp > inv.expiry) revert InvoiceExpired(invoiceId);
    }
}
