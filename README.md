# logosup

A CLI tool for installing, running, and managing a [Logos Blockchain](https://logos.co/) node. Handles Docker setup, configuration, updates, and monitoring — so you can go from zero to a running node in minutes.

> Previously `logos-node`. The CLI command was renamed to `logosup` in v0.4.0; the old `logos-node` and `logosnode` commands still work as aliases.

## Quick start

```sh
curl -sL https://raw.githubusercontent.com/logosnode/logosup/main/install.sh | bash
logosup install
```

The installer checks prerequisites, fetches the latest release, builds a Docker image, generates configuration and wallet keys, and optionally enables monitoring and security hardening.

## Requirements

- **Docker** with Docker Compose v2
- **git**, **curl**
- **OS**: Linux (x86_64, aarch64), macOS (Intel, Apple Silicon), or WSL2

Missing prerequisites are auto-installed via the system package manager (apt, dnf, pacman, brew) on supported platforms.

## Commands

| Command | Description |
|---------|-------------|
| `logosup install` | Full setup — download, build, configure, generate keys |
| `logosup start` / `stop` | Start or stop the node (+ monitoring) |
| `logosup status` | Consensus state, peers, wallet balances |
| `logosup logs` | Tail node logs (`-f`, `--tail=N`, `--since=1h`) |
| `logosup update` | Update node and/or CLI (`update node\|cli\|all`, `-b BRANCH`) |
| `logosup wallet` | Send transfers, check balance, look up transactions |
| `logosup keys` | Show, backup, or restore wallet keys |
| `logosup faucet` | Show keys + faucet URL, open in browser |
| `logosup inscribe` | Publish text inscriptions on-chain |
| `logosup monitor` | Manage Grafana + Prometheus stack |
| `logosup security` | Scan and harden server (firewall, SSH, fail2ban, auto-updates) |
| `logosup reset` | Wipe local data and regenerate config (after breaking releases) |
| `logosup version` / `help` | Self-explanatory |

## Documentation

- [Installation & Docker setup](docs/installation.md) — what `install.sh` and `logosup install` actually do
- [Usage guide](docs/usage.md) — wallet, faucet, inscribing, after-install steps
- [Monitoring](docs/monitoring.md) — Grafana dashboards, OTLP architecture, Pi cgroup fix
- [Security hardening](docs/security.md) — what `logosup security` checks and fixes
- [Configuration](docs/configuration.md) — `network.yml`, `settings.env`, data layout, extending, project structure
- [Breaking-change migrations](docs/migrations.md) — when and how to wipe local state

## Links

- [Logos Blockchain quickstart guide](https://github.com/logos-co/logos-docs/blob/main/docs/blockchain/get-started/run-a-logos-blockchain-node-from-cli.md)
- [Logos Blockchain releases](https://github.com/logos-blockchain/logos-blockchain/releases/)
- [Testnet faucet](https://testnet.blockchain.logos.co/web/faucet/) · [Testnet dashboard](https://testnet.blockchain.logos.co/web/)
- [Logos website](https://logos.co/)

## License

MIT
