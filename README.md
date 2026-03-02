# Sovra Protocol
Status: Pre-MVP | Getting Started Grant Application Phase

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
# Technical Specification

## Overview

Sovra is a sovereign yield vault protocol built on Stacks.

The initial MVP focuses on a Nigeria Treasury Bill vault that allows users to deposit USDCx and gain exposure to short-duration sovereign debt yield with transparent FX adjustment.

---

## Vault Structure

Users deposit USDCx into the Sovra Vault.

Vault shares represent proportional ownership of underlying Treasury Bill allocation.

Vault NAV reflects:

- Principal
- Accrued T-Bill yield
- NGN/USD FX adjustment
- Protocol fee (if applicable)

---

## Deposit Flow

1. User deposits USDCx.
2. Vault mints shares based on current NAV.
3. Capital is allocated off-chain into Nigerian T-Bills via licensed partners.
4. Yield accrues over time.

---

## Redemption Flow

1. User submits withdrawal request.
2. Shares are burned.
3. USDCx is returned based on updated NAV and FX rate.

Redemptions may align with T-Bill maturity cycles.

---

## FX Oracle

The vault requires a reliable NGN/USD price feed.

Requirements:

- Periodic updates
- On-chain integration with Clarity contract
- Transparent reporting on dashboard

---

## Risk Model

Primary risks include:

- FX depreciation
- Sovereign credit risk
- Liquidity constraints
- Capital controls

Risk transparency is prioritized in reporting and documentation.
## Status

Design and technical specification phase. Preparing MVP implementation on Stacks.
---

## 12 Week Roadmap

Weeks 1–2  
Finalize vault mechanics and complete technical design documentation.

Weeks 3–5  
Develop Clarity vault contract on testnet.

Weeks 6–7  
Integrate FX oracle and implement NAV calculation logic.

Weeks 8–9  
Build minimal dashboard for deposits and yield tracking.

Weeks 10–11  
Internal testing and refinement.

Week 12  
Public testnet release and documentation.

---

## Grant Milestones

Milestone 1  
Vault contract deployed on Stacks testnet with deposit logic implemented.

Milestone 2  
FX oracle integrated and NAV calculation live.

Milestone 3  
Basic dashboard deployed for public testing.

Milestone 4  
Public documentation and transparency report published.
