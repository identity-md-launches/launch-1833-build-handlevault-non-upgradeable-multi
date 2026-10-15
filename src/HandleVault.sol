// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title HandleVault
/// @notice Non-upgradeable escrow addressed by opaque, off-chain salted recipient identifiers.
/// @dev An authorizer must verify handle control and the destination off-chain before signing.
/// An authorizer can redirect claims within the caps; the admin can rotate signers, raise caps,
/// set fees up to 1%, and control the allowlist. A production admin should be a Safe.
/// The per-token cap is one budget shared by every recipient, so any attested handle can consume
/// it by cycling deposits and claims at the cost of the fee; the admin-set recipient share bounds
/// what one handle can take per window and makes that cost scale with attested handles.
/// Pause prevents deposits and claims until a pauser unpauses; claimants cannot override it.
/// Refunds remain permissionless after 180 days and always pay the original sender in full.
/// Only non-rebasing, exact-transfer tokens are supported; incoming and outgoing transfers reject
/// balance deltas that differ from the requested amount. There are no bridge, upgrade, or arbitrary-call powers.
contract HandleVault is AccessControlDefaultAdminRules, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant AUTHORIZER_ROLE = keccak256("AUTHORIZER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant CLAIM_TYPEHASH =
        keccak256("Claim(bytes32 recipientId,address dest,uint256 nonce,uint256 deadline)");
    uint256 public constant MAX_DEPOSITS_PER_CLAIM = 64;
    /// @notice Deposits examined per claim, swept or skipped for not fitting a cap; bounds gas.
    uint256 public constant MAX_VISITS_PER_CLAIM = 256;
    uint256 public constant MAX_TOKENS_PER_CLAIM = 16;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Initial recipient share: one recipient may use the whole per-token cap per window.
    uint256 public constant DEFAULT_RECIPIENT_SHARE_BPS = 10_000;
    uint256 public constant MAX_PAGE_SIZE = 256;
    uint256 public constant OUTFLOW_WINDOW = 24 hours;
    uint256 public constant MAX_FEE_BPS = 100;
    uint256 public immutable REFUND_DELAY;

    enum Status {
        None,
        Open,
        Claimed,
        Refunded
    }

    struct Deposit {
        address sender;
        bytes32 recipientId;
        address token;
        uint256 amount;
        uint256 createdAt;
        Status status;
    }

    struct TokenConfig {
        bool allowed;
        uint256 minimum;
    }

    struct Queue {
        uint256 head;
        uint256 tail;
        uint256 count;
    }

    struct Links {
        uint256 previous;
        uint256 next;
        uint256 tokenPrevious;
        uint256 tokenNext;
    }

    struct OutflowCheckpoint {
        uint256 timestamp;
        uint256 cumulative;
    }

    struct SweepAccounting {
        uint256 available;
        uint256 gross;
        uint256 fees;
        uint256 visited;
    }

    uint256 public nextDepositId = 1;
    uint256 public feeBps;
    address public feeRecipient;
    /// @notice Share of each token's cap one recipient may claim per rolling window, in bps.
    uint256 public recipientShareBps = DEFAULT_RECIPIENT_SHARE_BPS;
    mapping(uint256 depositId => Deposit) public deposits;
    mapping(address token => TokenConfig) public tokenConfigs;
    mapping(address token => uint256) public outflowCaps;
    mapping(bytes32 recipientId => mapping(address token => uint256)) public totalEscrowed;
    mapping(address token => uint256) public totalOpen;
    mapping(address token => uint256) public accruedFees;
    mapping(bytes32 recipientId => mapping(uint256 nonce => bool)) public usedNonces;

    mapping(uint256 depositId => Links) private _links;
    mapping(bytes32 recipientId => Queue) private _recipientQueues;
    mapping(bytes32 recipientId => mapping(address token => Queue)) private _tokenQueues;
    /// @dev Keyed by the token for the shared window and by hash(recipientId, token) per recipient.
    mapping(bytes32 key => OutflowCheckpoint[]) private _outflows;

    error InvalidAddress();
    error InvalidMinimum();
    error TokenNotAllowed(address token);
    error UseNativeDeposit();
    error InvalidToken(address token);
    error BelowMinimum(uint256 minimum);
    error DepositExceedsCap(uint256 cap);
    error UnsupportedTransfer(address token);
    error InvalidTokenList();
    error DuplicateToken(address token);
    error ExpiredClaim();
    error NonceAlreadyUsed();
    error InvalidAuthorizer();
    error NothingToClaim();
    error OutflowCapExceeded();
    error DepositNotOpen();
    error RefundTooEarly(uint256 refundableAt);
    error NativeTransferFailed();
    error FeeTooHigh();
    error InvalidShare();
    error NoFees();
    error InvalidPageSize();
    error InvalidCursor();

    event Deposited(
        uint256 indexed depositId, bytes32 indexed recipientId, address indexed token, uint256 amount, address sender
    );
    event Claimed(
        uint256 indexed depositId,
        bytes32 indexed recipientId,
        address indexed token,
        uint256 amount,
        address dest,
        uint256 fee
    );
    event Refunded(
        uint256 indexed depositId, bytes32 indexed recipientId, address indexed token, uint256 amount, address sender
    );
    event TokenConfigured(address indexed token, bool allowed, uint256 minimum);
    event OutflowCapSet(address indexed token, uint256 oldCap, uint256 newCap);
    event FeeConfigured(uint256 feeBps, address indexed feeRecipient);
    event RecipientShareSet(uint256 oldShareBps, uint256 newShareBps);
    event DepositSkipped(uint256 indexed depositId, bytes32 indexed recipientId, address indexed token);
    event FeesWithdrawn(address indexed token, address indexed recipient, uint256 amount);
    event ClaimProcessed(bytes32 indexed recipientId, uint256 indexed nonce, address indexed dest, uint256 count);

    /// @param initialOwner Explicit launch owner, never inferred from the deploying factory.
    /// @param initialToken MockUSDC deployment address. No external calls are made in this constructor.
    /// @param nativeMinimum Minimum native deposit in wei.
    /// @param tokenMinimum Minimum MockUSDC deposit in its six-decimal base units.
    /// @param nativeCap Rolling native gross claim cap in wei.
    /// @param tokenCap Rolling MockUSDC gross claim cap in its base units.
    constructor(
        address initialOwner,
        address initialToken,
        uint256 nativeMinimum,
        uint256 tokenMinimum,
        uint256 nativeCap,
        uint256 tokenCap
    ) AccessControlDefaultAdminRules(1 days, initialOwner) EIP712("HandleVault", "1") {
        if (initialToken == address(0) || initialToken == address(this)) revert InvalidAddress();
        if (nativeMinimum == 0 || tokenMinimum == 0 || nativeCap < nativeMinimum || tokenCap < tokenMinimum) {
            revert InvalidMinimum();
        }
        REFUND_DELAY = 180 days;
        feeRecipient = initialOwner;
        _grantRole(AUTHORIZER_ROLE, initialOwner);
        _grantRole(PAUSER_ROLE, initialOwner);
        _configureToken(address(0), true, nativeMinimum);
        _configureToken(initialToken, true, tokenMinimum);
        _setOutflowCap(address(0), nativeCap);
        _setOutflowCap(initialToken, tokenCap);
        emit FeeConfigured(0, initialOwner);
        emit RecipientShareSet(0, DEFAULT_RECIPIENT_SHARE_BPS);
    }

    /// @notice Rejects fee-on-transfer deposits, recording exactly the requested amount.
    function depositFor(bytes32 recipientId, address token, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 depositId)
    {
        if (token == address(0)) revert UseNativeDeposit();
        _checkDeposit(token, amount);
        if (token.code.length == 0) revert InvalidToken(token);
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = IERC20(token).balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert UnsupportedTransfer(token);
        // Receipt must be measured before recording credit. The guard covers token callbacks.
        depositId = _recordDeposit(recipientId, token, amount);
    }

    function depositNativeFor(bytes32 recipientId)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 depositId)
    {
        _checkDeposit(address(0), msg.value);
        depositId = _recordDeposit(recipientId, address(0), msg.value);
    }

    /// @notice Relays an authorizer's attestation; pays up to 64 FIFO deposits across <=16 tokens.
    /// @dev Nonces are scoped to recipientId, shared across signers, and never reset on rotation.
    /// Tokens are intentionally not signed: a relayer may choose any subset/order but cannot
    /// change the recipient or destination. Continuations require a fresh nonce/signature.
    /// Skips, rather than stops at, a deposit that does not fit the token's remaining shared
    /// cap or the recipient's remaining share, so an oversized deposit parked ahead in the FIFO
    /// can never block the ones behind it. At most 256 deposits are examined per call.
    /// All accounting, nonce consumption, and queue removal precede outgoing transfers.
    function claim(
        bytes32 recipientId,
        address dest,
        address[] calldata tokens,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant whenNotPaused returns (uint256 count) {
        if (dest == address(0) || dest == address(this)) revert InvalidAddress();
        if (block.timestamp > deadline) revert ExpiredClaim();
        if (usedNonces[recipientId][nonce]) revert NonceAlreadyUsed();
        _checkTokens(tokens);
        (address signer, ECDSA.RecoverError err,) =
            ECDSA.tryRecover(claimDigest(recipientId, dest, nonce, deadline), signature);
        if (err != ECDSA.RecoverError.NoError || !hasRole(AUTHORIZER_ROLE, signer)) revert InvalidAuthorizer();
        usedNonces[recipientId][nonce] = true;

        uint256[] memory payouts = new uint256[](tokens.length);
        bool capBlocked;
        uint256 visited;
        uint256 currentFeeBps = feeBps;
        for (uint256 i; i < tokens.length && count < MAX_DEPOSITS_PER_CLAIM && visited < MAX_VISITS_PER_CLAIM; ++i) {
            (uint256 swept, uint256 seen, uint256 payout, bool blocked) = _sweep(
                recipientId,
                dest,
                tokens[i],
                MAX_DEPOSITS_PER_CLAIM - count,
                MAX_VISITS_PER_CLAIM - visited,
                currentFeeBps
            );
            count += swept;
            visited += seen;
            payouts[i] = payout;
            capBlocked = capBlocked || blocked;
        }
        if (count == 0) {
            if (capBlocked) revert OutflowCapExceeded();
            revert NothingToClaim();
        }
        emit ClaimProcessed(recipientId, nonce, dest, count);
        for (uint256 i; i < tokens.length; ++i) {
            if (payouts[i] != 0) _pay(tokens[i], dest, payouts[i]);
        }
    }

    /// @notice Anyone may return an expired open deposit to its original sender, even while paused.
    function refund(uint256 depositId) external nonReentrant {
        Deposit storage d = deposits[depositId];
        if (d.status != Status.Open) revert DepositNotOpen();
        uint256 refundableAt = d.createdAt + REFUND_DELAY;
        if (block.timestamp < refundableAt) revert RefundTooEarly(refundableAt);
        _closeDeposit(depositId, Status.Refunded);
        emit Refunded(depositId, d.recipientId, d.token, d.amount, d.sender);
        _pay(d.token, d.sender, d.amount);
    }

    /// @notice Pays only already-accrued claim fees to the currently configured fee recipient.
    /// @dev Permissionless, available while paused, and cannot spend open deposits. Gross fees
    /// were counted against the outflow cap when claimed; withdrawing them does not count twice.
    function withdrawFees(address token) external nonReentrant {
        uint256 amount = accruedFees[token];
        if (amount == 0) revert NoFees();
        address recipient = feeRecipient;
        accruedFees[token] = 0;
        emit FeesWithdrawn(token, recipient, amount);
        _pay(token, recipient, amount);
    }

    /// @notice Controls new deposits only. Disabling a token never disables claims or refunds.
    function setTokenConfig(address token, bool allowed, uint256 minimum) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _configureToken(token, allowed, minimum);
    }

    /// @notice Changes the gross claim limit without clearing any outflow history. Zero halts claims.
    /// @dev Lowering below an existing deposit can delay its claim until raised; refunds still work.
    function setOutflowCap(address token, uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setOutflowCap(token, cap);
    }

    /// @notice Sets the share of every token's cap that one recipient may claim per rolling window.
    /// @dev Applies to all tokens and existing deposits; it never clears any outflow history.
    /// New deposits are bounded by the resulting recipient cap so each one fits an empty window.
    /// Lowering it below an existing deposit delays that deposit until the share or cap is raised.
    function setRecipientShareBps(uint256 newShareBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newShareBps == 0 || newShareBps > BPS_DENOMINATOR) revert InvalidShare();
        emit RecipientShareSet(recipientShareBps, newShareBps);
        recipientShareBps = newShareBps;
    }

    /// @notice Fee changes affect future claims, including deposits made before the change.
    /// @dev The new recipient also receives any existing unpaid fees, never open principal.
    function setFee(uint256 newFeeBps, address newFeeRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (newFeeRecipient == address(0) || newFeeRecipient == address(this)) revert InvalidAddress();
        feeBps = newFeeBps;
        feeRecipient = newFeeRecipient;
        emit FeeConfigured(newFeeBps, newFeeRecipient);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Starts OpenZeppelin's delayed, two-step handover; zero-address handovers are disabled.
    /// @dev Operational roles and fee recipient do not automatically follow the default admin.
    function beginDefaultAdminTransfer(address newAdmin) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin == address(0) || newAdmin == address(this)) revert InvalidAddress();
        super.beginDefaultAdminTransfer(newAdmin);
    }

    function claimDigest(bytes32 recipientId, address dest, uint256 nonce, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(CLAIM_TYPEHASH, recipientId, dest, nonce, deadline)));
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function openDepositCount(bytes32 recipientId) external view returns (uint256) {
        return _recipientQueues[recipientId].count;
    }

    function firstOpenDeposit(bytes32 recipientId, address token) external view returns (uint256) {
        return _tokenQueues[recipientId][token].head;
    }

    /// @notice Cursor pagination over open deposits in insertion order, bounded to 256 entries.
    /// @param cursor Zero starts a page; otherwise the open deposit id returned as nextCursor.
    /// @dev Zero nextCursor means finished. Use one block tag for multiple pages. If a cursor
    /// has been closed between reads, restart at zero; closed history is never scanned.
    function getOpenDepositIds(bytes32 recipientId, uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 nextCursor)
    {
        if (limit == 0 || limit > MAX_PAGE_SIZE) revert InvalidPageSize();
        if (cursor == 0) {
            cursor = _recipientQueues[recipientId].head;
        } else if (deposits[cursor].recipientId != recipientId || deposits[cursor].status != Status.Open) {
            revert InvalidCursor();
        }
        ids = new uint256[](limit);
        uint256 length;
        while (cursor != 0 && length < limit) {
            ids[length++] = cursor;
            cursor = _links[cursor].next;
        }
        assembly ("memory-safe") {
            mstore(ids, length)
        }
        nextCursor = cursor;
    }

    /// @notice Gross claims in (block.timestamp - 24 hours, block.timestamp], including fees.
    /// @dev Exact sliding window, not fixed daily buckets. Binary search avoids linear cleanup
    /// of historical claims. Checkpoints at the same timestamp are coalesced.
    function rollingOutflow(address token) public view returns (uint256) {
        return _rolling(_tokenKey(token));
    }

    function remainingOutflow(address token) public view returns (uint256) {
        uint256 used = rollingOutflow(token);
        uint256 cap = outflowCaps[token];
        return used >= cap ? 0 : cap - used;
    }

    /// @notice Gross amount one recipient may claim of a token per rolling window: cap times share.
    function recipientCap(address token) public view returns (uint256) {
        return Math.mulDiv(outflowCaps[token], recipientShareBps, BPS_DENOMINATOR);
    }

    /// @notice Gross claims of one recipient in a token during the last 24 hours, including fees.
    function recipientRollingOutflow(bytes32 recipientId, address token) public view returns (uint256) {
        return _rolling(_recipientKey(recipientId, token));
    }

    /// @notice Capacity a claim for this recipient can use now: the lesser of both remaining windows.
    function recipientRemainingOutflow(bytes32 recipientId, address token) public view returns (uint256) {
        uint256 used = recipientRollingOutflow(recipientId, token);
        uint256 cap = recipientCap(token);
        uint256 own = used >= cap ? 0 : cap - used;
        return Math.min(own, remainingOutflow(token));
    }

    function _tokenKey(address token) private pure returns (bytes32) {
        return bytes32(uint256(uint160(token)));
    }

    function _recipientKey(bytes32 recipientId, address token) private pure returns (bytes32) {
        return keccak256(abi.encode(recipientId, token));
    }

    function _rolling(bytes32 key) private view returns (uint256) {
        OutflowCheckpoint[] storage history = _outflows[key];
        uint256 length = history.length;
        if (length == 0) return 0;
        uint256 cumulative = history[length - 1].cumulative;
        if (block.timestamp < OUTFLOW_WINDOW) return cumulative;
        uint256 cutoff = block.timestamp - OUTFLOW_WINDOW;
        uint256 low;
        uint256 high = length;
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (history[mid].timestamp <= cutoff) low = mid + 1;
            else high = mid;
        }
        // Lifetime totals may wrap. Modular subtraction is exact because accepted gross claims
        // within any live window never exceed a uint256 cap, even if lifetime volume does.
        unchecked {
            return cumulative - (low == 0 ? 0 : history[low - 1].cumulative);
        }
    }

    function _checkDeposit(address token, uint256 amount) private view {
        TokenConfig memory config = tokenConfigs[token];
        if (!config.allowed) revert TokenNotAllowed(token);
        if (amount == 0 || amount < config.minimum) revert BelowMinimum(config.minimum);
        // A deposit must fit the recipient's share of an empty window, so it is always claimable
        // once the windows clear; a larger one is skipped, never a blocker, until then.
        uint256 cap = recipientCap(token);
        if (amount > cap) revert DepositExceedsCap(cap);
    }

    function _configureToken(address token, bool allowed, uint256 minimum) private {
        if (token == address(this)) revert InvalidAddress();
        if (minimum == 0) revert InvalidMinimum();
        tokenConfigs[token] = TokenConfig(allowed, minimum);
        emit TokenConfigured(token, allowed, minimum);
    }

    function _setOutflowCap(address token, uint256 cap) private {
        uint256 old = outflowCaps[token];
        outflowCaps[token] = cap;
        emit OutflowCapSet(token, old, cap);
    }

    function _checkTokens(address[] calldata tokens) private pure {
        if (tokens.length == 0 || tokens.length > MAX_TOKENS_PER_CLAIM) revert InvalidTokenList();
        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (tokens[i] == tokens[j]) revert DuplicateToken(tokens[i]);
            }
        }
    }

    function _recordDeposit(bytes32 recipientId, address token, uint256 amount) private returns (uint256 id) {
        id = nextDepositId++;
        deposits[id] = Deposit(msg.sender, recipientId, token, amount, block.timestamp, Status.Open);
        Queue storage recipients = _recipientQueues[recipientId];
        Queue storage tokenQueue = _tokenQueues[recipientId][token];
        Links storage links = _links[id];
        links.previous = recipients.tail;
        links.tokenPrevious = tokenQueue.tail;
        if (recipients.tail == 0) recipients.head = id;
        else _links[recipients.tail].next = id;
        if (tokenQueue.tail == 0) tokenQueue.head = id;
        else _links[tokenQueue.tail].tokenNext = id;
        recipients.tail = id;
        tokenQueue.tail = id;
        ++recipients.count;
        ++tokenQueue.count;
        totalEscrowed[recipientId][token] += amount;
        totalOpen[token] += amount;
        emit Deposited(id, recipientId, token, amount, msg.sender);
    }

    function _closeDeposit(uint256 id, Status status) private {
        Deposit storage d = deposits[id];
        Links memory links = _links[id];
        Queue storage recipients = _recipientQueues[d.recipientId];
        Queue storage tokenQueue = _tokenQueues[d.recipientId][d.token];
        if (links.previous == 0) recipients.head = links.next;
        else _links[links.previous].next = links.next;
        if (links.next == 0) recipients.tail = links.previous;
        else _links[links.next].previous = links.previous;
        if (links.tokenPrevious == 0) tokenQueue.head = links.tokenNext;
        else _links[links.tokenPrevious].tokenNext = links.tokenNext;
        if (links.tokenNext == 0) tokenQueue.tail = links.tokenPrevious;
        else _links[links.tokenNext].tokenPrevious = links.tokenPrevious;
        --recipients.count;
        --tokenQueue.count;
        delete _links[id];
        d.status = status;
        totalEscrowed[d.recipientId][d.token] -= d.amount;
        totalOpen[d.token] -= d.amount;
    }

    /// @dev FIFO over the recipient's token queue. A deposit larger than the capacity left in this
    /// call is skipped and stays open; the walk continues behind it until a budget is spent.
    function _sweep(
        bytes32 recipientId,
        address dest,
        address token,
        uint256 budget,
        uint256 visitBudget,
        uint256 currentFeeBps
    ) private returns (uint256 count, uint256 visited, uint256 payout, bool blocked) {
        SweepAccounting memory accounting;
        accounting.available = recipientRemainingOutflow(recipientId, token);
        uint256 id = _tokenQueues[recipientId][token].head;
        while (id != 0 && count < budget && accounting.visited < visitBudget) {
            ++accounting.visited;
            uint256 next = _links[id].tokenNext;
            Deposit storage d = deposits[id];
            if (d.amount > accounting.available - accounting.gross) {
                blocked = true;
                emit DepositSkipped(id, recipientId, token);
            } else {
                uint256 fee = Math.mulDiv(d.amount, currentFeeBps, BPS_DENOMINATOR);
                accounting.gross += d.amount;
                accounting.fees += fee;
                _closeDeposit(id, Status.Claimed);
                emit Claimed(id, recipientId, token, d.amount, dest, fee);
                ++count;
            }
            id = next;
        }
        visited = accounting.visited;
        if (accounting.gross != 0) {
            accruedFees[token] += accounting.fees;
            _recordOutflow(_tokenKey(token), accounting.gross);
            _recordOutflow(_recipientKey(recipientId, token), accounting.gross);
            payout = accounting.gross - accounting.fees;
        }
    }

    function _recordOutflow(bytes32 key, uint256 amount) private {
        OutflowCheckpoint[] storage history = _outflows[key];
        uint256 length = history.length;
        if (length != 0 && history[length - 1].timestamp == block.timestamp) {
            unchecked {
                history[length - 1].cumulative += amount;
            }
        } else {
            uint256 previous = length == 0 ? 0 : history[length - 1].cumulative;
            unchecked {
                history.push(OutflowCheckpoint(block.timestamp, previous + amount));
            }
        }
    }

    function _pay(address token, address dest, uint256 amount) private {
        if (token == address(0)) {
            (bool success,) = payable(dest).call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            uint256 beforeVault = IERC20(token).balanceOf(address(this));
            uint256 beforeDest = IERC20(token).balanceOf(dest);
            IERC20(token).safeTransfer(dest, amount);
            uint256 afterVault = IERC20(token).balanceOf(address(this));
            uint256 afterDest = IERC20(token).balanceOf(dest);
            if (
                afterVault > beforeVault || beforeVault - afterVault != amount || afterDest < beforeDest
                    || afterDest - beforeDest != amount
            ) revert UnsupportedTransfer(token);
        }
    }
}
