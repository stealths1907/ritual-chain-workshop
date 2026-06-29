# Privacy-Preserving AI Bounty Judge (Commit-Reveal)

A Solidity smart contract implementing a **two-phase commit-reveal** flow for Ritual Chain's AI Bounty system. This prevents participants from copying others' submissions before the judging phase.

## Problem

In the original `AIJudge.sol`, submissions were stored as plaintext on-chain. This allowed:
- Participants to read others' answers and submit improved versions
- Front-running attacks where someone copies a good answer
- Unfair advantage for late submitters

## Solution: Commit-Reveal Flow

### Lifecycle

```
Phase 1: COMMIT (before deadline)
  └─ Participants submit hash: keccak256(answer, salt, sender, bountyId)
  └─ No one can see the actual answers

Phase 2: REVEAL (deadline → revealDeadline)
  └─ Participants reveal their answer + salt
  └─ Contract verifies hash matches commitment
  └─ Invalid reveals are rejected

Phase 3: JUDGE (after revealDeadline)
  └─ Owner triggers AI judging via Ritual LLM precompile
  └─ All revealed answers are evaluated at once

Phase 4: FINALIZE
  └─ Owner picks the winner based on AI review
  └─ Reward is automatically transferred
```

### Key Functions

| Function | Phase | Description |
|---|---|---|
| `createBounty()` | Setup | Creates bounty with commit + reveal deadlines |
| `submitCommitment()` | Commit | Submit keccak256 hash of your answer |
| `revealAnswer()` | Reveal | Reveal answer + salt, contract verifies hash |
| `judgeAll()` | Judge | Trigger Ritual LLM to evaluate all answers |
| `finalizeWinner()` | Finalize | Pay out the winner |
| `computeCommitment()` | Helper | Compute hash off-chain for verification |

### Hash Formula

```solidity
keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
```

The `msg.sender` and `bountyId` are included to prevent:
- Cross-bounty replay attacks
- One user submitting another user's commitment

## Test Plan

### Happy Path
- Create bounty → Commit → Reveal → Judge → Finalize → Winner gets paid

### Edge Cases
| Test | Expected |
|---|---|
| Commit after deadline | ❌ Reverts: "commit phase ended" |
| Reveal before deadline | ❌ Reverts: "commit phase still active" |
| Reveal after revealDeadline | ❌ Reverts: "reveal phase ended" |
| Reveal with wrong salt | ❌ Reverts: "commitment mismatch" |
| Reveal with wrong answer | ❌ Reverts: "commitment mismatch" |
| Reveal without committing | ❌ Reverts: "no commitment found" |
| Double commit | ❌ Reverts: "already committed" |
| Double reveal | ❌ Reverts: "already revealed" |
| Judge before reveal ends | ❌ Reverts: "reveal phase not ended" |
| Read answers before reveal ends | ❌ Reverts: "answers hidden until reveal phase ends" |

## Deploy & Verify

```bash
cd hardhat
pnpm install
npx hardhat compile
npx hardhat ignition deploy ./ignition/modules/AIJudge.ts --network ritual
```

## Architecture

See [architecture.md](./architecture.md) for the Advanced Track design using Ritual's TEE.

## Author

Built for Ritual Academy — Privacy-Preserving AI Bounty Judge Assignment
