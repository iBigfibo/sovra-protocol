# Sovra Protocol

Sovra is an emerging market sovereign yield vault protocol built on Stacks.

The protocol enables stablecoin holders to access diversified emerging market Treasury Bill yields through structured on-chain vaults with transparent FX exposure.

---

## Problem

The Stacks ecosystem currently lacks diversified real-world sovereign yield primitives. Most yield opportunities are limited to DeFi pools or U.S. Treasury-based RWAs.

There is no structured access to emerging market sovereign yield.

---

## Solution

Sovra introduces country-specific sovereign yield vaults starting with Nigeria Treasury Bills.

Users deposit USDCx into a vault. Capital is allocated off-chain into short-duration Treasury Bills via licensed partners. Yield performance and FX exposure are transparently reflected in vault share value.

---

## MVP Scope (Phase 1)

- Single-country vault (Nigeria)
- Clarity vault contract (testnet)
- FX oracle integration
- Basic dashboard for deposits and yield tracking
- Legal and operational structure outline

---

## Architecture Overview

### On-Chain
- Vault smart contract
- Deposit and redemption logic
- Yield accounting
- FX oracle integration

### Off-Chain
- Licensed asset manager custody
- Treasury Bill allocation
- FX conversion layer
- Proof-of-reserve reporting

---

## Roadmap

See roadmap.md for milestone breakdown.

---

## Status

Design and technical specification phase. Preparing MVP implementation on Stacks.
