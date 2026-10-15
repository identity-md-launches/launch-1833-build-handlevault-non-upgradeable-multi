# Local verification

These are builder-run checks, not independent verification or a security audit.

Toolchain: Foundry 1.8.3; Solidity 0.8.26; the checked-in `foundry.toml` configuration.

| Command | Result |
| --- | --- |
| `forge build --sizes` | Passed; HandleVault runtime 13,772 bytes, MockUSDC runtime 2,164 bytes |
| `FOUNDRY_FUZZ_SEED=0x98cd57a930d7d0682b836422f53fa736e382d0858e0a2d8fa928fce0de643880 forge test` | 70 reported tests passed, zero failed/skipped |
| `forge fmt --check` | Passed |
| `forge script script/DeployHandleVault.s.sol:DeployHandleVault --chain-id 11155111` | Local simulation passed; no broadcast; reported gas 4,098,821 |

The test total groups the two stateful invariant functions into one invariant suite result. Both invariants passed over 128 sequences and 12,288 handler calls, with zero unexpected reverts. Each ordinary fuzz test ran 512 cases with the assignment's seed.

The default suite includes application runtime opcode/size checks and constructor ownership/configuration tests. The network's protected harness still requires the later deployment manifest and factory inputs; public Sepolia addresses and explorer verification belong to that stage. No live addresses are inferred from the script simulation.

Foundry's lint diagnostics are advisory; the reviewed classes and remaining trust assumptions are recorded in `SECURITY_REVIEW.md` and the README. Dependencies are vendored; no test reads environment configuration or uses FFI, runtime filesystem permissions, RPC forks, or a funded wallet.
