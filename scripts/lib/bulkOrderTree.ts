/**
 * Bulk order signing for `NFTExchange` — one signature covering many
 * orders.
 *
 * The construction is Seaport's, copied deliberately. The signed type is
 * `BulkOrder(Order[2][2]…[2] tree)`. EIP-712 hashes a fixed-size array as
 * `keccak256(concat(encodeData(element)))`, so nesting `[2]` to depth `h`
 * IS an unsorted binary Merkle tree over plain `keccak256(left ‖ right)` —
 * no sorting, no leaf prefix, no pre-hashing. The wallet still renders
 * readable typed data, so the seller is not blind-signing. The leaf is the
 * byte-identical single-order struct hash, so bulk signing is purely
 * additive: single-order verification on chain is untouched.
 *
 * Reference: `ProjectOpenSea/seaport` `docs/SeaportDocumentation.md`, and
 * `seaport-core/src/lib/Verifiers.sol`.
 *
 * 🛑 THE TREE IS PADDED TO A POWER OF TWO. It is never built by
 * duplicating a trailing odd node. `merkletreejs` under `duplicateOdd`
 * omits a trailing odd node's self-sibling from `getProof`, producing
 * proofs that fail its own `verify` — measured, and recorded in memory
 * `trustless_data_t2_2026-07-26`. That is why this file exists instead of
 * a dependency, and it is why every tree here is padded rather than
 * duplicated.
 *
 * Padding orders are all-zero, which makes them unfulfillable: a zero
 * `nftContract` is rejected by `NFTExchange`, and a zero `offerer` cannot
 * have signed anything.
 */

import { AbiCoder, TypedDataEncoder, concat, id, keccak256, toBeHex } from "ethers";

/** EIP-712 domain the exchange signs under. */
export interface ExchangeDomain {
  /** Always `"OmniBazaar NFTExchange"`. */
  name: string;
  /** Always `"1"`. */
  version: string;
  /** Chain the exchange is deployed on. */
  chainId: number | bigint;
  /** Address of the `NFTExchange` contract. */
  verifyingContract: string;
}

/**
 * One order, exactly as `NFTExchange.Order` declares it.
 *
 * Field order matters: it is the order of the EIP-712 type string, and
 * changing it changes every hash.
 */
export interface Order {
  /** Member of `NFTExchange.OrderKind`. 0 is a fixed price. */
  kind: number;
  /** Member of `NFTExchange.ItemType`. 0 is ERC-721, 1 is ERC-1155. */
  itemType: number;
  /** Seller. The signature must recover to this address. */
  offerer: string;
  /** Zero for an open listing, or the only address allowed to buy. */
  taker: string;
  /** Collection holding the item. */
  nftContract: string;
  /** Item within the collection. */
  tokenId: bigint | string;
  /** Units offered. Exactly 1 for ERC-721. */
  amount: bigint | string;
  /** Currency the buyer pays in. Zero means the chain's own currency. */
  paymentToken: string;
  /** Total price for all units at `startTime`. */
  startPrice: bigint | string;
  /** Total price at `endTime`. Equal to `startPrice` for a fixed price. */
  endPrice: bigint | string;
  /** Unix seconds before which the order cannot be filled. */
  startTime: number | bigint | string;
  /** Unix seconds after which the order cannot be filled. Inclusive. */
  endTime: number | bigint | string;
  /** The seller's on-chain counter value at the moment of signing. */
  counter: bigint | string;
  /** Free field making otherwise identical orders distinguishable. */
  salt: bigint | string;
  /** Fee in basis points the seller agreed to. */
  marketplaceFeeBps: bigint | string;
  /** Most of the sale the seller will let the creator take, in basis
   * points. The royalty is read from the collection at fill time and a
   * collection owner can raise it after signing, so this is the seller's
   * protection against that. 10,000 accepts whatever the collection says. */
  maxRoyaltyBps: bigint | string;
  /** Who introduced the trade, or the zero address. */
  referrer: string;
  /** Second-level referrer, or the zero address. */
  referrer2: string;
}

/** The `Order` member list, in the order the contract hashes them. */
export const ORDER_TYPE_FIELDS = [
  { name: "kind", type: "uint8" },
  { name: "itemType", type: "uint8" },
  { name: "offerer", type: "address" },
  { name: "taker", type: "address" },
  { name: "nftContract", type: "address" },
  { name: "tokenId", type: "uint256" },
  { name: "amount", type: "uint256" },
  { name: "paymentToken", type: "address" },
  { name: "startPrice", type: "uint256" },
  { name: "endPrice", type: "uint256" },
  { name: "startTime", type: "uint64" },
  { name: "endTime", type: "uint64" },
  { name: "counter", type: "uint256" },
  { name: "salt", type: "uint256" },
  { name: "marketplaceFeeBps", type: "uint256" },
  { name: "maxRoyaltyBps", type: "uint256" },
  { name: "referrer", type: "address" },
  { name: "referrer2", type: "address" },
] as const;

/** Typed-data types for signing a single order. */
export const SINGLE_ORDER_TYPES = {
  Order: ORDER_TYPE_FIELDS as unknown as Array<{ name: string; type: string }>,
};

/** Deepest tree the contract accepts — 16,777,216 orders. */
export const MAX_BULK_HEIGHT = 24;

/**
 * Deepest tree this generator will build without being told to.
 *
 * The contract goes to 24 for Seaport parity, but nobody is going to read
 * 16.7 million orders in a wallet prompt, so a tree that deep is blind
 * signing whatever the encoding says. Depth 12 is 4,096 orders — more than
 * any real inventory we have seen, including the founder's 822 — so the cap
 * costs nothing in practice and makes going past it a deliberate act rather
 * than an accident of a loop.
 */
export const REVIEWABLE_BULK_HEIGHT = 12;

/** An order every field of which is zero. Unfulfillable by construction. */
export const EMPTY_ORDER: Order = {
  kind: 0,
  itemType: 0,
  offerer: "0x0000000000000000000000000000000000000000",
  taker: "0x0000000000000000000000000000000000000000",
  nftContract: "0x0000000000000000000000000000000000000000",
  tokenId: 0n,
  amount: 0n,
  paymentToken: "0x0000000000000000000000000000000000000000",
  startPrice: 0n,
  endPrice: 0n,
  startTime: 0,
  endTime: 0,
  counter: 0n,
  salt: 0n,
  marketplaceFeeBps: 0n,
  maxRoyaltyBps: 0n,
  referrer: "0x0000000000000000000000000000000000000000",
  referrer2: "0x0000000000000000000000000000000000000000",
};

/** A padded tree of orders, ready to be signed once. */
export interface BulkOrderTree {
  /** Tree depth. `2 ** height` leaves. */
  height: number;
  /** The orders as given, before padding. */
  orders: Order[];
  /** The orders padded out to `2 ** height` with {@link EMPTY_ORDER}. */
  paddedOrders: Order[];
  /** Struct hash of every padded order, in leaf order. */
  leaves: string[];
  /** Merkle root — what the seller's one signature actually covers. */
  root: string;
  /** Typed-data types to hand to a wallet for the bulk signature. */
  types: Record<string, Array<{ name: string; type: string }>>;
  /** The nested value to sign, shaped to match `types`. */
  value: { tree: unknown };
}

/**
 * Smallest tree depth that holds `count` orders.
 *
 * @param count How many orders need to fit.
 * @param allowUnreviewableDepth Permit a depth past
 *        {@link REVIEWABLE_BULK_HEIGHT}.
 * @returns Depth in the range 1 to {@link MAX_BULK_HEIGHT}.
 * @throws If `count` is zero, deeper than the contract accepts, or deeper
 *         than a person could review without being told that is intended.
 */
export function bulkOrderHeight(
  count: number,
  allowUnreviewableDepth = false,
): number {
  if (!Number.isInteger(count) || count < 1) {
    throw new Error(`bulk order count must be a positive integer, got ${count}`);
  }
  let height = 1;
  while (2 ** height < count) {
    height += 1;
  }
  if (height > MAX_BULK_HEIGHT) {
    throw new Error(
      `${count} orders needs a tree of depth ${height}; the contract accepts at most ${MAX_BULK_HEIGHT}`,
    );
  }
  if (height > REVIEWABLE_BULK_HEIGHT && !allowUnreviewableDepth) {
    throw new Error(
      `${count} orders needs a tree of depth ${height}, past the ${REVIEWABLE_BULK_HEIGHT} a person could plausibly review before signing. Split the batch, or pass allowUnreviewableDepth to say you mean it.`,
    );
  }
  return height;
}

/**
 * The nested EIP-712 type string for a tree of a given depth, e.g.
 * `Order[2][2]` at depth 2.
 *
 * @param height Tree depth.
 * @returns The member type of `BulkOrder.tree`.
 */
export function bulkOrderTreeType(height: number): string {
  return `Order${"[2]".repeat(height)}`;
}

/**
 * Typed-data types for a bulk signature over a tree of a given depth.
 *
 * @param height Tree depth.
 * @returns Types to hand to `signTypedData`.
 */
export function bulkOrderTypes(
  height: number,
): Record<string, Array<{ name: string; type: string }>> {
  return {
    BulkOrder: [{ name: "tree", type: bulkOrderTreeType(height) }],
    Order: ORDER_TYPE_FIELDS as unknown as Array<{
      name: string;
      type: string;
    }>,
  };
}

/**
 * The EIP-712 type hash the contract derives for a tree of a given depth.
 *
 * Kept here so a test can prove our string and the contract's agree; the
 * contract builds the same string at call time from its own
 * `ORDER_TYPE_STRING`.
 *
 * @param height Tree depth.
 * @returns `keccak256` of the full encoded type.
 */
export function bulkOrderTypehash(height: number): string {
  return id(TypedDataEncoder.from(bulkOrderTypes(height)).encodeType("BulkOrder"));
}

/**
 * Struct hash of one order — its identity on chain, and its leaf in a
 * bulk tree.
 *
 * @param order The order.
 * @returns The struct hash.
 */
export function hashOrder(order: Order): string {
  return TypedDataEncoder.hashStruct("Order", SINGLE_ORDER_TYPES, order);
}

/**
 * Build a padded bulk tree over a list of orders.
 *
 * @param orders Orders to cover with one signature. At least one.
 * @param allowUnreviewableDepth Build a tree deeper than
 *        {@link REVIEWABLE_BULK_HEIGHT}, which no user can meaningfully
 *        review before signing.
 * @returns The tree, its root, and the typed data to sign.
 */
export function buildBulkOrderTree(
  orders: Order[],
  allowUnreviewableDepth = false,
): BulkOrderTree {
  const height = bulkOrderHeight(orders.length, allowUnreviewableDepth);
  const width = 2 ** height;

  const paddedOrders = orders.slice();
  while (paddedOrders.length < width) {
    paddedOrders.push(EMPTY_ORDER);
  }

  const leaves = paddedOrders.map(hashOrder);
  const root = merkleRoot(leaves);

  return {
    height,
    orders,
    paddedOrders,
    leaves,
    root,
    types: bulkOrderTypes(height),
    value: { tree: nest(paddedOrders, height) },
  };
}

/**
 * Merkle root of an already-padded list of leaves.
 *
 * Plain `keccak256(left ‖ right)`, pairs taken in order, no sorting. This
 * is not a convention chosen here — it is what EIP-712's encoding of a
 * fixed-size array computes, which is the whole reason the wallet can
 * still render what it is signing.
 *
 * @param leaves Leaf hashes. Length must be a power of two.
 * @returns The root.
 */
export function merkleRoot(leaves: string[]): string {
  assertPowerOfTwo(leaves.length);
  let level = leaves;
  while (level.length > 1) {
    const next: string[] = [];
    for (let i = 0; i < level.length; i += 2) {
      next.push(keccak256(concat([level[i], level[i + 1]])));
    }
    level = next;
  }
  return level[0];
}

/**
 * Sibling hashes proving one leaf belongs to the root, lowest level first.
 *
 * @param leaves Leaf hashes. Length must be a power of two.
 * @param index  Which leaf to prove.
 * @returns One sibling per level, `log2(leaves.length)` of them.
 */
export function merkleProof(leaves: string[], index: number): string[] {
  assertPowerOfTwo(leaves.length);
  if (!Number.isInteger(index) || index < 0 || index >= leaves.length) {
    throw new Error(`leaf index ${index} is outside a tree of ${leaves.length}`);
  }

  const proof: string[] = [];
  let level = leaves;
  let at = index;
  while (level.length > 1) {
    // The sibling is always present, because the tree is padded to a power
    // of two. This is exactly the case `merkletreejs` gets wrong when it
    // duplicates a trailing odd node instead of padding.
    proof.push(level[at ^ 1]);
    const next: string[] = [];
    for (let i = 0; i < level.length; i += 2) {
      next.push(keccak256(concat([level[i], level[i + 1]])));
    }
    level = next;
    at >>= 1;
  }
  return proof;
}

/**
 * Rebuild a root from a leaf and its proof — the same walk the contract
 * does, for checking our own work.
 *
 * @param leaf  Leaf hash.
 * @param index Leaf position.
 * @param proof Siblings, lowest level first.
 * @returns The root the proof implies.
 */
export function rootFromProof(
  leaf: string,
  index: number,
  proof: string[],
): string {
  let node = leaf;
  let key = index;
  for (const sibling of proof) {
    node =
      (key & 1) === 0
        ? keccak256(concat([node, sibling]))
        : keccak256(concat([sibling, node]));
    key >>= 1;
  }
  return node;
}

/**
 * Pack one order's proof into the signature argument `fulfillOrder` takes:
 * `65-byte signature ‖ 3-byte index ‖ one 32-byte sibling per level`.
 *
 * The contract tells a bulk signature from a plain one purely by length,
 * so nothing about `fulfillOrder`'s arguments changes between the two.
 *
 * @param signature The seller's 65-byte signature over the whole tree.
 * @param index     Which leaf this order is.
 * @param proof     Siblings from {@link merkleProof}.
 * @returns The bytes to pass as `fulfillOrder`'s `signature` argument.
 */
export function encodeBulkSignature(
  signature: string,
  index: number,
  proof: string[],
): string {
  if (signature.length !== 132) {
    throw new Error(
      `expected a 65-byte signature, got ${(signature.length - 2) / 2} bytes`,
    );
  }
  if (proof.length < 1 || proof.length > MAX_BULK_HEIGHT) {
    throw new Error(
      `proof depth must be 1 to ${MAX_BULK_HEIGHT}, got ${proof.length}`,
    );
  }
  if (index < 0 || index >= 2 ** proof.length) {
    throw new Error(
      `leaf index ${index} is outside a tree of depth ${proof.length}`,
    );
  }
  return concat([signature, toBeHex(index, 3), ...proof]) as string;
}

/**
 * Check, before a user is asked to sign, that the tree we built and the
 * typed data we are about to show them describe the same root.
 *
 * Seaport's reference implementation makes the same assertion at signing
 * time, and for the same reason: a construction mistake must fail loudly
 * here rather than produce a signature that silently covers nothing.
 *
 * @param tree The tree from {@link buildBulkOrderTree}.
 * @throws If the two disagree.
 */
export function assertTreeMatchesTypedData(tree: BulkOrderTree): void {
  const fromTypedData = TypedDataEncoder.hashStruct(
    "BulkOrder",
    tree.types,
    tree.value,
  );
  const fromRoot = keccak256(
    AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "bytes32"],
      [bulkOrderTypehash(tree.height), tree.root],
    ),
  );
  if (fromTypedData !== fromRoot) {
    throw new Error(
      `bulk order tree does not match its typed data: ${fromTypedData} from typed data, ${fromRoot} from the root`,
    );
  }
}

/**
 * Reject a leaf count that is not a power of two.
 *
 * @param count Number of leaves.
 * @throws If `count` is not a power of two.
 */
function assertPowerOfTwo(count: number): void {
  if (count < 2 || (count & (count - 1)) !== 0) {
    throw new Error(
      `a bulk tree must have a power-of-two number of leaves; got ${count}. Pad it — never duplicate a trailing odd node.`,
    );
  }
}

/**
 * Shape a flat list of orders into the nested arrays the typed-data value
 * needs, e.g. depth 2 gives `[[a, b], [c, d]]`.
 *
 * @param orders Padded orders, `2 ** height` of them.
 * @param height Tree depth.
 * @returns The nested value.
 */
function nest(orders: Order[], height: number): unknown {
  let level: unknown[] = orders.slice();
  for (let i = 0; i < height; i += 1) {
    const next: unknown[] = [];
    for (let j = 0; j < level.length; j += 2) {
      next.push([level[j], level[j + 1]]);
    }
    level = next;
  }
  return level[0];
}
