## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

source .env

# Deploy Dummy Polygon Token for testing

```bash
forge script script/integration_tests/DeployMockPoly.s.sol:DeployMockPolymarket \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=$POLYGON_CHAIN_ID" \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```
# Mint Polygon token for testing

```bash
forge script script/integration_tests/MintMock.s.sol \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast
```


# Deploy FEE_COLLECTOR AND POOL_FACTORY

```bash
forge script script/Deploy.s.sol \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=$POLYGON_CHAIN_ID" \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

# Deploy CreatePool

```bash
forge script script/CreatePool.s.sol \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast \
  --verify \
  --verifier etherscan \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=$POLYGON_CHAIN_ID" \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

# Deposit to pool

```bash
forge script script/integration_tests/Deposit.s.sol\
  --rpc-url $POLYGON_RPC_URL \
  --broadcast 
```

# Swap in pool

```bash
forge script script/integration_tests/Swap.s.sol\
  --rpc-url $POLYGON_RPC_URL \
  --broadcast 
```

# Withdraw from pool
```bash
forge script script/integration_tests/Withdraw.s.sol\
  --rpc-url $POLYGON_RPC_URL \
  --broadcast 
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
