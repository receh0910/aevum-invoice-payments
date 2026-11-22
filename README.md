# InvoicePayments — Aevum Builder Challenge #1

On-chain invoices for **tUSD8** on the QDay Aevum testnet (chain `44005`),
with two payment modes and public, on-chain receipts.

**Live on Aevum testnet:** [`0x92af365d48A7D5f6E23cE880BEe44F1445d76651`](https://explorer-test.qday.info/address/0x92af365d48A7D5f6E23cE880BEe44F1445d76651)
(token: tUSD8 `0x456569838f1d43009A91ebA4263147Afd7233483`)

## Problem & solution

Freelancers, agencies, and small merchants who invoice in stablecoins usually
have to trust a backend (or a screenshot) to know whether an invoice was
actually paid, paid in full, and paid on time. Amount checks are often done
off-chain, so "paid" can be faked or recorded with the wrong amount.

**InvoicePayments** puts the invoice itself on-chain:

- A merchant creates an invoice with an **exact amount**, an **expiry**, and a
  **memo hash** (hash of the off-chain invoice details). Invoice ids are
  unguessable `bytes32` values chosen by the merchant.
- The amount is enforced **by the contract**: the payable amount always comes
  from the stored invoice, so marking an invoice paid with less than the full
  amount (e.g. 1 base unit) is impossible.
- Every payment emits a public receipt event, and anyone can verify an
  invoice's status with a read-only call — no backend trust required.
- The contract **never custodies funds**: payments go directly from payer to
  merchant (the gasless path forwards atomically in the same transaction).

## Features

- **Exact-amount invoices** with expiry and memo hash; duplicate ids and
  zero-amount invoices are rejected.
- **Standard payment** — `approve` + `payInvoice`; funds move payer →
  merchant directly.
- **Gasless payment (EIP-3009)** — the payer signs a `ReceiveWithAuthorization`
  off-chain and anyone can relay `payInvoiceWithAuthorization`. The signed
  nonce is bound to the invoice id and this contract
  (`keccak256(invoiceId, contract)`), so a signature cannot be replayed
  against a different invoice. The payer pays no gas.
- **Public receipts** — `InvoicePaid(invoiceId, payer, merchant, amount,
  timestamp)` events; `invoiceStatus(invoiceId)` / `isPaid(invoiceId)` let
  anyone verify open / paid / cancelled / expired state.
- **Merchant controls** — unpaid invoices can be cancelled; expired invoices
  cannot be paid.
- **No custody** — contract token balance is always 0 after settlement
  (proven on-chain, see demo below).
- Small footprint: 2,980-byte runtime, cheap to deploy.

## Live deployment & demo proof (Aevum testnet)

Deployed and exercised end-to-end on the real Aevum testnet on 22 Nov 2026.
Invoice A (2 tUSD8) was paid via the standard path; invoice B (1 tUSD8) via
the gasless EIP-3009 path. Final on-chain verification: both invoices
`Paid`, merchant balance restored to 5 tUSD8, payer 0, contract 0.

| Step | Transaction |
|---|---|
| Deploy InvoicePayments | [`0xbc536176…d10d99c`](https://explorer-test.qday.info/tx/0xbc536176e2243bb1581d7aa31b93511ef2d7fa9dc41e98a8ba955b763d10d99c) |
| createInvoice A (2 tUSD8) | [`0xfb4d2f76…6d320a`](https://explorer-test.qday.info/tx/0xfb4d2f768a0d622d3ddf395ae72f9dc677c0973490001a463f3b0301de6d320a) |
| createInvoice B (1 tUSD8) | [`0x925d647a…72819`](https://explorer-test.qday.info/tx/0x925d647a1bae7d5030884d12992ec1c7da5f8cf53839530cf610c627bbed5f4a) |
| approve (payer) | [`0x599c8f0c…101033`](https://explorer-test.qday.info/tx/0x599c8f0c26f746d655eaca13ab8008bf6b0120091a9944a8a647b5fde1101033) |
| payInvoice A (standard) | [`0x803c67ad…420ab`](https://explorer-test.qday.info/tx/0x803c67ad60b73c5dcc2421aa0481929e57c9bbc18a899af843c5ef5bbc7420ab) |
| payInvoiceWithAuthorization B (gasless EIP-3009) | [`0x174ada36…4281`](https://explorer-test.qday.info/tx/0x174ada3602662b6395c4cf7c7046f2a72c90b4799ed842934e197766ac7e4281) |

Invoice ids: A `0x47ef503fa2ebd3c3581f63c77b281bff51a7320ea97a5fbae7415960427d6ed5`,
B `0xeaab59bdd9123538db2c36bf8eee43b3f1b307b889f0a5fbc74f603375c72819`.

Network: chain `44005`, RPC `https://rpc-test.qday.info`, explorer
`https://explorer-test.qday.info`. Aevum runs the Shanghai EVM (no Cancun
opcodes) and legacy (type 0) transactions. The explorer's contract verifier
is not working yet (per organizer docs), so this repository is the source of
record for the deployed bytecode.

## Build & test (no funds needed)

```bash
forge test        # 17 tests, local EVM (no forge-std dependency)
forge build --sizes
```

`foundry.toml` pins `evm_version = "shanghai"` and solc 0.8.24 — Cancun
bytecode deploys on Aevum and then reverts with `invalid opcode`.

The test suite covers: standard + gasless happy paths, exact-amount
enforcement (allowance short by 1 base unit reverts), double-pay reverts,
expired invoices revert (and the derived `Expired` view status), paying
exactly at the expiry boundary, merchant-only cancel, create guards (zero
amount / past expiry / duplicate id), signatures bound to the invoice
(wrong-invoice signature reverts), wrong-amount signature reverts, gasless
replay reverts, expired authorization reverts, wrong signer reverts, and the
mock's EIP-2612 permit.

## Deploy to Aevum testnet (needs tQDAY from the faucet)

```bash
forge script script/Deploy.s.sol:Deploy --rpc-url aevum --broadcast --legacy \
  --account <foundry-keystore-account>
```

Defaults to the real tUSD8 (`0x456569838f1d43009A91ebA4263147Afd7233483`);
override with the `TUSD8` env var.

## Run the demo flow

```bash
PAYMENTS=<deployed address> TOKEN=0x456569838f1d43009A91ebA4263147Afd7233483 \
MERCHANT_PK=<test key> PAYER_PK=<test key> \
forge script script/Demo.s.sol:Demo --rpc-url aevum --broadcast --legacy
```

`Demo.s.sol` creates two invoices (5 + 3 tUSD8), pays the first via the
standard path and the second gasless (payer signs, merchant relays), then
reads back both statuses. `DemoLive.s.sol` is the same flow sized for the
Discord faucet grant (2 + 1 tUSD8). Test wallets only; keys are read from
environment variables, never stored in this repo.

## Verify an invoice in the browser (no wallet)

`web/index.html` is a single-file, read-only verifier: open it in any browser,
paste an invoice id, and it calls `invoiceStatus()` on the deployed contract
through the public Aevum RPC and shows status, merchant, exact amount, payer,
and timestamps. Two buttons load the demo invoices above. No wallet, no
backend, no keys — verification is a plain `eth_call` anyone can repeat.

## Project structure

```
web/index.html              read-only browser verifier (eth_call via public RPC)
src/InvoicePayments.sol     the contract
src/mocks/MockUSD8.sol      local tUSD8 stand-in for tests (6 decimals,
                            EIP-712 domain "tUSD8"/"2", permit + EIP-3009)
test/InvoicePayments.t.sol  17 tests (no forge-std dependency)
script/Deploy.s.sol         deploy against real tUSD8 on Aevum
script/Demo.s.sol           end-to-end demo (5 + 3 tUSD8)
script/DemoLive.s.sol       end-to-end demo sized for the faucet grant (2 + 1 tUSD8)
foundry.toml                solc 0.8.24, evm_version = "shanghai", rpc endpoint "aevum"
```

No external dependencies: the cheatcode interface used by tests/scripts is
declared locally, so `forge build` works from a clean checkout with only
Foundry installed.

## Notes

- Design informed by the official Aevum Starter Kit (MIT, PQA Labs), in
  particular its EIP-3009 checkout pattern and its warning that example
  contracts must enforce exact amounts. This contract is an original
  implementation written for the challenge; no starter-kit code is included.
- EIP-3009 support on the real tUSD8 was verified directly
  (`authorizationState` / `DOMAIN_SEPARATOR` respond on-chain).

## License

MIT — see [LICENSE](LICENSE).
