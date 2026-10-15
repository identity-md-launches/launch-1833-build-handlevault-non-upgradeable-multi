# HandleVault

Non-upgradeable multi-token escrow for opaque `bytes32 recipientId` values. The identifier is a salted hash computed off-chain: no handle, social profile, salt, or identity evidence is submitted to the vault. Each deposit keeps its own sender, identifier, currency, amount, timestamp, and status. Anyone can relay an authorized claim or a mature refund.

## Build and check

```sh
forge build
FOUNDRY_FUZZ_SEED=0x98cd57a930d7d0682b836422f53fa736e382d0858e0a2d8fa928fce0de643880 forge test
forge fmt --check
```

The root Foundry project pins Solidity **0.8.26**, Cancun, optimization at 200 runs, `via_ir = true`, and `bytecode_hash = "none"`. IR compilation is needed for the claim's structured accounting. OpenZeppelin Contracts **v5.2.0** and forge-std **v1.9.6** are vendored as ordinary files in `lib/`, with upstream licenses and archive hashes. Builds and tests need no network, environment secrets, submodules, FFI, or filesystem cheatcode permissions. Foundry and the pinned compiler must already be installed in an offline verifier.

The tests include independent EIP-712 encoding, domain and nonce separation, signer rotation, malformed/malleable signatures, multi-token/native paths, FIFO continuation, refunds, exact cap boundaries, fee rounding, allowlisting, pause, admin transfer, failed transfers, malicious callbacks, no-return ERC-20s, maximum amounts, and factory-independent constructor configuration. Stateful invariants compare deposits, balances, payouts, fees, queues, and rolling outflow with a separate linear reference model. Default settings are 512 runs per fuzz test and 128 invariant sequences of depth 96 with `fail_on_revert = true`.

## Sepolia deployment handoff

This assignment prepares the contracts for **IdentityMD's subsequent deployment stage**. The worker does not broadcast, access a wallet, or write `launch.json`. Confirmed application addresses do not exist in this deliverable; the launch service must record them here after successful deployment. Simulation addresses must never be published as Sepolia deployments.

| Item | Sepolia address / status |
| --- | --- |
| Chain | Sepolia, chain ID `11155111` |
| Launch owner, initial admin, authorizer, pauser, and fee recipient | `0xD58DCd4594087c2758717A59f44A5Ac09DB65105` |
| `MockUSDC` | Pending IdentityMD launch; use the confirmed deployment receipt |
| `HandleVault` | Pending IdentityMD launch; use the confirmed deployment receipt |

Deploy the two application contracts in this order, sending zero native value to each constructor:

1. `MockUSDC(address initialOwner)`: pass the owner above (`$owner` in the later manifest). It starts with zero supply. Only its owner can call `mint(to, amount)`; it has six decimals, name `Mock USDC`, symbol `mUSDC`, and two-step ownership transfer. It is test currency with no backing.
2. `HandleVault(address initialOwner, address initialToken, uint256 nativeMinimum, uint256 tokenMinimum, uint256 nativeCap, uint256 tokenCap)`: pass `$owner`, the newly deployed MockUSDC address, `100000000000000`, `1000000`, `10000000000000000000`, and `100000000000` respectively. Both currencies are enabled in the constructor. No initialization transactions are needed.

Constructors do not call the token or require code at its address, so deployment through a factory works on an empty chain. Ownership is never inferred from `msg.sender` or `tx.origin`. The application contracts have no proxies, delegatecalls, externally linked libraries, upgrade path, or arbitrary execution mechanism.

`script/DeployHandleVault.s.sol` provides the same parameters as named constants and a callable `deploy(owner)` function tested directly. `run()` is a Sepolia-only, **non-broadcasting rehearsal**. For a local rehearsal without RPC or a key:

```sh
forge script script/DeployHandleVault.s.sol:DeployHandleVault --chain-id 11155111
```

| Parameter | Initial value | Behavior |
| --- | --- | --- |
| Native minimum | `0.0001 ETH` (`10^14 wei`) | Admin-settable |
| MockUSDC minimum | `1 mUSDC` (`10^6` base units) | Admin-settable |
| Native claim cap | `10 ETH` (`10^19 wei`) | Per rolling 24 hours; admin-settable |
| MockUSDC claim cap | `100,000 mUSDC` (`10^11` base units) | Per rolling 24 hours; admin-settable |
| Recipient share of each cap | `10,000` bps (100%, `DEFAULT_RECIPIENT_SHARE_BPS`) | Per recipient and token, rolling 24 hours; admin-settable 1 to 10,000 bps |
| Maximum deposits examined per claim | `256` (`MAX_VISITS_PER_CLAIM`), swept or skipped | Constant |
| Claim fee | `0` basis points | Admin-settable, maximum `100` bps (1%) |
| Fee recipient | Launch owner | Admin-settable; zero and vault itself rejected |
| Refund delay | `180 days` = `15,552,000` seconds | Immutable |
| Initial admin handover delay | `1 day` | OpenZeppelin scheduled delay changes |
| Maximum deposits per claim | `64` across all listed tokens | Constant |
| Maximum tokens per claim | `16`, with no duplicates | Constant |
| Maximum page size | `256` | Constant |

The caps and minimums are testnet operating choices, not asset price assumptions. All amounts are raw base units of each token; the vault never normalizes or queries decimals.

## Deposits and views

- `depositFor(recipientId, token, amount)` pulls an approved ERC-20 amount from the caller. Approve the intended amount first. `depositNativeFor(recipientId)` records `msg.value`. Both return a monotonically increasing ID starting at 1 and emit `Deposited(depositId, recipientId, token, amount, sender)`.
- **Native ETH is represented by `address(0)` in currency lists and views.** It is a currency sentinel, not a deployment or recipient address. Use the payable native entry point for deposits. Plain ETH transfers and unknown selectors revert.
- New deposits require an enabled token, a positive amount at least its minimum, and an amount no greater than `recipientCap(token)`, the token's claim cap times the recipient share (equal to the full cap at the initial 100% share). This guarantees every accepted deposit fits an empty window, so it is always claimable once the windows clear. It uses the configured capacity, not the currently remaining capacity. Setting a cap to zero also stops new deposits for that token.
- `deposits(id)` returns `(sender, recipientId, token, amount, createdAt, status)`. Status values are `None=0`, `Open=1`, `Claimed=2`, `Refunded=3`. Closed records remain available permanently.
- `totalEscrowed(recipientId, token)` reports open principal for that pair; `totalOpen(token)` reports all open principal. `openDepositCount(recipientId)` and `firstOpenDeposit(recipientId, token)` support continuation planning.
- `getOpenDepositIds(recipientId, cursor, limit)` returns `(ids, nextCursor)`. Start at cursor 0; use the returned cursor for the next page. A zero returned cursor means finished. The cursor is an inclusive open deposit ID, not an offset. Use the same block tag across pages. If the cursor is claimed/refunded between reads, the call rejects it and the client should restart. Only open records are traversed; history does not increase pagination work.

The vault accepts arbitrary `bytes32` identifiers, including zero, without pretending to know whether an off-chain identity exists. Consistent normalization, domain separation of handles, unpredictable salts, retention of the identifier mapping, and protection of the off-chain database belong to the identity service. Opaque identifiers still link all deposits using that same ID publicly.

## Claim signing and relaying

The authorizer must verify both control of the handle represented by `recipientId` and the intended destination **off-chain**. The claimant does not need an on-chain wallet to create the original deposit; a destination is required at claim time. Authorized signers are ECDSA EOAs. Safe administration is supported, but ERC-1271 contract signatures are not implemented in v1.

The exact [EIP-712](https://eips.ethereum.org/EIPS/eip-712) domain is:

```text
name:              HandleVault
version:           1
chainId:           11155111                  (Sepolia)
verifyingContract: the confirmed HandleVault deployment address
```

The domain contains **no salt**. The hash for the domain type string
`EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)` is:

```text
0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f
```

The primary type is `Claim`, with exactly these fields in this order:

```text
Claim(bytes32 recipientId,address dest,uint256 nonce,uint256 deadline)
CLAIM_TYPEHASH = 0x1864f171689e98e3f2f87c8a15907d4fb03045729017118057305c1e0d842410
```

```text
domainSeparator = keccak256(abi.encode(
    DOMAIN_TYPEHASH, keccak256("HandleVault"), keccak256("1"), chainId, vaultAddress
))
structHash = keccak256(abi.encode(CLAIM_TYPEHASH, recipientId, dest, nonce, deadline))
digest = keccak256(0x1901 || domainSeparator || structHash)
```

Use typed-data signing, **not** personal-sign / `signMessage`. Send a 65-byte `r || s || v` signature with low `s` and `v` of 27 or 28. The contract exposes `CLAIM_TYPEHASH()`, `domainSeparator()`, `claimDigest(...)`, and the OpenZeppelin EIP-5267 `eip712Domain()` view for checking the integration. The domain uses the runtime chain ID and vault address, so signatures cannot cross chains or instances.

For an off-chain client already using ethers v6, the complete signing shape is:

```js
// vaultAddress and dest must be real addresses; recipientId comes from the identity service.
const domain = { name: "HandleVault", version: "1", chainId: 11155111n,
                 verifyingContract: vaultAddress };
const types = { Claim: [
  { name: "recipientId", type: "bytes32" },
  { name: "dest", type: "address" },
  { name: "nonce", type: "uint256" },
  { name: "deadline", type: "uint256" },
] };
const message = { recipientId, dest, nonce: BigInt(nonce), deadline: BigInt(deadline) };
const signature = await authorizer.signTypedData(domain, types, message);
// A separate relayer can submit this. Keep uint256 values as bigint/decimal strings.
await vault.connect(relayer).claim(recipientId, dest, tokens, message.nonce,
                                  message.deadline, signature);
```

This snippet documents integration and adds no JavaScript build dependency to the Foundry project. The signer integration must supply its own signing service, library, and wallet custody.

Nonces are arbitrary `uint256` values scoped to the recipient ID, **shared by all authorizers**, and permanently consumed by a successful nonempty claim. They are not a global sequence, do not reset when signers rotate, and cannot be reused for another token batch. `usedNonces(recipientId, nonce)` is public. Coordinate nonce allocation across authorizers; issue fresh, short-lived signatures for continuations. A reverted claim does not burn its nonce. A deadline equal to the block timestamp is valid; a later timestamp rejects it.

Anyone can call `claim(recipientId, dest, tokens, nonce, deadline, signature)`. The relayer receives no funds. Zero or self-vault destinations are rejected. The caller chooses the token subset and order: **tokens, amounts, individual deposit IDs, and fee rate are deliberately absent from the requested signed type**. A relayer can consume the nonce on a smaller valid subset, or include deposits arriving before execution, but cannot change the signed recipient or destination. A fresh signature is needed for any remaining balance. The signer should choose short deadlines and avoid issuing several outstanding destinations for one recipient.

Each selected token's queue is FIFO. A call processes at most 64 deposits total, then the caller continues with a fresh signature. A deposit that does not fit the capacity left for this call (the lesser of the token's remaining shared cap and the recipient's remaining share, minus what the call has already swept) is **skipped, not a stop**: it stays open, emits `DepositSkipped(depositId, recipientId, token)`, and the walk continues to the deposits behind it, so an oversized deposit parked at the head of a recipient's queue can never make the deposits behind it unclaimable. A call examines at most 256 deposits across all listed tokens, swept or skipped, and continues with other listed tokens. If nothing can be processed, the call reverts with `NothingToClaim` or `OutflowCapExceeded` and the nonce stays unused. A deposit is never split or partially marked claimed. Every processed record emits `Claimed(depositId, recipientId, token, grossAmount, dest, fee)`; `ClaimProcessed` identifies the nonce and processed count.

The visit bound is the gas limit of a claim, and a griefer who parks more than 256 deposits that do not fit the current window ahead of a victim's deposit delays it until the windows clear; each parked deposit must exceed the capacity the victim's claim would otherwise have, is locked for 180 days, and is a visible `DepositSkipped` pattern the operator can act on. Listing tokens in a different order spends the budget differently.

Claim work is bounded by the token/deposit limits and logarithmic outflow-history lookups. Closing a deposit unlinks it in constant time from both queues. Spamming deposits or retaining years of closed records cannot force a full-history scan. Successful delivery still requires a live authorizer, unpaused vault, available cap capacity, and transferable assets.

## Rolling caps, fees, and refunds

`rollingOutflow(token)` counts **gross claimed amounts, including fees**, in `(now - 86,400 seconds, now]`. `remainingOutflow(token)` reports the remaining capacity, clamped to zero. These are exact sliding windows, not calendar-day resets or approximate buckets. Cumulative checkpoints coalesce claims sharing a timestamp and binary search locates expired history. Lifetime totals use modular counters; the live-window cap ensures their difference remains exact even across a lifetime counter wrap.

`setOutflowCap(token, cap)` never clears history. Reducing a cap below current usage stops claims until enough usage expires. Reducing it below an existing individual deposit leaves that deposit open and skipped (the deposits behind it still flow) until the admin raises the cap; the original sender retains the timed refund path. Re-enabling a token or raising/lowering its cap cannot reset prior outflow.

### Shared budget and the recipient share

The per-token cap is **one budget shared by every recipient**, which is what bounds a compromised authorizer. The flip side is that any attested handle can consume it: a user who controls a handle deposits to it and claims straight back, paying only the fee (nothing at the initial 0 bps), and every other recipient's claim in that token then waits for the window to roll. Two wallets make the cycle look like ordinary traffic, so the on-chain admin cannot tell it apart; only the operator's off-chain view (the same handle cycling the cap each day) can.

`recipientShareBps` is the admin's lever against that. Each (recipient, token) pair has its own exact rolling 24-hour window, `recipientRollingOutflow(recipientId, token)`, bounded by `recipientCap(token) = cap × share / 10,000`; a claim uses the lesser of the two remaining windows, `recipientRemainingOutflow(recipientId, token)`. At the initial 100% share the recipient window never binds before the shared one and behaviour is exactly the single-cap design the brief describes. At, for example, 2,500 bps one handle can take at most a quarter of the window per day, so exhausting the cap needs four attested handles, each a verified social identity the operator can stop signing for. New deposits are bounded by `recipientCap(token)`, so lowering the share also lowers the largest accepted deposit; lowering it below an already open deposit leaves that deposit skipped until the share or cap is raised, never affecting its refund. The share applies to all tokens, changes affect future claims only, and no change clears any window. Set it with `setRecipientShareBps(bps)` (1 to 10,000); it emits `RecipientShareSet`.

The share is initially 100% rather than lower because the deployment parameters were reviewed against a 100,000 mUSDC single deposit being accepted, and a deposit larger than the recipient cap would never be claimable. A legitimate recipient who receives more than its share in a day claims the rest after roll-over.

Fees are `floor(deposit.amount * feeBps / 10_000)` **per deposit** using overflow-safe multiplication/division. Fractional dust stays with the claimant. Changing the fee affects existing deposits when they are later claimed. Net proceeds go to the signed destination; fees accrue separately in `accruedFees(token)`.

Anyone can call `withdrawFees(token)` to pay only that accrued amount to the current `feeRecipient`, even while paused. The recipient never receives principal via this function. Changing the fee recipient also redirects fees accrued earlier. A fee recipient that cannot receive ETH cannot block a claim; its fee withdrawal reverts and can be retried after the admin changes the recipient or it can accept payments. Fees were charged to the cap at claim time and are not counted again on withdrawal.

`refund(depositId)` is permissionless at or after `createdAt + REFUND_DELAY`. It closes the open deposit and returns its **full amount to the original sender**, never to the caller, irrespective of pause, allowlist changes, cap settings, or fees. It emits `Refunded`. Refunds do not consume claim cap capacity. There is no automatic refund or bounty. Mature deposits remain claimable until refunded; the first successfully included claim/refund wins. Claimed/refunded/nonexistent records cannot be refunded again. A sender that cannot accept its refund must correct its receiving behavior; funds cannot be redirected by an admin.

## Safety and accounting assumptions

OpenZeppelin `ReentrancyGuard` covers all entry points that move funds. Claims consume the nonce, close records, adjust all token liabilities/caps/fees, and emit events before any outgoing transfer. Refunds and fee withdrawals also settle state before transfer. Token receipt must be measured before recording a deposit, with the guard protecting that interaction. Native payouts use `call` and check success. Any failed payout reverts the entire claim, including earlier token payouts, accounting, events, and nonce consumption.

The allowlist is for **reviewed, non-rebasing, exact-transfer ERC-20s**. `SafeERC20` supports standard true returns and no-return tokens and rejects false returns. Incoming vault balance deltas must equal the requested amount; outgoing vault debits and recipient credits must both equal the payout. Transfer-tax, sender-surcharge, rebasing, reflection, and transfer-hook tokens are unsupported. These checks do not make a malicious token trustworthy: a token can lie about balances, change behavior, pause transfers, or blocklist an account. Such token failures can prevent both claims and refunds until the token itself permits transfers. A claimant can exclude a broken token and claim the others.

For every supported token, under protocol-mediated operations:

```text
vault balance = sum(amount of all Open deposits) + accruedFees(token)
```

The invariant suite checks this equality against individual records and an independent model. Unsolicited ERC-20 transfers and forced native credits are possible on Ethereum, so under those external donations the true relationship is `balance = open principal + accrued fees + unsolicited surplus`. This unavoidable exception is tested explicitly. Direct transfers create no claim/refund record; surplus remains locked. No admin sweep or recovery function can reclassify it as fees.

## Roles and operational responsibilities

The [OpenZeppelin admin rules](https://docs.openzeppelin.com/contracts/5.x/access-control) enforce a single `DEFAULT_ADMIN_ROLE` holder and a delayed two-step handover. The current admin calls `beginDefaultAdminTransfer(newAdmin)`; after the scheduled time has passed, the nominated account calls `acceptDefaultAdminTransfer()`. The current admin can cancel before acceptance. Use `pendingDefaultAdmin()` to obtain the schedule. Zero/vault handovers and direct grant/revoke of the default-admin role are rejected; default-admin renunciation is consequently disabled. OpenZeppelin's scheduled delay-change and rollback methods remain available.

| Role | Powers and trust |
| --- | --- |
| `DEFAULT_ADMIN_ROLE` | Manage allowlist/minimums, raise or lower caps, set the recipient share, set fee up to 1%, choose fee recipient, grant/revoke operational roles, schedule admin/delay changes. Should be a Safe in production. |
| `AUTHORIZER_ROLE` | Attest off-chain identity and destination via ECDSA. Can redirect claims if compromised; current caps bound gross claims per currency while the admin has not raised them. |
| `PAUSER_ROLE` | Pause and unpause deposits and claims. A claimant cannot bypass or end pause. Refunds and accrued-fee withdrawals remain callable. |
| MockUSDC owner | Mint test currency and transfer its mint authority via two steps; has no special vault withdrawal permission. |

There is no privileged escrow withdrawal: principal exits only through a valid signed claim or a refund to its original sender. **Admin and authorizer trust remain material**: an admin can grant itself signing rights and raise caps; an admin-authorizer compromise is not bounded by immutable caps. An admin can increase fees to 1% on already-deposited funds. A pauser can keep claimants waiting until unpaused, although refunds eventually remain available to senders. The initial owner holds all three roles as requested.

### After launch

1. The deployment service records both confirmed Sepolia addresses above, verifies source/constructor arguments, and publishes the vault's on-chain EIP-712 domain. The signer must use that confirmed vault address, never a simulation result.
2. The owner mints desired test balances through `MockUSDC.mint(to, amount)`. There is no automatic initial allocation.
3. The identity operator verifies handle control and destination off-chain, protects the salted-ID mapping, coordinates nonces, uses short deadlines, and monitors redemptions. The current owner wallet is initially authorized; no unspecified backend signer is hardcoded. To rotate, the admin obtains the actual public address from its signing service, calls `grantRole(AUTHORIZER_ROLE, newSigner)`, then `revokeRole(AUTHORIZER_ROLE, oldSigner)`. Revocation invalidates unconsumed signatures from that key; regranting the same key can revive still-unexpired ones.
4. Before any production use, transfer default administration to the organization's selected Safe using the two-step flow. Admin transfer does **not** transfer authorizer/pauser roles, fee recipient, or MockUSDC ownership. Explicitly rotate/revoke those roles and update `setFee` and token ownership as appropriate. Give an EOA signing service the authorizer role if the admin is a Safe.
5. Monitor `Deposited`, `Claimed`, `DepositSkipped`, `Refunded`, `ClaimProcessed`, cap/fee/config/share changes, pause events, and role events. Choose caps small enough to bound authorizer compromise; keep minimums meaningful for spam cost. Once the vault has several real recipients, lower `recipientShareBps` (a quarter of the cap is a reasonable starting point) so one handle cannot consume the shared window, and stop signing for a handle that cycles deposits and claims to exhaust it. New tokens require both `setTokenConfig(token, true, minimum)` and `setOutflowCap(token, cap)` with reviewed units and behavior. Review pending large deposits before lowering caps.
6. On a signer incident, pause claims, revoke the key, investigate, rotate, then unpause with an authorized pauser. Account for the still-running refund clock and rolling cap history. Relayers pay gas without compensation from the vault; arrange sponsorship off-chain. Schedule mature refunds explicitly if desired.
7. Complete the network's independent adversarial review before release. Passing tests and the focused local review in `docs/SECURITY_REVIEW.md` do not constitute an independent audit.

## Deferred integrations

`src/interfaces/IFutureHandleVault.sol` is an **unimplemented interface hook** for a future `claimTo` bridge flow. The deployed vault cannot call adapters. A future, separately deployed version must sign the adapter, destination chain/recipient, and bridge payload under a new EIP-712 type/domain and define bridge failure/refund behavior.

ERC-4337 sponsorship can wrap the existing permissionless `claim` from an external smart account/paymaster integration; no EntryPoint, trusted forwarder, paymaster, or paymaster funds are embedded here. There is no mutable integration switch.

Multichain same-address deployment is left to a future deployment layer (factory, salts, and identical constructor configuration). This release promises no cross-chain address equality; chain-bound domains prevent cross-chain claim replay. Non-upgradeability means adding contract logic requires a new vault and deliberate client migration, while this vault keeps its existing refund obligations.
