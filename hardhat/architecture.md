# Architecture Note: Ritual-Native Hidden Submissions (Advanced Track)

## Overview

While the **Required Track** uses a standard commit-reveal pattern, the **Advanced Track** leverages Ritual's unique TEE (Trusted Execution Environment) infrastructure to keep answers encrypted on-chain and only decrypted inside the secure enclave during AI judging.

## Architecture Comparison

```
REQUIRED TRACK (Commit-Reveal)          ADVANCED TRACK (TEE-Encrypted)
================================        ================================
Commit Phase:                           Submit Phase:
  hash stored on-chain                    ECIES-encrypted answer on-chain
  plaintext NEVER on-chain                plaintext NEVER on-chain

Reveal Phase:                           No Reveal Needed:
  plaintext goes on-chain                 TEE decrypts inside enclave
  everyone can see after reveal           only AI sees plaintext

Judge Phase:                            Judge Phase:
  AI reads plaintext from chain           AI reads decrypted text in TEE
  public after reveal                     stays private even after judging
```

## Where Does Plaintext Exist?

| Location | Commit-Reveal | TEE-Encrypted |
|---|---|---|
| User's browser | ✅ Yes (when composing) | ✅ Yes (when composing) |
| On-chain (during submit) | ❌ Only hash | ❌ Only ciphertext |
| On-chain (after reveal) | ✅ Yes (public) | ❌ Never |
| Inside TEE enclave | N/A | ✅ Yes (during judging only) |
| AI model input | ✅ Yes | ✅ Yes (inside TEE) |

## On-Chain vs Off-Chain Storage

### On-Chain
- Bounty metadata (title, rubric, deadlines, reward)
- Encrypted submissions (ECIES ciphertext)
- AI judgment result (winner index, scores)
- Commitment hashes (Required Track)

### Off-Chain (TEE Only)
- Decrypted plaintext answers (exist only during execution)
- LLM inference context (destroyed after execution)
- Decryption keys (held by TEE, never exposed)

## How the LLM Receives Submissions for Batch Judging

### Required Track
The `judgeAll()` function passes all revealed plaintext answers to the LLM precompile in a single call. The bounty owner constructs the `llmInput` parameter containing all answers and the rubric.

### Advanced Track (TEE-Native)
1. Submissions are encrypted with the TEE executor's public key using ECIES
2. The `judgeAll()` function sends all encrypted submissions to the LLM precompile
3. Inside the TEE enclave:
   a. Each submission is decrypted using the executor's private key
   b. All plaintext answers are assembled into a single prompt with the rubric
   c. The LLM evaluates all answers in one batch call
   d. The result (scores/ranking) is returned on-chain
4. Plaintext answers are destroyed when the TEE execution completes

### Key Advantage
The TEE approach means **answers never become public**, even after judging. This is important for scenarios like:
- Trade secret submissions
- Security vulnerability reports (bug bounties)
- Competitive proposals where losing answers should remain confidential

## Ritual-Specific Components Used

| Component | Purpose |
|---|---|
| `LLM_INFERENCE_PRECOMPILE (0x0802)` | AI judging inside TEE |
| `DKMS_PRECOMPILE (0x081B)` | Decentralized key management for encryption |
| `ECIES Encryption` | Encrypt submissions with executor's public key |
| `RitualWallet` | Escrow for bounty rewards |

## Trade-offs

| Aspect | Commit-Reveal | TEE-Encrypted |
|---|---|---|
| Complexity | Low | High |
| Privacy after judging | ❌ Answers public | ✅ Answers stay private |
| EVM compatibility | ✅ Any EVM chain | ❌ Ritual Chain only |
| Trust model | Trustless (math) | Hardware trust (TEE) |
| Gas cost | Lower | Higher (encryption overhead) |
