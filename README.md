# Silent Cat (SCAT)

A plain, fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum.

| Parameter | Value |
| --- | --- |
| Solidity contract | `SilentCat` (`src/SilentCat.sol`) |
| `name()` | `Silent Cat` |
| `symbol()` | `SCAT` |
| `decimals()` | `18` |
| Total supply | 1,000,000,000 SCAT = `1000000000000000000000000000` minor units |
| Minting | Once, in the constructor, the whole supply to `msg.sender` |
| Constructor arguments | None |
| Owner / admin | None |

## Behaviour

- **Fixed supply.** `TOTAL_SUPPLY` is a compile-time constant. The constructor is the only place
  `_mint` is called. There is no `mint`, no minter role, no owner and no upgrade path, so the supply
  can never grow after deployment.
- **Minted to the deployer.** The constructor mints to `msg.sender`. At the IdentityMD launch the
  deployer is the ProjectFactory, which then pays the supply out (swarm share, pool seed, remainder).
  It is never minted to `tx.origin` or to a hard-coded address.
- **Standard transfers.** Transfers, approvals and `transferFrom` are OpenZeppelin v5.1 `ERC20`
  behaviour with no tax, fee, burn-on-transfer, cooldown, maximum wallet, or exemption list. Every
  flow delivers exactly the amount sent, so the launch's distributor transfers, pool seed and swaps
  through the Uniswap v4 PoolManager move exactly what they say.
- **Self-burn only.** `burn(uint256)` destroys the caller's own tokens and reduces `totalSupply`.
  There is no `burnFrom`, so nobody can reduce another holder's balance.
- **No privileged powers.** No pause, blacklist, freeze, lock, seize or transfer switch. No
  `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in the runtime. The contract has no `receive` or
  `fallback`, so it refuses ether.

## Assumptions

- The requester asked for a plain token: name, symbol and supply only. No taxes, reflections,
  vesting or governance were requested, so none are implemented. Anything else would change the
  launch flows the floor checks.
- The supply is minted to `msg.sender` because the launch factory deploys the token and must hold
  the whole supply to distribute it. Anyone else deploying this bytecode receives the supply instead.
- The number of decimals (18) and the supply (one billion) are the requester's; nothing else in the
  brief was left open, so there are no additional chosen constants.

## Deployment parameters

The IdentityMD launch deploys the token from the built bytecode. The relevant manifest values, which
the separate manifest step writes after this work is accepted, are:

| Manifest field | Value |
| --- | --- |
| `token.contract` | `SilentCat` |
| `token.name` | `Silent Cat` |
| `token.symbol` | `SCAT` |
| `token.decimals` | `18` |
| `token.constructorArgs` | `[]` |
| `token.totalSupply` | `1000000000000000000000000000` |
| Application contracts | none |

Launch-decided values (not open questions): chain id 1, pair IMD
(`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), pool fee 12500, tick spacing 60, initial price
`79228162514264337593543950336`, economics `{"poolBps":8000,"initialMarketCapWei":"3500000000000000000000","remainderTo":"0x0f44a55663e888bb63618a0c31b68cbc6c01aa71"}`.
The factory sends 10% of the supply to the launch's MerkleDistributor, seeds the pool with 80%, and
forwards the remaining 10% to `remainderTo`.

Build settings in `foundry.toml`: `solc = "0.8.26"`, `bytecode_hash = "none"`, `cbor_metadata = false`,
optimizer on with 200 runs, EVM version `cancun`. The fuzz seed is pinned to the verifier's seed.

`script/DeploySilentCat.s.sol` is a reference deployment for local or self-hosted use. It is not
used by the launch. Its `deploy()` function takes no configuration because the token has no
constructor arguments; `run()` only wraps it in a broadcast.

## After launch

There is nothing to configure. The token has no owner-settable values, no outside dependencies and
no setters.

## Operational responsibilities

- **Holders** control their own balances. Allowances given to third parties are standard ERC-20
  allowances; an infinite allowance is never decremented, so grant only what is needed.
- **Nobody** can recover tokens sent to the wrong address, to the token contract itself, or burned.
  There is no admin to intervene.
- **The launch deployer (IdentityMD)** deploys the bytecode, verifies source on the explorer and
  distributes the supply under the manifest. This repository does not deploy, broadcast or hold keys.
- **The requester** receives the remainder at `remainderTo` and is responsible for that wallet.

## Security notes

The eth-security checklist was applied: no decimals arithmetic, no price oracles, no external calls
(so no reentrancy surface), no proxies, no delegatecall, no access-controlled functions, input
validation by OpenZeppelin's ERC20 (zero-address checks, balance and allowance checks with custom
errors). Tooling run: `forge build`, `forge test` (including fuzz tests with the verifier's seed) and
`forge fmt --check`. Slither and Mythril were not run; they are not available in this environment.
Passing tests are not an audit. Review by an independent contributor is recommended before release.

## Repository layout

```
foundry.toml                 Foundry configuration (pinned solc 0.8.26, bytecode_hash none)
remappings.txt               forge-std and @openzeppelin/contracts remappings
src/SilentCat.sol            The token
script/DeploySilentCat.s.sol Reference deploy script
test/SilentCat.t.sol         Unit and fuzz tests for the token
test/DeploySilentCat.t.sol   Test for the deploy script's deploy() function
lib/forge-std                Vendored forge-std v1.9.7 (src only), MIT/Apache-2.0
lib/openzeppelin-contracts   Vendored OpenZeppelin Contracts v5.1.0 (ERC20 subset), MIT
```

Dependencies are vendored as ordinary files, not git submodules, so the project builds offline.

## Commands

```
forge build
forge test
forge fmt --check
```
