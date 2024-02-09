import argparse
import logging
import os
import subprocess
import json
import socket
import datetime
import time
import shutil
import http.client
from multiprocessing import Process, Queue
import concurrent.futures
from collections import namedtuple
import traceback


import devnet.log_setup

pjoin = os.path.join

parser = argparse.ArgumentParser(description='Bedrock devnet launcher')
parser.add_argument('--monorepo-dir', help='Directory of the monorepo', default=os.getcwd())
parser.add_argument('--allocs', help='Only create the allocs and exit', type=bool, action=argparse.BooleanOptionalAction)
parser.add_argument('--test', help='Tests the deployment, must already be deployed', type=bool, action=argparse.BooleanOptionalAction)

log = logging.getLogger()

class Bunch:
    def __init__(self, **kwds):
        self.__dict__.update(kwds)

class ChildProcess:
    def __init__(self, func, *args):
        self.errq = Queue()
        self.process = Process(target=self._func, args=(func, args))

    def _func(self, func, args):
        try:
            func(*args)
        except Exception as e:
            self.errq.put(str(e))

    def start(self):
        self.process.start()

    def join(self):
        self.process.join()

    def get_error(self):
        return self.errq.get() if not self.errq.empty() else None


def main():
    args = parser.parse_args()

    monorepo_dir = os.path.abspath(args.monorepo_dir)
    devnet_dir = pjoin(monorepo_dir, '.devnet')
    contracts_bedrock_dir = pjoin(monorepo_dir, 'packages', 'contracts-bedrock')
    deployment_dir = pjoin(contracts_bedrock_dir, 'deployments', 'regtest')
    op_node_dir = pjoin(args.monorepo_dir, 'op-node')
    op_rskj = pjoin(args.monorepo_dir, '../rsk/rskj')
    ops_bedrock_dir = pjoin(monorepo_dir, 'ops-bedrock')
    deploy_config_dir = pjoin(contracts_bedrock_dir, 'deploy-config')
    devnet_config_path = pjoin(deploy_config_dir, 'regtest.json')
    devnet_config_template_path = pjoin(deploy_config_dir, 'regtest-template.json')
    ops_chain_ops = pjoin(monorepo_dir, 'op-chain-ops')
    sdk_dir = pjoin(monorepo_dir, 'packages', 'sdk')

    paths = Bunch(
      mono_repo_dir=monorepo_dir,
      devnet_dir=devnet_dir,
      contracts_bedrock_dir=contracts_bedrock_dir,
      deployment_dir=deployment_dir,
      l1_deployments_path=pjoin(deployment_dir, '.deploy'),
      deploy_config_dir=deploy_config_dir,
      devnet_config_path=devnet_config_path,
      devnet_config_template_path=devnet_config_template_path,
      op_node_dir=op_node_dir,
      op_rskj=op_rskj,
      ops_bedrock_dir=ops_bedrock_dir,
      ops_chain_ops=ops_chain_ops,
      sdk_dir=sdk_dir,
      genesis_l1_path=pjoin(devnet_dir, 'genesis-l1.json'),
      genesis_l2_path=pjoin(devnet_dir, 'genesis-l2.json'),
      allocs_path=pjoin(devnet_dir, 'allocs-l1.json'),
      addresses_json_path=pjoin(devnet_dir, 'addresses.json'),
      sdk_addresses_json_path=pjoin(devnet_dir, 'sdk-addresses.json'),
      rollup_config_path=pjoin(devnet_dir, 'rollup.json')
    )

    if args.test:
        log.info('Testing deployed devnet')
        devnet_test(paths)
        return

    os.makedirs(devnet_dir, exist_ok=True)

    if args.allocs:
        generate_allocs(paths)
        return

    git_commit = subprocess.run(['git', 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()
    git_date = subprocess.run(['git', 'show', '-s', "--format=%ct"], capture_output=True, text=True).stdout.strip()

    # CI loads the images from workspace, and does not otherwise know the images are good as-is
    if os.getenv('DEVNET_NO_BUILD') == "true":
        log.info('Skipping docker images build')
    else:
        log.info(f'Building docker images for git commit {git_commit} ({git_date})')
        run_command(['docker', 'compose', 'build', '--progress', 'plain',
                    '--build-arg', f'GIT_COMMIT={git_commit}', '--build-arg', f'GIT_DATE={git_date}'],
                    cwd=paths.ops_bedrock_dir, env={
            'PWD': paths.ops_bedrock_dir,
            'DOCKER_BUILDKIT': '1', # (should be available by default in later versions, but explicitly enable it anyway)
            'COMPOSE_DOCKER_CLI_BUILD': '1'  # use the docker cache
        })

    log.info('Devnet starting')
    devnet_deploy(paths)


def deploy_contracts(paths):
    wait_up(8545)
    wait_for_rpc_server('127.0.0.1:8545')
    res = eth_accounts('127.0.0.1:8545')

    response = json.loads(res)
    account = response['result'][0]
    log.info(f'Deploying with {account}')

    # send some ether to the create2 deployer account
    run_command([
        'cast', 'send', '--from', account,
        '--rpc-url', 'http://127.0.0.1:8545',
        '--unlocked', '--value', '1ether', '0x3fAB184622Dc19b6109349B94811493BF2a45362',
        '--legacy'
    ], env={}, cwd=paths.contracts_bedrock_dir)

    # deploy the create2 deployer
    run_command([
        'cast', 'publish', '--rpc-url', 'http://127.0.0.1:8545',
        '0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222'
    ], env={}, cwd=paths.contracts_bedrock_dir)

    fqn = 'scripts/Deploy.s.sol:Deploy'
    run_command([
        'forge', 'script', fqn, '-vvv', '--legacy', '--slow', '--sender', account,
        '--rpc-url', 'http://127.0.0.1:8545', '--broadcast',
        '--unlocked'
    ], env={}, cwd=paths.contracts_bedrock_dir)

    shutil.copy(paths.l1_deployments_path, paths.addresses_json_path)

    log.info('Syncing contracts.')
    run_command([
        'forge', 'script', fqn, '-vvv', '--legacy', '--sig', 'sync()',
        '--rpc-url', 'http://127.0.0.1:8545'
    ], env={}, cwd=paths.contracts_bedrock_dir)

def init_devnet_l1_deploy_config(paths, update_timestamp=False):
    deploy_config = read_json(paths.devnet_config_template_path)
    if update_timestamp:
        deploy_config['l1GenesisBlockTimestamp'] = '{:#x}'.format(int(time.time()))
    write_json(paths.devnet_config_path, deploy_config)

def extDumpState(url: str, account: str):
    log.info(f'Requesting state dump for account: {account}')
    conn = http.client.HTTPConnection(url)
    headers = {'Content-type': 'application/json'}
    body = f'{{"id":2, "jsonrpc":"2.0", "method": "ext_dumpState", "params":["{account}", true, true]}}'
    log.info(f'body: {body}')
    conn.request('POST', '/', body, headers)
    response = conn.getresponse()
    data = response.read().decode()
    log.info(f'extDumpState data: {data}')
    conn.close()

def copy_from_docker(guest_path: str, host_path: str, paths: Bunch):
    log.info(f'Copying {guest_path} from docker to {host_path}')
    run_command([
        'docker', 'cp', guest_path, host_path
    ], cwd=paths.ops_bedrock_dir, env={ 'PWD': paths.ops_bedrock_dir })
    # could verify here

def prefix_hash(hash:str):
    return hash if hash.startswith('0x') else f'0x{hash}'

def prefix_hash_keys_for(dictionary):
    prefixed_dict = {}
    for key in dictionary.keys():
        prefixed_key = prefix_hash(key)
        prefixed_dict[prefixed_key] = dictionary[key]
    return prefixed_dict

def extract_contract_data(account_data):
    contract = account_data['contract']
    data = {}
    data['codeHash'] = prefix_hash(contract['codeHash'])
    data['storage'] = prefix_hash_keys_for(contract['data'])
    data['code'] = prefix_hash(contract['code'])
    return data

def retrieve_dump_for(account: str, paths: Bunch):
    filename = pjoin(paths.devnet_dir, 'rskdump-' + account + '.json')
    log.info(f'Getting account dump from {filename}')
    if os.path.exists(filename):
        return read_json(filename)

def merge_alloc(allocs, account, account_data):
    log.info(f'Merging account data')

    if 'contract' in account_data:
        account_data = extract_contract_data(account_data)

    account_data['nonce'] = int(account_data['nonce']) if 'nonce' in account_data else 0
    account_data['balance'] = account_data['balance'] if 'balance' in account_data and account_data['balance'] else "0"
    allocs['accounts'][prefix_hash(account)] = account_data
    # TODO: missing account.root and account.key in allocs. Could be not needed?
    return allocs

def merge_rsk_genesis(generated_genesis, paths: Bunch):
    log.info('Merging generated genesis file with RSK regtest default')
    default_genesis = read_json(pjoin(paths.ops_bedrock_dir, 'rsk-dev.json'))

    return {**default_genesis, **generated_genesis}

def format_genesis_for_rsk(genesis_json, paths):
    log.info('Fromatting generated genesis file for use in RSK')
    base_genesis_keys = {
        'coinbase',
        'timestamp',
        'parentHash',
        'extraData',
        'nonce',
        'bitcoinMergedMiningHeader',
        'bitcoinMergedMiningMerkleProof',
        'bitcoinMergedMiningCoinbaseTransaction',
        'minimumGasPrice',
    }
    valid_rsk_genesis = {}
    # fill common
    for key in base_genesis_keys:
        valid_rsk_genesis[key] = genesis_json[key]
    valid_rsk_genesis['gasLimit'] = '0x989680'
    valid_rsk_genesis['difficulty'] = '0x0000000001'
    # handle special cases
    if 'mixHash' in genesis_json:
        valid_rsk_genesis['mixhash'] = genesis_json['mixHash']
    if 'alloc' in genesis_json:
      # transform alloc
      allocs = genesis_json['alloc']
      valid_allocs = {}
      for key in allocs.keys():
          valid_alloc = {}
          alloc = allocs[key]
          if 'balance' in alloc:
              valid_alloc['balance'] = alloc['balance'][2:]
          if 'nonce' in alloc:
              valid_alloc['nonce'] = alloc['nonce'][2:]
          if 'code' in alloc:
              valid_alloc['contract'] = {
                  'code': alloc['code'][2:]
              }

          if 'storage' in alloc:
              data = {}
              for data_point in alloc['storage'].keys():
                  data[data_point[2:]] = alloc['storage'][data_point][2:]
              valid_alloc['contract'] = {
                  **valid_alloc['contract'],
                  'data': data
              }
          valid_allocs[key] = valid_alloc

      valid_rsk_genesis['alloc'] = valid_allocs

    return valid_rsk_genesis




def generate_allocs(paths: Bunch):
    log.info('Generating L1 genesis state')
    init_devnet_l1_deploy_config(paths)

    run_command(['docker', 'compose', 'up', '-d', 'l1_deployer'], cwd=paths.ops_bedrock_dir, env={
        'PWD': paths.ops_bedrock_dir
    })

    try:
        forge = ChildProcess(deploy_contracts, paths)
        forge.start()
        forge.join()
        err = forge.get_error()
        if err:
            raise Exception(f"Exception occurred in child process: {err}")

        # need this to get the latest state root. However I am not sure that this is reliable enough. Maybe getting it from tx would be better?
        res = getLatestBlock('127.0.0.1:8545')
        response = json.loads(res)
        log.info(f'latest block response: {response}')
        state_root = response['result']['stateRoot']
        log.info(f'state_root: {state_root}')

        rsk_allocs = {"root": state_root, "accounts": {}}
        contracts = read_json(paths.addresses_json_path)
        # TODO: also do all EOA accounts
        for contract in contracts.keys():
            account = contracts[contract].lower()
            extDumpState('127.0.0.1:8545', account)
            if account.startswith('0x'):
                account = account[2:]
            filename = 'rskdump-' + account + '.json'
            copy_from_docker(f'l1_deployer:/var/lib/rsk/{filename}', paths.devnet_dir, paths)
            dump = retrieve_dump_for(account, paths)
            rsk_allocs = merge_alloc(rsk_allocs, account, dump[account])
        log.info(f'Writing allocs to {paths.allocs_path}')
        write_json(paths.allocs_path, rsk_allocs)
    finally:
        run_command([
            'docker', 'compose', 'down', 'l1_deployer'
        ], cwd=paths.ops_bedrock_dir)

# Bring up the devnet where the contracts are deployed to L1
def devnet_deploy(paths):
    if os.path.exists(paths.genesis_l1_path):
        log.info('L1 genesis already generated.')
    else:
        log.info('Generating L1 genesis.')
        if os.path.exists(paths.allocs_path) == False:
            generate_allocs(paths)

        # It's odd that we want to regenerate the regtest.json file with
        # an updated timestamp different than the one used in the devnet_l1_genesis
        # function.  But, without it, CI flakes on this test rather consistently.
        # If someone reads this comment and understands why this is being done, please
        # update this comment to explain.
        log.info('Updating timestamp in the config')
        init_devnet_l1_deploy_config(paths, update_timestamp=True)
        run_command([
            'go', 'run', 'cmd/main.go', 'genesis', 'l1',
            '--deploy-config', paths.devnet_config_path,
            '--l1-allocs', paths.allocs_path,
            '--l1-deployments', paths.addresses_json_path,
            '--outfile.l1', paths.genesis_l1_path,
        ], cwd=paths.op_node_dir)

    if not os.path.isfile(paths.genesis_l1_path):
        log.error(f'No L1 genesis file at {paths.genesis_l1_path}')
        exit(1)

    write_json(
        pjoin(paths.devnet_dir, 'rsk-dev.json'),
        format_genesis_for_rsk(
            merge_rsk_genesis(
                read_json(paths.genesis_l1_path),
                paths
            ), paths
        )
    )

    log.info('Starting L1.')
    run_command(['docker', 'compose', 'up', '-d', 'l1'], cwd=paths.ops_bedrock_dir, env={
        'PWD': paths.ops_bedrock_dir
    })
    wait_up(8545)
    wait_for_rpc_server('127.0.0.1:8545')

    if os.path.exists(paths.genesis_l2_path):
        log.info('L2 genesis and rollup configs already generated.')
    else:
        log.info('Generating L2 genesis and rollup configs.')
        run_command([
            'go', 'run', 'cmd/main.go', 'genesis', 'l2',
            '--l1-rpc', 'http://localhost:8545',
            '--deploy-config', paths.devnet_config_path,
            '--deployment-dir', paths.deployment_dir,
            '--outfile.l2', paths.genesis_l2_path,
            '--outfile.rollup', paths.rollup_config_path
        ], cwd=paths.op_node_dir)

    rollup_config = read_json(paths.rollup_config_path)
    addresses = read_json(paths.addresses_json_path)

    log.info('Bringing up L2.')
    run_command(['docker', 'compose', 'up', '-d', 'l2'], cwd=paths.ops_bedrock_dir, env={
        'PWD': paths.ops_bedrock_dir
    })
    wait_up(9545)
    wait_for_rpc_server('127.0.0.1:9545')

    l2_output_oracle = addresses['L2OutputOracleProxy']
    log.info(f'Using L2OutputOracle {l2_output_oracle}')
    batch_inbox_address = rollup_config['batch_inbox_address']
    log.info(f'Using batch inbox {batch_inbox_address}')

    log.info('Bringing up `op-node`, `op-proposer` and `op-batcher`.')
    run_command(['docker', 'compose', 'up', '-d', 'op-node', 'op-proposer', 'op-batcher'], cwd=paths.ops_bedrock_dir, env={
        'PWD': paths.ops_bedrock_dir,
        'L2OO_ADDRESS': l2_output_oracle,
        'SEQUENCER_BATCH_INBOX_ADDRESS': batch_inbox_address
    })

    log.info('Bringing up `artifact-server`')
    run_command(['docker', 'compose', 'up', '-d', 'artifact-server'], cwd=paths.ops_bedrock_dir, env={
        'PWD': paths.ops_bedrock_dir
    })

    log.info('Devnet ready.')


def eth_accounts(url):
    log.info(f'Fetch eth_accounts {url}')
    conn = http.client.HTTPConnection(url)
    headers = {'Content-type': 'application/json'}
    body = '{"id":2, "jsonrpc":"2.0", "method": "eth_accounts", "params":[]}'
    conn.request('POST', '/', body, headers)
    response = conn.getresponse()
    data = response.read().decode()
    conn.close()
    return data


def getLatestBlock(url):
    log.info(f'Fetch getBlockByNumber {url}')
    conn = http.client.HTTPConnection(url)
    headers = {'Content-type': 'application/json'}
    body = '{"id":3, "jsonrpc":"2.0", "method": "eth_getBlockByNumber", "params":["latest", true]}'
    conn.request('POST', '/', body, headers)
    response = conn.getresponse()
    data = response.read().decode()
    conn.close()
    return data


def wait_for_rpc_server(url):
    log.info(f'Waiting for RPC server at {url}')

    headers = {'Content-type': 'application/json'}
    body = '{"id":1, "jsonrpc":"2.0", "method": "eth_chainId", "params":[]}'

    while True:
        try:
            conn = http.client.HTTPConnection(url)
            conn.request('POST', '/', body, headers)
            response = conn.getresponse()
            if response.status < 300:
                log.info(f'RPC server at {url} ready')
                return
        except Exception as e:
            log.info(f'Waiting for RPC server at {url}')
            time.sleep(1)
        finally:
            if conn:
                conn.close()


CommandPreset = namedtuple('Command', ['name', 'args', 'cwd', 'timeout'])


def devnet_test(paths):
    # Check the L2 config
    run_command(
        ['go', 'run', 'cmd/check-l2/main.go', '--l2-rpc-url', 'http://localhost:9545', '--l1-rpc-url', 'http://localhost:8545'],
        cwd=paths.ops_chain_ops,
    )

    # Run the two commands with different signers, so the ethereum nonce management does not conflict
    # And do not use devnet system addresses, to avoid breaking fee-estimation or nonce values.
    run_commands([
        CommandPreset('erc20-test',
            ['npx', 'hardhat',  'deposit-erc20', '--network',  'regtest',
            '--l1-contracts-json-path', paths.addresses_json_path, '--signer-index', '14'],
            cwd=paths.sdk_dir, timeout=8*60),
            CommandPreset('eth-test',
            ['npx', 'hardhat',  'deposit-eth', '--network',  'regtest',
            '--l1-contracts-json-path', paths.addresses_json_path, '--signer-index', '15'],
            cwd=paths.sdk_dir, timeout=8*60)
    ], max_workers=2)


def run_commands(commands: list[CommandPreset], max_workers=2):
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = [executor.submit(run_command_preset, cmd) for cmd in commands]

        for future in concurrent.futures.as_completed(futures):
            result = future.result()
            if result:
                print(result.stdout)


def run_command_preset(command: CommandPreset):
    with subprocess.Popen(command.args, cwd=command.cwd,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as proc:
        try:
            # Live output processing
            for line in proc.stdout:
                # Annotate and print the line with timestamp and command name
                timestamp = datetime.datetime.utcnow().strftime('%H:%M:%S.%f')
                # Annotate and print the line with the timestamp
                print(f"[{timestamp}][{command.name}] {line}", end='')

            stdout, stderr = proc.communicate(timeout=command.timeout)

            if proc.returncode != 0:
                raise RuntimeError(f"Command '{' '.join(command.args)}' failed with return code {proc.returncode}: {stderr}")

        except subprocess.TimeoutExpired:
            raise RuntimeError(f"Command '{' '.join(command.args)}' timed out!")

        except Exception as e:
            raise RuntimeError(f"Error executing '{' '.join(command.args)}': {e}")

        finally:
            # Ensure process is terminated
            proc.kill()
    return proc.returncode


def run_command(args, check=True, shell=False, cwd=None, env=None, timeout=None):
    env = env if env else {}
    return subprocess.run(
        args,
        check=check,
        shell=shell,
        env={
            **os.environ,
            **env
        },
        cwd=cwd,
        timeout=timeout
    )


def wait_up(port, retries=10, wait_secs=1):
    for i in range(0, retries):
        log.info(f'Trying 127.0.0.1:{port}')
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.connect(('127.0.0.1', int(port)))
            s.shutdown(2)
            log.info(f'Connected 127.0.0.1:{port}')
            return True
        except Exception:
            time.sleep(wait_secs)

    raise Exception(f'Timed out waiting for port {port}.')


def write_json(path, data):
    with open(path, 'w+') as f:
        json.dump(data, f, indent='  ')


def read_json(path):
    with open(path, 'r') as f:
        return json.load(f)
