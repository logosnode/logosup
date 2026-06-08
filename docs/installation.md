# Installation & Docker setup

`logosup` automates the full [Logos Blockchain quickstart](https://github.com/logos-co/logos-docs/blob/main/docs/blockchain/get-started/run-a-logos-blockchain-node-from-cli.md) flow.

## What `install.sh` does

The one-line installer (`curl … | bash`):

1. Checks prerequisites (Docker, git, curl) and offers to install anything missing
2. Handles Docker group permissions on Linux
3. Clones this repo to `~/.logos-node/cli/`
4. Creates `logosup`, `logos-node`, and `logosnode` symlinks in your `PATH`

After this, the `logosup` command is available globally.

## What `logosup install` does

1. Fetches the latest [Logos Blockchain release](https://github.com/logos-blockchain/logos-blockchain/releases/) and matching ZK circuits version
2. Builds a Docker image containing the node binary and circuits
3. Runs `logos-blockchain-node init` inside the container to generate `user_config.yaml` with fresh cryptographic keys and your auto-detected public IP
4. Displays your wallet keys and the faucet URL
5. Optionally runs the security hardening flow (firewall, SSH, fail2ban, auto-updates)
6. Optionally sets up monitoring (Grafana + Prometheus + exporter)
7. Starts the node

## Quickstart-guide mapping

| Quickstart step | What `logosup` does |
|-----------------|----------------------|
| Download node binary | Docker image downloads it at build time |
| Download ZK circuits | Docker image downloads and installs them at build time |
| Install circuits to `~/.logos-blockchain-circuits` | Baked into the image at `/app/circuits`, set via `LOGOS_BLOCKCHAIN_CIRCUITS` env var |
| Run `logos-blockchain-node init` with bootstrap peers | `logosup install` runs init inside the container, generates `user_config.yaml` with fresh keys |
| Run the node | `logosup start` launches the container via Docker Compose |
| Find wallet keys | `logosup keys` parses and displays them |
| Request faucet tokens | `logosup faucet` shows keys + faucet URL, opens browser |
| Check consensus state (`/cryptarchia/info`) | `logosup status` queries and displays it |
| Check peer connectivity (`/network/info`) | `logosup status` queries and displays it |
| Check wallet balance | `logosup status` shows balance for each key |
| Consensus participation | Automatic after UTXO ages ~3.5 hours |
| Inscribe text on-chain | `logosup inscribe` runs the text sequencer inside the container |

## Docker setup

The node runs inside a Docker container based on `debian:trixie-slim` (glibc 2.39+):

- **Node binary and ZK circuits** are downloaded from GitHub releases and baked into the image at build time — no manual download or extraction needed
- **`user_config.yaml`** is mounted read-only from `~/.logos-node/`
- **Data directory** (`~/.logos-node/data/`) is bind-mounted for RocksDB, logs, and other runtime state
- **Runs as your host user** (UID/GID) to avoid permission issues
- **Health check** polls the node's `/cryptarchia/info` API endpoint
- **Restart policy** `unless-stopped` keeps the node running across reboots
- **Ports**: `8080` (HTTP API), `3000/udp` (libp2p peer-to-peer)
- **Network**: `logosnode-net` (Docker bridge network, shared with the monitoring stack if enabled)

## After install

1. **Get testnet tokens** — run `logosup faucet` to see your wallet keys and the faucet URL. Visit the [testnet faucet](https://testnet.blockchain.logos.co/web/faucet/), paste one of your keys, and request funds.
2. **Wait for UTXO maturity** — tokens must age approximately 3.5 hours (two epochs) before your node can participate in the consensus lottery.
3. **Monitor** — `logosup status` shows consensus mode (Bootstrapping → Online), peer count, and wallet balances. Compare against the [testnet dashboard](https://testnet.blockchain.logos.co/web/).
