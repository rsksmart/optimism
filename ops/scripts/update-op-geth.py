#!/usr/bin/env python3


import subprocess
import os


def main():
	for project in ('.', 'indexer'):
		print(f'Updating {project}...')
		update_mod(project)


def update_mod(project):
	print('Replacing...')
	subprocess.run([
		'go',
		'mod',
		'edit',
		'-replace',
		f'github.com/ethereum/go-ethereum=github.com/rsksmart/op-geth@8b4e5b074d5a19fd1397dd4dcbda424c52311464'
	], cwd=os.path.join(project), check=True)
	print('Tidying...')
	subprocess.run([
		'go',
		'mod',
		'tidy'
	], cwd=os.path.join(project), check=True)


if __name__ == '__main__':
	main()
