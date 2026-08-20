# Breaking-change migrations

Some Logos Blockchain releases reset the genesis block or otherwise make existing local chain state incompatible. When that happens, you must wipe `~/.logos-node/data/` and regenerate `user_config.yaml`.

## How `logosup` handles it

- **Auto-detected during update** — `logosup update` checks the target version against a list of known breaking releases (maintained in `lib/releases.sh` as `LOGOS_BREAKING_VERSIONS`). If detected, it prompts for a one-step migration instead of the standard update.
- **Manual** — run `logosup reset` (or `logosup reset -y` for non-interactive) at any time to wipe local data and regenerate config against the currently-installed node version.

## What the migration does

1. Stops the node and monitoring stack
2. Backs up `~/.logos-node/user_config.yaml` to `user_config.yaml.pre-migration-<timestamp>`
3. Deletes `~/.logos-node/data/` (chain DB + logs)
4. Rebuilds the Docker image
5. Regenerates `user_config.yaml`. If a `keystore.yaml` exists (any 0.2.0+ install), your wallet key identities are preserved via the node's `update-config` command; 0.1.2-era configs are converted with `migrate-from-0.1.2`, also preserving keys. Only a fully fresh install generates new keys.
6. Restarts the node (and monitoring, if it was running)

## After migration

You must re-claim faucet funds — the new chain starts from zero, so previous balances do not carry over. The pre-migration backup is preserved if you want to recover the old keys; see [Discord guidance](https://github.com/logos-blockchain/logos-blockchain/releases/tag/0.1.2) on which sections are portable.
