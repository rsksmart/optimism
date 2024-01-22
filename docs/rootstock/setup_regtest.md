
<div align="center">
  <a href="https://optimism.io"><img alt="Optimism" src="https://raw.githubusercontent.com/ethereum-optimism/brand-kit/main/assets/svg/OPTIMISM-R.svg" width=600></a>
  <br />
  <h3><a href="https://optimism.io">Optimism</a> is <del>Ethereum</del> <ins>Rootstock</ins>, scaled.</h3>
  <br />
</div>

# Guide to setup local L1 and L2 development nodes

### Requirements

Consult the [optmism official documentation](https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#software-dependencies) for this.

You will need **5 TTYs** for running the both **L1** and **L2** nodes.
For the purpose of this guide we will assume:

```shell
export PATH_RSKSMART="$HOME/src/rsksmart/"
```

This is illustrative, but by all means, set it in each TTY to copy-paste from this guide and/or set it to your desired location.

#### TTY 1

1. clone op-geth to serve as the execution client and build it

    ```shell
    cd $PATH_RSKSMART  # if not there already
    git clone git@github.com:rsksmart/op-geth.git
    cd op-geth
    git swich rsk/poc-v0
    make geth
    ```


2. clone this repo and switch to this branch:

    ```shell
    cd $PATH_RSKSMART  # if not there already
    git clone git@github.com:rsksmart/optimism.git
    cd optimism
    git switch rsk/poc-v0
    ```

3. make a copy of the `.envrc.example` and configure it according to:

    [fill-out-environment-variables](https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#fill-out-environment-variables) optimism documentation

    ```shell
    cd $PATH_RSKSMART/optimism # if not there already
    make rsk-env # this will also create the configuration in the future
    ```

      > [!NOTE]
      > These confis shall be automated in the near future (//TODO:).

      - additionally, to make the use of the rsk make targets configure the following env vars:

    ```shell
    # path to optimism
    export PATH_OPSTACK="$PATH_RSKSMART/optimism"

    # path to bedrock contracts
    export PATH_CONTRACTS="$PATH_OPSTACK/packages/contracts-bedrock"

    # paths to clients
    export PATH_CLIENT_CONSENSUS="$PATH_OPSTACK/op-node"
    export PATH_CLIENT_EXECUTION="$PATH_RSKSMART/op-geth"

    # regtest 33
    export L1_CHAIN_ID=33
    ```

      - also change:
      ```shell
      export DEPLOYMENT_CONTEXT=regtest
      ```

    > [!IMPORTANT]
    > run `direnv allow` to load the environment variables after change.

4. run your favourite **L1 node**:

    - in docker

    ```shell
    cd $PATH_RSKSMART/optimism  # if not there already
    make rsk-regtest-start-log
    ```

    - from jar

      see [rootstock developer's portal](https://dev.rootstock.io/rsk/node/install/operating-systems/java)

#### TTY 2 ([start op geth](https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#start-op-geth))

5. build the internal packages and run execution client with

    ```shell
    cd $PATH_RSKSMART/optimism  # if not there already
    make rsk-build
    make rsk-execution-fresh
    ```

#### TTY 3 ([start op node](https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#start-op-node))

6. run consensus client

    ```shell
    cd $PATH_RSKSMART/optimism  # if not there already
    make rsk-consensus-run
    ```

#### TTY 4 ([start op batcher](https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#start-op-batcher))

7. run batcher client

    ```shell
    cd $PATH_RSKSMART/optimism  # if not there already
    make rsk-batcher-run
    ```

#### TTY 5 ([start op proposer](https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#start-op-proposer))

8. run proposer client

    ```shell
    cd $PATH_RSKSMART/optimism  # if not there already
    make rsk-proposer-run
    ```

---

| :rocket:    | Liftoff, We Have Liftoff|
|---------------|:----------------------------------------|
||[get hacking](https://docs.optimism.io/builders/chain-operators/hacks/overview)|

#### TTY 6 test setup

deposit some RBTC using sdk

```shell
cd $PATH_RSKSMART/optimism/packages/sdk
npx hardhat deposit-eth --to 0x36615Cf349d7F6344891B1e7CA7C72883F5dc049 --amount 100 --network regtest --withdraw false;
```

> [!NOTE]
> the `withdraw false` is necessary at the moment as withdrawal not yet supported on RSK

and to verify the balance

```shell
cast balance 0x36615Cf349d7F6344891B1e7CA7C72883F5dc049 --rpc-url http://localhost:8545
```
