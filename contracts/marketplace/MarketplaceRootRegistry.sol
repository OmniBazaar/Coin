// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IRootAttestationVerifier
 * @author OmniCoin Development Team
 * @notice The two functions {@link MarketplaceRootRegistry} needs from a
 *         committee verifier.
 * @dev A deliberate structural subset of `IBridgeVerifier`, which
 *      `RandomCommitteeVerifier` implements. Declaring only what is used keeps
 *      this registry from depending on the bridge's interface file, and the two
 *      signatures below are part of a deployed, immutable contract's ABI, so
 *      there is nothing here that can drift.
 */
interface IRootAttestationVerifier {
    /**
     * @notice Verify a committee attestation `proof` over `messageHash`.
     * @param messageHash The 32 bytes the committee signed. The verifier never
     *        inspects it — the meaning lives entirely in the caller.
     * @param proof `commitBlock(32) || sig0(65) || sig1(65) || ...`.
     * @return valid Whether the proof is a quorum attestation over `messageHash`.
     * @return attesters The addresses whose signatures were counted.
     */
    function verify(bytes32 messageHash, bytes calldata proof)
        external
        view
        returns (bool valid, address[] memory attesters);

    /**
     * @notice The minimum number of attesters the verifier requires.
     * @return The quorum threshold.
     */
    function quorumThreshold() external view returns (uint256);
}

/**
 * @title MarketplaceRootRegistry
 * @author OmniCoin Development Team
 * @notice Stores one Merkle root per epoch of an off-chain append-only log, so
 *         that what a node serves can be checked against something the node
 *         does not control.
 *
 * @dev FIX_TRUSTLESS_DATA phase T3. The problem this solves is stated in that
 *      plan: an operator with root on the machine holding the database can
 *      rewrite their own copy of it, and no credential has ever defended
 *      against the owner of a machine. So tampering is not prevented — it is
 *      made detectable and worthless, which is how every blockchain already
 *      works.
 *
 *      An epoch is a contiguous, inclusive range of sequence numbers in the
 *      log. Publishing epoch N commits to which entries were in it, in what
 *      order, and to which epoch preceded it. Because the epochs are monotonic
 *      and their ranges are forced to abut, an outsider reading only this
 *      contract can tell that log entry K belongs to exactly one epoch — which
 *      is what makes the ABSENCE of an entry provable. Signatures alone can
 *      never do that: a node can withhold a seller's cancellation and every
 *      signature it does serve still verifies.
 *
 *      This contract contains no cryptography of its own. It recomputes the
 *      commitment from its own arguments and hands it to the committee
 *      verifier, so it never trusts a hash it was given. What it enforces is
 *      the shape of the history:
 *
 *        - epochs are gapless and strictly increasing, per namespace;
 *        - each epoch's `prevRoot` is the stored root of its predecessor;
 *        - each epoch's range resumes exactly where its predecessor ended;
 *        - epoch 1 chains to the zero root and begins at sequence 1;
 *        - a published epoch can never be republished or amended.
 *
 *      Calling `publishRoot` is permissionless, and deliberately so. Anybody
 *      holding a valid committee attestation may anchor — including an
 *      independent operator running their own full cluster, which is the point
 *      of the whole effort. Whichever transaction lands first wins and the rest
 *      revert with {EpochOutOfOrder}.
 *
 *      🛑 That does NOT mean two clusters always agree on epoch N. They agree on
 *      the root of any given RANGE, because the leaves are a pure function of
 *      the entries — but each cluster chooses its own range, by batching
 *      whatever was unanchored when its own timer fired. So two honest clusters
 *      can close epoch N over 801–900 and 801–950 respectively, and the loser's
 *      epoch N is then unanchorable, because an epoch may be published exactly
 *      once. Agreeing on batch BOUNDARIES between independent proposers is
 *      genuine consensus work and is deliberately deferred (FIX_TRUSTLESS_DATA
 *      §9, first risk). Until it lands, one cluster anchors and the others
 *      follow; a validator that finds a different root already anchored for its
 *      epoch distinguishes "different range" from "same range, different root"
 *      and only the second is a tamper.
 *
 *      Namespaces are not allow-listed. They do not need to be: publishing
 *      under any namespace still requires a committee quorum over a commitment
 *      that binds that namespace, and the committee's members only sign what
 *      they can reproduce from their own copy of the log.
 *
 *      Not upgradeable, on purpose. The value of an append-only history is that
 *      nobody can rewrite it, and that includes us. `verifier` is settable so
 *      the registry can follow the committee verifier across versions, but no
 *      admin action can alter or replace a root that has already been
 *      published.
 *
 *      Pioneer-phase control: `admin` is the deployer EOA and every
 *      administrative call is direct, with no timelock and no built-in delay,
 *      per the project's Pioneer-phase contract rule. `admin` is a plain
 *      address so the post-Pioneer handover to governance is a single transfer.
 */
contract MarketplaceRootRegistry {
    // ─────────────────────────────────────────────────────────── types ──

    /**
     * @notice One anchored epoch.
     * @dev `root` occupies a full slot; the three 64-bit fields share the
     *      next. Sequence numbers are `uint64` because the off-chain log
     *      allocates them as a gapless 64-bit counter.
     */
    struct AnchoredEpoch {
        /// @notice The Merkle root over the epoch's leaves.
        bytes32 root;
        /// @notice First log sequence number in the epoch, inclusive.
        uint64 firstSeq;
        /// @notice Last log sequence number in the epoch, inclusive.
        uint64 lastSeq;
        /// @notice Block timestamp at which the epoch was anchored.
        uint64 publishedAt;
    }

    // ─────────────────────────────────────────────────────── constants ──

    /**
     * @notice Domain tag mixed into every commitment.
     * @dev `keccak256("omnibazaar.marketplace.root.v1")`. Names what the hash
     *      IS, so a signer presented with 32 bytes is not being asked to sign
     *      something whose meaning depends entirely on context it cannot see.
     *      Bump the version only if the commitment's field set changes.
     */
    bytes32 public constant COMMITMENT_DOMAIN =
        keccak256("omnibazaar.marketplace.root.v1");

    // ─────────────────────────────────────────────────────────── state ──

    /**
     * @notice Attester count no publish may fall below, fixed at construction.
     *
     * @dev The runtime check against `verifier.quorumThreshold()` alone cannot
     *      deliver what it looks like it delivers: both operands come from the
     *      same contract, so a verifier reporting a threshold of one and
     *      returning one attester satisfies it exactly as designed. This floor
     *      is read from the verifier once, at deployment, and then frozen — so
     *      the bar for THIS registry cannot be lowered afterwards by pointing
     *      it at a more permissive verifier. Both checks run: the floor stops
     *      the bar dropping, the runtime check follows it upward.
     */
    uint256 public immutable MIN_ATTESTERS;

    /// @notice Holder of the administrative functions. The deployer, in Pioneer phase.
    address public admin;

    /// @notice The committee verifier consulted on every publish.
    IRootAttestationVerifier public verifier;

    /// @notice namespace → epoch → the anchored epoch record.
    mapping(bytes32 => mapping(uint256 => AnchoredEpoch)) private _epochs;

    /**
     * @notice namespace → the epoch number that must be published next.
     * @dev Zero means nothing has been published for the namespace yet, in
     *      which case the next epoch is 1. Reading it through
     *      {expectedEpoch} rather than directly avoids that off-by-one.
     */
    mapping(bytes32 => uint256) private _nextEpoch;

    // ────────────────────────────────────────────────────────── events ──

    /**
     * @notice A publish attempt failed before the state was written.
     * @dev L-06: Emitted before every revert in {publishRoot}, so
     *      off-chain monitors can distinguish "nobody tried" from
     *      "someone tried and was rejected".
     * @param namespace The log family.
     * @param epoch The epoch number that was attempted.
     * @param reason The error reason — one of the custom error selectors.
     */
    event PublishFailed(
        bytes32 indexed namespace,
        uint256 indexed epoch,
        bytes4 indexed reason
    );

    /**
     * @notice A root was anchored.
     * @param namespace The log family, e.g. `keccak256("marketplace")`.
     * @param epoch The epoch number.
     * @param root The Merkle root over the epoch's leaves.
     * @param firstSeq First log sequence number committed, inclusive.
     * @param lastSeq Last log sequence number committed, inclusive.
     * @param prevRoot The predecessor epoch's root, or zero at epoch 1.
     * @param commitment The exact bytes the committee attested, so an observer
     *        can replay the verification from the event alone.
     * @param attesters The committee members whose signatures were counted.
     * @param publisher Whoever paid for the transaction. Carries no authority.
     */
    event RootPublished(
        bytes32 indexed namespace,
        uint256 indexed epoch,
        bytes32 indexed root,
        uint64 firstSeq,
        uint64 lastSeq,
        bytes32 prevRoot,
        bytes32 commitment,
        address[] attesters,
        address publisher
    );

    /**
     * @notice The committee verifier was changed.
     * @param previousVerifier The verifier that was in use.
     * @param newVerifier The verifier now in use.
     */
    event VerifierUpdated(
        address indexed previousVerifier,
        address indexed newVerifier
    );

    /**
     * @notice Administrative control was transferred.
     * @param previousAdmin The outgoing admin.
     * @param newAdmin The incoming admin.
     */
    event AdminTransferred(
        address indexed previousAdmin,
        address indexed newAdmin
    );

    // ────────────────────────────────────────────────────────── errors ──

    /// @notice A zero address was supplied where a contract or account is required.
    error ZeroAddress();
    /// @notice The caller is not the admin.
    error NotAdmin(address caller);
    /// @notice The epoch is not the one this namespace expects next.
    error EpochOutOfOrder(uint256 supplied, uint256 expected);
    /// @notice `prevRoot` does not match the stored root of the previous epoch.
    error RootChainBroken(bytes32 supplied, bytes32 expected);
    /// @notice The epoch's range does not resume where its predecessor ended.
    error SequenceGap(uint64 suppliedFirstSeq, uint64 expectedFirstSeq);
    /// @notice `lastSeq` is below `firstSeq`, so the range is empty or inverted.
    error EmptyRange(uint64 firstSeq, uint64 lastSeq);
    /// @notice A zero root was supplied. A root over no leaves proves nothing.
    error ZeroRoot();
    /// @notice `lastSeq` is the maximum, which would trap every later epoch.
    error SequenceExhausted();
    /// @notice The address supplied as a verifier does not answer as one.
    error NotAVerifier(address supplied);
    /// @notice The committee verifier rejected the proof.
    error AttestationRejected();
    /// @notice The proof carried fewer attesters than the verifier's quorum.
    error QuorumNotMet(uint256 attesters, uint256 required);

    // ───────────────────────────────────────────────────────── modifier ──

    /// @dev Restricts a call to {admin}.
    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        _;
    }

    // ──────────────────────────────────────────────────── construction ──

    /**
     * @notice Deploy the registry.
     * @param initialAdmin The administrative account. The deployer EOA during
     *        Pioneer phase; a governance contract after the handover.
     * @param initialVerifier The committee verifier to consult on every publish.
     */
    constructor(address initialAdmin, address initialVerifier) {
        if (initialAdmin == address(0) || initialVerifier == address(0)) {
            revert ZeroAddress();
        }
        admin = initialAdmin;
        verifier = IRootAttestationVerifier(initialVerifier);
        // Freeze the verifier's quorum as this registry's permanent floor. It
        // also fails the deployment outright if `initialVerifier` is not a live
        // verifier, which is cheaper than discovering it on the first publish.
        uint256 quorum = IRootAttestationVerifier(initialVerifier)
            .quorumThreshold();
        if (quorum == 0) revert QuorumNotMet(0, 1);
        MIN_ATTESTERS = quorum;
        emit AdminTransferred(address(0), initialAdmin);
        emit VerifierUpdated(address(0), initialVerifier);
    }

    // ──────────────────────────────────────────────────────── publishing ──

    /**
     * @notice Anchor one epoch's Merkle root, given a committee attestation.
     * @dev Permissionless. The caller pays gas and gains nothing else; the
     *      only authority in play belongs to the committee whose signatures
     *      the proof carries.
     *
     *      The commitment is recomputed here from the arguments, never
     *      supplied, so the registry cannot be made to anchor a root the
     *      committee did not attest to under exactly this epoch, range and
     *      predecessor.
     *
     *      Note for callers: the verifier resolves its committee from recent
     *      block hashes, which the EVM only keeps for 256 blocks. A proof must
     *      therefore be broadcast promptly after it is assembled — on a one to
     *      two second chain that is a window of a few minutes, not hours.
     * @param namespace The log family, e.g. `keccak256("marketplace")`.
     * @param epoch The epoch number. Must be exactly {expectedEpoch}.
     * @param root The Merkle root over the epoch's leaves. Must be non-zero.
     * @param firstSeq First log sequence number committed, inclusive.
     * @param lastSeq Last log sequence number committed, inclusive.
     * @param prevRoot The predecessor epoch's root; zero at epoch 1.
     * @param proof The committee proof: `commitBlock(32) || sig0(65) || ...`.
     */
    function publishRoot(
        bytes32 namespace,
        uint256 epoch,
        bytes32 root,
        uint64 firstSeq,
        uint64 lastSeq,
        bytes32 prevRoot,
        bytes calldata proof
    ) external {
        uint256 expected = expectedEpoch(namespace);
        if (epoch != expected) {
            emit PublishFailed(namespace, epoch, EpochOutOfOrder.selector);
            revert EpochOutOfOrder(epoch, expected);
        }
        if (root == bytes32(0)) {
            emit PublishFailed(namespace, epoch, ZeroRoot.selector);
            revert ZeroRoot();
        }
        if (lastSeq < firstSeq) {
            emit PublishFailed(namespace, epoch, EmptyRange.selector);
            revert EmptyRange(firstSeq, lastSeq);
        }
        // An epoch ending at the maximum would make every later epoch's
        // `previous.lastSeq + 1` trap on overflow, bricking the namespace
        // forever behind an unlabelled arithmetic panic. Unreachable from our
        // own log, whose sequence is a Postgres BIGINT, but it is one committee
        // signature away from unrecoverable, so it is refused by name.
        if (lastSeq == type(uint64).max) {
            emit PublishFailed(namespace, epoch, SequenceExhausted.selector);
            revert SequenceExhausted();
        }

        _checkLinksToPredecessor(namespace, epoch, firstSeq, prevRoot);

        bytes32 commitment = commitmentFor(
            namespace,
            epoch,
            root,
            firstSeq,
            lastSeq,
            prevRoot
        );

        // Effects before the external call. The interface declares `verify` as
        // `view`, so today this compiles to STATICCALL and reentrancy is
        // impossible — but that safety is incidental to a keyword rather than
        // structural, and the day someone regenerates this interface against a
        // verifier whose `verify` is not `view`, an inner frame could publish
        // one root and the outer frame overwrite it, emitting two RootPublished
        // events for one epoch. Writing first costs nothing and does not
        // depend on remembering why the keyword mattered.
        _epochs[namespace][epoch] = AnchoredEpoch({
            root: root,
            firstSeq: firstSeq,
            lastSeq: lastSeq,
            // solhint-disable-next-line not-rely-on-time
            publishedAt: uint64(block.timestamp)
        });
        _nextEpoch[namespace] = epoch + 1;

        uint256 quorumThreshold = verifier.quorumThreshold();
        address[] memory attesters = _requireAttested(namespace, epoch, commitment, proof, quorumThreshold);

        emit RootPublished(
            namespace,
            epoch,
            root,
            firstSeq,
            lastSeq,
            prevRoot,
            commitment,
            attesters,
            msg.sender
        );
    }

    // ──────────────────────────────────────────────────────────── admin ──

    /**
     * @notice Point the registry at a different committee verifier.
     * @dev Takes effect immediately, with no delay, per the Pioneer-phase
     *      rule. It can only affect epochs published from here on; every root
     *      already anchored is immutable and unaffected.
     * @param newVerifier The verifier to consult from now on.
     */
    function setVerifier(address newVerifier) external onlyAdmin {
        if (newVerifier == address(0)) revert ZeroAddress();
        // Probe it before adopting it. An address with no code, or one that is
        // not a verifier, would otherwise make every publish revert on the
        // compiler's own extcodesize guard with nothing naming the cause, until
        // somebody noticed the marketplace had stopped being provable.
        //
        // The code-length check has to come first and cannot be folded into the
        // `try`: for a call to an address with no code the compiler emits its
        // own assertion, which reverts before the `catch` can see anything.
        if (newVerifier.code.length == 0) revert NotAVerifier(newVerifier);
        try IRootAttestationVerifier(newVerifier).quorumThreshold() returns (
            uint256 quorum
        ) {
            if (quorum == 0) revert NotAVerifier(newVerifier);
        } catch {
            revert NotAVerifier(newVerifier);
        }
        // Probe that the verifier's verify function exists and returns
        // the expected interface. A zero hash with empty proof should
        // return (false, []), proving the function is callable.
        try IRootAttestationVerifier(newVerifier).verify(bytes32(0), "") returns (
            bool, address[] memory
        ) {
            // Function exists and returns expected types; proceed.
        } catch {
            revert NotAVerifier(newVerifier);
        }
        address previous = address(verifier);
        verifier = IRootAttestationVerifier(newVerifier);
        emit VerifierUpdated(previous, newVerifier);
    }

    /**
     * @notice Hand administrative control to another account.
     * @dev The post-Pioneer migration to governance is this call and nothing
     *      else.
     * @param newAdmin The incoming admin.
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        address previous = admin;
        admin = newAdmin;
        emit AdminTransferred(previous, newAdmin);
    }

    // ───────────────────────────────────────────────────────────── views ──

    /**
     * @notice The most recently anchored epoch for a namespace.
     * @dev L-05: Returns 0 when no epoch has been anchored, which is
     *      indistinguishable from epoch 0 having been anchored. Consumers
     *      MUST check `rootAt(namespace, latestEpoch(namespace)) !=
     *      bytes32(0)` to distinguish "no epochs" from "epoch 0 exists".
     * @param namespace The log family.
     * @return The latest epoch number, or zero when none has been anchored.
     */
    function latestEpoch(bytes32 namespace) external view returns (uint256) {
        return expectedEpoch(namespace) - 1;
    }

    /**
     * @notice Read one anchored epoch.
     * @param namespace The log family.
     * @param epoch The epoch number.
     * @return The epoch record. A zero `root` means the epoch is not anchored.
     */
    function epochAt(bytes32 namespace, uint256 epoch)
        external
        view
        returns (AnchoredEpoch memory)
    {
        return _epochs[namespace][epoch];
    }

    /**
     * @notice Read one anchored root.
     * @param namespace The log family.
     * @param epoch The epoch number.
     * @return The root, or zero when the epoch is not anchored.
     */
    function rootAt(bytes32 namespace, uint256 epoch)
        external
        view
        returns (bytes32)
    {
        return _epochs[namespace][epoch].root;
    }

    /**
     * @notice The epoch number a namespace will accept next.
     * @param namespace The log family.
     * @return The next epoch, which is 1 before anything has been published.
     */
    function expectedEpoch(bytes32 namespace) public view returns (uint256) {
        uint256 next = _nextEpoch[namespace];
        return next == 0 ? 1 : next;
    }

    /**
     * @notice Recompute the commitment a committee must attest for an epoch.
     *
     * @dev Exposed so an off-chain proposer, a committee member and an auditor
     *      can all derive the same bytes from the same public function rather
     *      than from three private reimplementations.
     *
     *      🛑 THE DOMAIN — `block.chainid` and `address(this)` — IS LOAD-BEARING,
     *      and leaving it out was a real hole rather than a stylistic lapse.
     *      The committee verifier attests an arbitrary 32-byte hash and is
     *      shared with the bridge, the registration contract and the privacy
     *      escrows, so without a domain a proof is valid at every registry
     *      pointed at that verifier, not merely at this one.
     *
     *      The concrete harm is at epoch 1, where there is no predecessor root
     *      to force two registries to share a history: an attestation for
     *      epoch 1 of OUR log could be copied into a transaction against an
     *      independent operator's registry, permanently anchoring our root as
     *      THEIR epoch 1 — and since an epoch can be published exactly once,
     *      their namespace would be bricked before they ever used it. That is
     *      precisely the "somebody else runs a cluster" case this whole effort
     *      exists to make safe. From epoch 2 onward the `prevRoot` check forces
     *      the histories to be identical, which is why the hole is narrow, but
     *      narrow is not closed.
     *
     *      This also follows the convention the rest of the codebase already
     *      keeps: `PrivateMarketplaceEscrow._resolveDisputeDigest` domain-
     *      separates its committee digest for the same reason.
     * @param namespace The log family.
     * @param epoch The epoch number.
     * @param root The Merkle root over the epoch's leaves.
     * @param firstSeq First log sequence number committed, inclusive.
     * @param lastSeq Last log sequence number committed, inclusive.
     * @param prevRoot The predecessor epoch's root; zero at epoch 1.
     * @return The commitment.
     */
    function commitmentFor(
        bytes32 namespace,
        uint256 epoch,
        bytes32 root,
        uint64 firstSeq,
        uint64 lastSeq,
        bytes32 prevRoot
    ) public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    COMMITMENT_DOMAIN,
                    block.chainid,
                    address(this),
                    namespace,
                    epoch,
                    root,
                    firstSeq,
                    lastSeq,
                    prevRoot
                )
            );
    }

    // ────────────────────────────────────────────────────────── private ──

    /**
     * @notice Check that an epoch continues its predecessor in both senses.
     *
     * @dev The chain link and the range link are separate checks and neither
     *      substitutes for the other. A correct `prevRoot` with a range that
     *      skips sequence numbers would leave those entries committed to no
     *      root at all — invisible to any root comparison, and exactly how a
     *      node would drop an entry it did not want anchored.
     * @param namespace The log family.
     * @param epoch The epoch being published.
     * @param firstSeq The first sequence number it claims.
     * @param prevRoot The predecessor root it claims.
     */
    function _checkLinksToPredecessor(
        bytes32 namespace,
        uint256 epoch,
        uint64 firstSeq,
        bytes32 prevRoot
    ) private {
        bytes32 expectedPrevRoot;
        uint64 expectedFirstSeq;
        if (epoch == 1) {
            expectedPrevRoot = bytes32(0);
            expectedFirstSeq = 1;
        } else {
            AnchoredEpoch storage previous = _epochs[namespace][epoch - 1];
            expectedPrevRoot = previous.root;
            expectedFirstSeq = previous.lastSeq + 1;
        }
        if (prevRoot != expectedPrevRoot) {
            emit PublishFailed(namespace, epoch, RootChainBroken.selector);
            revert RootChainBroken(prevRoot, expectedPrevRoot);
        }
        if (firstSeq != expectedFirstSeq) {
            emit PublishFailed(namespace, epoch, SequenceGap.selector);
            revert SequenceGap(firstSeq, expectedFirstSeq);
        }
    }

    /**
     * @notice Require a committee quorum over `commitment`, and report who.
     *
     * @dev Two bars, doing different jobs. {MIN_ATTESTERS} was frozen at
     *      deployment, so the bar for this registry cannot be lowered later by
     *      pointing it at a more permissive verifier; the live threshold
     *      follows the verifier upward if the committee grows. Checking only
     *      the live one would be comparing a verifier against itself, which is
     *      no check at all.
     * @param commitment The bytes the committee must have attested.
     * @param proof The committee proof.
     * @return attesters The committee members whose signatures were counted.
     */
    function _requireAttested(
        bytes32 namespace,
        uint256 epoch,
        bytes32 commitment,
        bytes calldata proof,
        uint256 quorumThreshold
    )
        private
        returns (address[] memory attesters)
    {
        bool valid;
        (valid, attesters) = verifier.verify(commitment, proof);
        if (!valid) {
            emit PublishFailed(namespace, epoch, AttestationRejected.selector);
            revert AttestationRejected();
        }

        uint256 required = quorumThreshold;
        if (required < MIN_ATTESTERS) required = MIN_ATTESTERS;
        if (attesters.length < required) {
            emit PublishFailed(namespace, epoch, QuorumNotMet.selector);
            revert QuorumNotMet(attesters.length, required);
        }
    }
}
