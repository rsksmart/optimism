COMPOSEFLAGS=-d
ITESTS_L2_HOST=http://localhost:9545
BEDROCK_TAGS_REMOTE?=origin
OP_STACK_GO_BUILDER?=us-docker.pkg.dev/oplabs-tools-artifacts/images/op-stack-go:latest

# Requires at least Python v3.9; specify a minor version below if needed
PYTHON?=python3

build: build-go build-ts
.PHONY: build

build-go: submodules op-node op-proposer op-batcher
.PHONY: build-go

lint-go:
	golangci-lint run -E goimports,sqlclosecheck,bodyclose,asciicheck,misspell,errorlint --timeout 5m -e "errors.As" -e "errors.Is" ./...
.PHONY: lint-go

build-ts: submodules
	if [ -n "$$NVM_DIR" ]; then \
		. $$NVM_DIR/nvm.sh && nvm use; \
	fi
	pnpm install
	pnpm build
.PHONY: build-ts

ci-builder:
	docker build -t ci-builder -f ops/docker/ci-builder/Dockerfile .

golang-docker:
	# We don't use a buildx builder here, and just load directly into regular docker, for convenience.
	GIT_COMMIT=$$(git rev-parse HEAD) \
	GIT_DATE=$$(git show -s --format='%ct') \
	IMAGE_TAGS=$$(git rev-parse HEAD),latest \
	docker buildx bake \
			--progress plain \
			--load \
			-f docker-bake.hcl \
			op-node op-batcher op-proposer op-challenger
.PHONY: golang-docker

contracts-bedrock-docker:
	IMAGE_TAGS=$$(git rev-parse HEAD),latest \
	docker buildx bake \
			--progress plain \
			--load \
			-f docker-bake.hcl \
		  contracts-bedrock
.PHONY: contracts-bedrock-docker

submodules:
	git submodule update --init --recursive
.PHONY: submodules

op-bindings:
	make -C ./op-bindings
.PHONY: op-bindings

op-node:
	make -C ./op-node op-node
.PHONY: op-node

generate-mocks-op-node:
	make -C ./op-node generate-mocks
.PHONY: generate-mocks-op-node

generate-mocks-op-service:
	make -C ./op-service generate-mocks
.PHONY: generate-mocks-op-service

op-batcher:
	make -C ./op-batcher op-batcher
.PHONY: op-batcher

op-proposer:
	make -C ./op-proposer op-proposer
.PHONY: op-proposer

op-challenger:
	make -C ./op-challenger op-challenger
.PHONY: op-challenger

op-program:
	make -C ./op-program op-program
.PHONY: op-program

cannon:
	make -C ./cannon cannon
.PHONY: cannon

cannon-prestate: op-program cannon
	./cannon/bin/cannon load-elf --path op-program/bin/op-program-client.elf --out op-program/bin/prestate.json --meta op-program/bin/meta.json
	./cannon/bin/cannon run --proof-at '=0' --stop-at '=1' --input op-program/bin/prestate.json --meta op-program/bin/meta.json --proof-fmt 'op-program/bin/%d.json' --output ""
	mv op-program/bin/0.json op-program/bin/prestate-proof.json

mod-tidy:
	# Below GOPRIVATE line allows mod-tidy to be run immediately after
	# releasing new versions. This bypasses the Go modules proxy, which
	# can take a while to index new versions.
	#
	# See https://proxy.golang.org/ for more info.
	export GOPRIVATE="github.com/ethereum-optimism" && go mod tidy
.PHONY: mod-tidy

clean:
	rm -rf ./bin
.PHONY: clean

nuke: clean devnet-clean
	git clean -Xdf
.PHONY: nuke

pre-devnet: submodules
	@if ! [ -x "$(command -v geth)" ]; then \
		make install-geth; \
	fi
	@if [ ! -e op-program/bin ]; then \
		make cannon-prestate; \
	fi
.PHONY: pre-devnet

devnet-up: pre-devnet
	./ops/scripts/newer-file.sh .devnet/allocs-l1.json ./packages/contracts-bedrock \
		|| make devnet-allocs
	PYTHONPATH=./bedrock-devnet $(PYTHON) ./bedrock-devnet/main.py --monorepo-dir=.
.PHONY: devnet-up

# alias for devnet-up
devnet-up-deploy: devnet-up

devnet-test: pre-devnet
	PYTHONPATH=./bedrock-devnet $(PYTHON) ./bedrock-devnet/main.py --monorepo-dir=. --test
.PHONY: devnet-test

devnet-down:
	@(cd ./ops-bedrock && GENESIS_TIMESTAMP=$(shell date +%s) docker compose stop)
.PHONY: devnet-down

devnet-clean:
	rm -rf ./packages/contracts-bedrock/deployments/devnetL1
	rm -rf ./.devnet
	cd ./ops-bedrock && docker compose down
	docker image ls 'ops-bedrock*' --format='{{.Repository}}' | xargs -r docker rmi
	docker volume ls --filter name=ops-bedrock --format='{{.Name}}' | xargs -r docker volume rm
.PHONY: devnet-clean

devnet-allocs: pre-devnet
	PYTHONPATH=./bedrock-devnet $(PYTHON) ./bedrock-devnet/main.py --monorepo-dir=. --allocs

devnet-logs:
	@(cd ./ops-bedrock && docker compose logs -f)
	.PHONY: devnet-logs

test-unit:
	make -C ./op-node test
	make -C ./op-proposer test
	make -C ./op-batcher test
	make -C ./op-e2e test
	pnpm test
.PHONY: test-unit

test-integration:
	bash ./ops-bedrock/test-integration.sh \
		./packages/contracts-bedrock/deployments/devnetL1
.PHONY: test-integration

# Remove the baseline-commit to generate a base reading & show all issues
semgrep:
	$(eval DEV_REF := $(shell git rev-parse develop))
	SEMGREP_REPO_NAME=ethereum-optimism/optimism semgrep ci --baseline-commit=$(DEV_REF)
.PHONY: semgrep

clean-node-modules:
	rm -rf node_modules
	rm -rf packages/**/node_modules

tag-bedrock-go-modules:
	./ops/scripts/tag-bedrock-go-modules.sh $(BEDROCK_TAGS_REMOTE) $(VERSION)
.PHONY: tag-bedrock-go-modules

update-op-geth:
	./ops/scripts/update-op-geth.py
.PHONY: update-op-geth

bedrock-markdown-links:
	docker run --init -it -v `pwd`:/input lycheeverse/lychee --verbose --no-progress --exclude-loopback \
		--exclude twitter.com --exclude explorer.optimism.io --exclude linux-mips.org --exclude vitalik.ca \
		--exclude-mail /input/README.md "/input/specs/**/*.md"

install-geth:
	./ops/scripts/geth-version-checker.sh && \
	(echo "Geth versions match, not installing geth..."; true) || \
	(echo "Versions do not match, installing geth!"; \
	go install -v github.com/ethereum/go-ethereum/cmd/geth@$(shell cat .gethrc); \
	echo "Installed geth!"; true)
.PHONY: install-geth

### Rootstock ###

rsk-regtest-log:
	docker exec -ti -w "/var/lib/rsk/logs" rsk_regtest /bin/bash -c "tail -f rsk.log"
.PHONY: rsk-regtest-log

rsk-regtest-up:
	docker start rsk_regtest && \
	make rsk-regtest-log
.PHONY: rsk-regtest-up

rsk-regtest-down:
	docker stop rsk_regtest
.PHONY: rsk-regtest-up

rsk-regtest-stop:
	docker stop rsk_regtest
.PHONY: rsk-regtest-stop

rsk-regtest-delete:
	docker rm rsk_regtest
.PHONY: rsk-regtest-delete

rsk-regtest-start:
	docker run --name rsk_regtest -d -it \
	-p 5050:5050 -p 4444:4444 -p 4445:4445 \
  -v $(PATH_OPSTACK)/rskj.logback.xml:/etc/rsk/logback.xml \
  -v $(PATH_OPSTACK)/rskj.node.conf:/etc/rsk/node.conf \
  franciscotobar/rskj:optimism-6.1.0 --regtest --reset
.PHONY: rsk-regtest-start

take-5:
	sleep 5
.PHONY: take-5

rsk-regtest-restart: rsk-regtest-stop	rsk-regtest-delete	rsk-regtest-start

.PHONY: rsk-regtest-restart

rsk-regtest-start-log: rsk-regtest-start take-5 rsk-regtest-log

.PHONY: rsk-regtest-restart

rsk-regtest-restart-log: rsk-regtest-restart take-5 rsk-regtest-log

.PHONY: rsk-regtest-restart-log

# https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#build-the-optimism-monorepo
rsk-build:
	pnpm i &&  make op-node op-batcher op-proposer && pnpm build --skipNxCache
.PHONY: rsk-build

# https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#fill-out-environment-variables
rsk-env:
	cp .envrc.example .envrc && direnv allow
	# sed L1_RPC_URL, L1_CHAIN_ID, L1_RPC_KIND
	# sed PATH_*s.
	# Prob also PRIVATE_KEY
	# and admin, batcher, proposer and sequencer details
.PHONY: rsk-env

# https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#generate-addresses
rsk-wallets:
	direnv allow && \
	echo "Send 50 rbtc to create2 deployer" && \
	cast send --from 0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826 --rpc-url "$(L1_RPC_URL)" --unlocked --value 50ether 0x3fAB184622Dc19b6109349B94811493BF2a45362 --legacy && \
	echo "Send 50 rbtc to GS_ADMIN_ADDRESS" && \
	cast send --from 0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826 --rpc-url "$(L1_RPC_URL)" --unlocked --value 50ether "$(GS_ADMIN_ADDRESS)" --legacy && \
	echo "Send 50 rbtc to GS_BATCHER_ADDRESS" && \
	cast send --from 0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826 --rpc-url "$(L1_RPC_URL)" --unlocked --value 50ether "$(GS_BATCHER_ADDRESS)" --legacy && \
	echo "Send 50 rbtc to GS_SEQUENCER_ADDRESS" && \
	cast send --from 0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826 --rpc-url "$(L1_RPC_URL)" --unlocked --value 50ether "$(GS_SEQUENCER_ADDRESS)" --legacy && \
	echo "Send 50 rbtc to GS_PROPOSER_ADDRESS" && \
	cast send --from 0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826 --rpc-url "$(L1_RPC_URL)" --unlocked --value 50ether "$(GS_PROPOSER_ADDRESS)" --legacy
.PHONY: rsk-wallets

# https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#configure-your-network
rsk-config:
	[ $(PWD) != $(PATH_CONTRACTS) ] && cd $(PATH_CONTRACTS) && \
	./scripts/regtest/config.sh
.PHONY: rsk-config


# add create2 clone, deploy, etc ...
rsk-create2:
	[ $(PWD) != $(PATH_CONTRACTS) ] && cd $(PATH_CONTRACTS) && \
	direnv allow && \
	if [ $$(cast codesize 0x4e59b44847b379578588920cA78FbF26c0B4956C --rpc-url $(L1_RPC_URL)) -eq 0 ]; then \
	cast publish --rpc-url "$(L1_RPC_URL)" 0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222 \
	; fi
.PHONY: rsk-create2

# https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#deploy-the-l1-contracts
rsk-deploy:
	[ $(PWD) != $(PATH_CONTRACTS) ] && cd $(PATH_CONTRACTS) && \
	direnv allow && \
	forge script scripts/Deploy.s.sol:Deploy -vvv --legacy --slow --rpc-url "$(L1_RPC_URL)" --broadcast --private-key "$(GS_ADMIN_PRIVATE_KEY)" --with-gas-price 65164000
.PHONY: rsk-deploy

rsk-deploy-sync:
	[ $(PWD) != $(PATH_CONTRACTS) ] && cd $(PATH_CONTRACTS) && \
	direnv allow && \
	forge script scripts/Deploy.s.sol:Deploy --sig 'sync()' --rpc-url $(L1_RPC_URL) -vvv --legacy --private-key $(GS_ADMIN_PRIVATE_KEY) --broadcast
.PHONY: rsk-deploy-sync

rsk-prepare-l1: rsk-wallets rsk-config rsk-create2 rsk-deploy rsk-deploy-sync

.PHONY: rsk-prepare-l1

# https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#generate-the-l2-config-files
rsk-create-genesis:
	[ $(PWD) != $(PATH_CLIENT_CONSENSUS) ] && cd $(PATH_CLIENT_CONSENSUS) && \
	go run cmd/main.go genesis l2 \
    --deploy-config $(PATH_CONTRACTS)/deploy-config/regtest.json \
    --deployment-dir $(PATH_CONTRACTS)/deployments/regtest \
    --outfile.l2 genesis.json \
    --outfile.rollup rollup.json \
    --l1-rpc $(L1_RPC_URL) && \
	cp genesis.json $(PATH_CLIENT_EXECUTION)
.PHONY: rsk-create-genesis

rsk-jwt:
	[ $(PWD) != $(PATH_CLIENT_CONSENSUS) ] && cd $(PATH_CLIENT_CONSENSUS) && \
	openssl rand -hex 32 > jwt.txt && \
	cp jwt.txt $(PATH_CLIENT_EXECUTION)
.PHONY: rsk-jwt

rsk-prepare: rsk-prepare-l1 rsk-create-genesis rsk-jwt

.PHONY: rsk-prepare

# https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#initialize-op-geth
rsk-execution-init:
	[ $(PWD) != $(PATH_CLIENT_EXECUTION) ] && cd $(PATH_CLIENT_EXECUTION) && \
	if [ -d $(PATH_CLIENT_EXECUTION)/datadir ]; then rm -rf datadir; fi && \
	mkdir -p datadir && \
	build/bin/geth init --datadir=datadir genesis.json
.PHONY: rsk-execution-init

# https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#start-op-geth
rsk-execution-run:
	[ $(PWD) != $(PATH_CLIENT_EXECUTION) ] && cd $(PATH_CLIENT_EXECUTION) && \
	./build/bin/geth \
    --datadir ./datadir \
    --http \
    --http.corsdomain="*" \
    --http.vhosts="*" \
    --http.addr=0.0.0.0 \
    --http.api=web3,debug,eth,txpool,net,engine \
    --ws \
    --ws.addr=0.0.0.0 \
    --ws.port=8546 \
    --ws.origins="*" \
    --ws.api=debug,eth,txpool,net,engine \
    --syncmode=full \
    --gcmode=archive \
    --nodiscover \
    --maxpeers=0 \
    --networkid=42069 \
    --authrpc.vhosts="*" \
    --authrpc.addr=0.0.0.0 \
    --authrpc.port=8551 \
    --authrpc.jwtsecret=./jwt.txt \
    --rollup.disabletxpoolgossip=true
.PHONY: rsk-execution-run

rsk-execution-fresh: rsk-prepare rsk-execution-init rsk-execution-run

.PHONY: rsk-execution-fresh

# https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#start-op-node
rsk-consensus-run:
	[ $(PWD) != $(PATH_CLIENT_CONSENSUS) ] && cd $(PATH_CLIENT_CONSENSUS) && \
	./bin/op-node \
	--l2=http://localhost:8551 \
	--l2.jwt-secret=./jwt.txt \
	--sequencer.enabled \
	--sequencer.l1-confs=0 \
	--verifier.l1-confs=0 \
	--rollup.config=./rollup.json \
	--rpc.addr=0.0.0.0 \
	--rpc.port=8547 \
	--p2p.disable \
	--rpc.enable-admin \
	--p2p.sequencer.key=$(GS_SEQUENCER_PRIVATE_KEY) \
	--l1=$(L1_RPC_URL) \
	--l1.trustrpc \
	--l1.rpckind=$(L1_RPC_KIND)
.PHONY: rsk-consensus-run

# https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#start-op-batcher
rsk-batcher-run:
	[ $(PWD) != $(PATH_OPSTACK)/op-batcher ] && cd $(PATH_OPSTACK)/op-batcher && \
	./bin/op-batcher \
    --l2-eth-rpc=http://localhost:8545 \
    --rollup-rpc=http://localhost:8547 \
    --poll-interval=1s \
    --sub-safety-margin=4 \
    --num-confirmations=1 \
    --safe-abort-nonce-too-low-count=3 \
    --resubmission-timeout=30s \
    --rpc.addr=0.0.0.0 \
    --rpc.port=8548 \
    --rpc.enable-admin \
    --max-channel-duration=1 \
    --l1-eth-rpc=$(L1_RPC_URL) \
    --private-key=$(GS_BATCHER_PRIVATE_KEY)
.PHONY: rsk-batcher-run

# https://docs.optimism.io/builders/chain-operators/tutorials/create-l2-rollup#start-op-proposer
rsk-proposer-run:
	[ $(PWD) != $(PATH_OPSTACK)/op-proposer ] && cd $(PATH_OPSTACK)/op-proposer && \
	./bin/op-proposer \
    --poll-interval=1s \
    --rpc.port=8560 \
    --rollup-rpc=http://localhost:8547 \
    --allow-non-finalized=true \
    --l2oo-address=$$(cat $(PATH_CONTRACTS)/deployments/regtest/L2OutputOracleProxy.json | jq -r .address) \
    --private-key=$(GS_PROPOSER_PRIVATE_KEY) \
    --l1-eth-rpc=$(L1_RPC_URL)
.PHONY: rsk-proposer-run
