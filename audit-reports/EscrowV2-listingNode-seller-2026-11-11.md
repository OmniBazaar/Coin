# EscrowV2 — `listingNode == seller` delta: audit and red-team

**Contract:** `EscrowV2` + linked `EscrowFeeRouter`
**Delta:** commit `d159a6d` (2026-11-11) — one deleted comparison in
`EscrowFeeRouter.validateAttributionNodes` (`listingNode == seller`), plus NatSpec.
**Deployed:** OmniCoin L1 `0x239d66026A45f5780003b96C44903f773FE3356e` (`c6f0ca1`),
and the six remaining chains deployed from the same source on 2026-11-11.
**Verdict:** SAFE TO DEPLOY, no code change required.

## Why the change

`UnifiedFeeVault` / `BuyIntentValidator` stopped rejecting `listingNode == seller` on
2026-05-18 (founder direction: a merchant runs her own listing node). The escrow was the
only surface that still disagreed, so the same sale settled through the vault and reverted
through the escrow. The buyer saw a fee-attribution error they could not act on.

## Pass 1 — security audit

Method: read the delta and the current full source; trace the credit arithmetic at both
split branches; enumerate every remaining collision; check the consent path; check the
blast radius onto already-deployed escrows.

Findings, all Info, none requiring a code change:

1. **Listing slice is address-keyed, not operator-keyed.** A seller naming herself is paid
   the same 17.5%-of-fee slice she could already collect through a second wallet. The
   removed comparison never bound `listingNode` to a real host, so it prevented no wash
   while it broke the primary merchant flow.
2. **Per-chain capability flag must flip with each redeploy.** `escrowChains.ts`
   `allowsSellerAsListingNode` defaults to false; leaving it false after a redeploy makes
   the consent builder zero a legitimate slot and route the merchant's slice to ODDAO
   silently. Actioned: flipped for each chain in the same change that swaps its address.
3. **Deploy-script header says three libraries, lists two.** Comment only; each run
   deploys both libraries fresh and links them into the new escrow (verified by the
   bytecode-embed check and the DELEGATECALL binding probe in
   `Coin/scripts/deploy-escrowv2.cjs`). Corrected here, no code impact.
4. **`splitInKind` doc mentions a private (pXOM) release path that does not exist.**
   Comment only; `PRIVATE_OMNI_COIN` is used solely to refuse the sunset token.

## Pass 2 — adversarial red team

Method: attempt every fee-wash, collision, consent-bypass, rounding, reentrancy,
cross-chain and replay attack available to a seller, buyer or third party.

- Seller captures the listing slice — **works, by design** (`EscrowFeeRouter` credits
  `attribution.listingNode`). It is a re-addressing, not value creation.
- Seller also captures the selling-node slice — **blocked** (`sellingNode == seller`
  still reverts).
- Seller captures a referrer slice — **blocked** (referrer/referrer2 vs seller, and every
  node-versus-referrer collision).
- Credited total exceeds the fee at any amount — **blocked**. Every branch's final credit
  is computed as `component - parts`, so the sum is exactly `feeAmount`; the final
  smallest-unit rounding falls on ODDAO's remainder and never on another recipient.
  Fuzzed across the fee range: zero mismatches, zero value creation.
- Buyer or third party names the seller as listing node without her signature —
  **blocked** (`InvalidSellerSignature`; the digest binds seller, token, all four slots
  and `validUntil`, and the recovered signer must equal the seller).
- Attribution pointing a slice at the escrow itself — **blocked** (burn rule).
- Dust: an escrow too small to yield a fee is refused at creation, so `fee == 0` is
  unreachable and no dust is stranded.
- Reentrancy / changed external-call ordering — **none**; the diff deletes one branch of
  a `pure` function.
- Blast radius onto already-deployed escrows — **none**. Libraries are deployed per chain
  and linked by address into immutable escrow bytecode; there is no proxy and no
  `delegatecall` in the router.
- Signature replay into a verdict, or across escrows/chains — **blocked**. Domain is
  `EIP712("OmniBazaar EscrowV2","3")` (binds chain id and verifying contract) and the
  attribution and verdict typehashes are distinct. A consent is deliberately replayable
  for the same seller + token until `validUntil`, which can only ever pay the payees the
  seller named.

## Tests

`npx hardhat test test/EscrowV2.test.ts test/MinimalEscrowV2.fees.test.ts` → **53 passing, 0 failing**.
The own-node case asserts seller proceeds `USDC(99)` plus a `175_000` listing credit with
the four-way sum equal to exactly `USDC(1)`. The collision case asserts six remaining reverts.

## Remaining risk, stated plainly

A seller can name a second self-controlled address as `sellingNode` and collect 25% of the
fee. That is pre-existing on every escrow generation and is unchanged by this delta:
binding a node slot to a real hosted listing would require a registry read inside the
escrow, which is a separate design change and not part of this deploy.
