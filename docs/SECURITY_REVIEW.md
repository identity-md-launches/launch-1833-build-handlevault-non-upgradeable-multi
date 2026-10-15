# Focused local review

This is a builder's review of the delivered implementation, not an independent audit or an assertion that all defects are excluded. An independent contributor must review the final source and deployment arguments before release.

## Custody boundaries

- The default admin is explicit constructor input; the factory never receives a role implicitly. Both constructors work without another deployed contract. All initial vault roles and fee rights go to the supplied owner.
- There is no upgrade, rescue, arbitrary call, bridge execution, approval to another spender, or privileged principal withdrawal. `withdrawFees` is bounded by separately recorded, already-earned fees.
- ECDSA validation binds recipient, destination, nonce, deadline, chain, and vault. Nonces survive role changes; an invalid/empty/reverted claim does not consume one. ERC-1271 is not supported.
- The signed type intentionally excludes token selection, amounts, and fee settings. A relayer can consume a signature on a subset; the authorizer must issue a fresh nonce for continuation. New deposits can enter the same signed scope before expiry. This follows the specified type and is documented, not hidden as stronger authorization.
- Both transfer branches use a reentrancy guard and checked interactions. Every outgoing batch commits all accounting first. Fee recipient failure is isolated from claims through pull accounting.

## Bounds and accounting

- FIFO doubly linked lists have constant-cost insertion/removal; claims process at most 64 records and 16 distinct tokens. Pagination traverses at most 256 open records and rejects stale cursors. Historical refunds/claims cannot create a scan backlog.
- A deposit cannot exceed the full configured cap. Claims stop at cap capacity before closing a record and can continue other tokens. Admin cap reductions may block an existing head; this is an explicit trusted power and cannot block timed refunds.
- Exact rolling cap accounting uses binary search over timestamp checkpoints. Changing caps never resets history. Gross fees count at claim time; refunds and fee collection do not consume the claim cap. Modular lifetime sums avoid permanently disabling claims after extreme cumulative volume; checked live-window limits make modular subtraction unambiguous.
- Incoming and outgoing ERC-20 balance-delta checks reject taxed transfers. Honest balance reporting, no rebasing/hooks, and continued transferability remain allowlist assumptions.
- Fee math rounds down per deposit and uses `Math.mulDiv`. Principal, accrued fees, and claimed/refunded statuses conserve funds. Direct token donations and forced ETH are surplus outside deposit accounting and have no withdrawal route.
- Boundary semantics: deadline equality is accepted; refund delay equality is accepted; a claim exactly 24 hours old no longer consumes capacity. Timestamp shifts can affect these boundaries; operators should avoid issuing signatures near expiry.

## Evidence and limitations

The Foundry suites exercise successful and failing claims/refunds, replay and domain attacks, revoked and unauthorized keys, high-s signatures, multi-token rollback, native receiver failures, token false/no-return behavior, taxed transfers, callbacks into guarded methods, maximum integer fee/counter cases, queue removal and continuation, and configuration/role authority.

The stateful model independently scans deposit and outflow records and checks payouts, statuses, balances, accrued fees, recipient totals, and paginated queues after randomized deposits, claims, refunds, fee collections, time changes, cap changes, pause changes, and allowlist changes. Test setup executes every principal flow to avoid a vacuous all-empty invariant. Fuzz/invariant tests are environment-independent and use the assignment's seed at invocation.

`Deployment.t.sol` also checks constructor configuration, explicit ownership, deployment with an address without code, runtime size, and absence of `DELEGATECALL`, `CALLCODE`, and `SELFDESTRUCT` opcodes, skipping PUSH data. The supplied protected deployment harness relies on deployment-service inputs and is left untouched; its final factory-address rehearsal belongs to that stage.

Local checks use Solidity 0.8.26 and Foundry, including its built-in compiler/lint diagnostics. Timestamp, external-call, and destination-control diagnostics were reviewed against the documented time rules, guarded checks-effects-interactions flow, ECDSA-bound destination, and fixed sender/fee-recipient paths. Solidity initializes local counters to zero; the owner zero check is performed by the inherited constructor. No Slither/Mythril execution, independent audit, public-network broadcast, explorer verification, or wallet operation is claimed.
