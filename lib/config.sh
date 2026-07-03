#!/usr/bin/env bash
# DESCRIPTION: Configuration file management
# Compatible with bash 3+ (no associative arrays)

LOGOS_NODE_DIR="${LOGOS_NODE_DIR:-$HOME/.logos-node}"
LOGOS_SETTINGS_FILE="$LOGOS_NODE_DIR/settings.env"

# ── Parse network.yml ─────────────────────────────────────────────────
# Simple YAML parser for our flat config (no dependencies needed)

_parse_network_yml() {
    local yml_file="$1"
    [[ -f "$yml_file" ]] || return 1

    # Parse bootstrap_peers list into comma-separated string
    local peers=""
    local in_peers=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^bootstrap_peers: ]]; then
            in_peers=true
            continue
        fi
        if [[ "$in_peers" == true ]]; then
            # Skip blank lines and full-line comments without ending the block.
            if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
                continue
            fi
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(.*) ]]; then
                local peer="${BASH_REMATCH[1]}"
                peer="${peer%%[[:space:]]*#*}"  # strip inline comments
                peer="${peer%%[[:space:]]}"     # strip trailing whitespace
                if [[ -n "$peers" ]]; then
                    peers="${peers},${peer}"
                else
                    peers="$peer"
                fi
            else
                in_peers=false
            fi
        fi
    done < "$yml_file"

    [[ -n "$peers" ]] && LOGOS_BOOTSTRAP_PEERS="$peers"

    # Parse simple key: value fields
    local val
    val="$(_yml_get "$yml_file" "network")"       && LOGOS_NETWORK="$val"
    val="$(_yml_get "$yml_file" "node_repo")"      && LOGOS_NODE_REPO="$val"
    val="$(_yml_get "$yml_file" "cli_repo")"       && LOGOS_CLI_REPO="$val"
    val="$(_yml_get "$yml_file" "api_port")"       && LOGOS_API_PORT="$val"
    val="$(_yml_get "$yml_file" "udp_port")"       && LOGOS_UDP_PORT="$val"
    val="$(_yml_get "$yml_file" "faucet_url")"     && LOGOS_FAUCET_URL="$val"
    val="$(_yml_get "$yml_file" "dashboard_url")"  && LOGOS_DASHBOARD_URL="$val"
}

# Get a simple top-level key from a YAML file
_yml_get() {
    local file="$1" key="$2"
    local val
    val="$(grep "^${key}:" "$file" 2>/dev/null | head -1 | sed "s/^${key}:[[:space:]]*//" | sed 's/[[:space:]]*#.*//' | sed 's/[[:space:]]*$//')"
    [[ -n "$val" ]] && echo "$val"
}

# ── Defaults ──────────────────────────────────────────────────────────

_set_defaults() {
    : "${LOGOS_NETWORK:=testnet}"
    : "${LOGOS_NODE_VERSION:=latest}"
    : "${LOGOS_CIRCUITS_VERSION:=latest}"
    : "${LOGOS_API_PORT:=8080}"
    : "${LOGOS_UDP_PORT:=3000}"
    : "${LOGOS_FAUCET_URL:=https://testnet.blockchain.logos.co/web/faucet/}"
    : "${LOGOS_DASHBOARD_URL:=https://testnet.blockchain.logos.co/web/}"
    : "${LOGOS_DOCKER_IMAGE:=logos-node}"
    : "${LOGOS_CONTAINER_NAME:=logos-node}"
    : "${LOGOS_NODE_REPO:=logos-blockchain/logos-blockchain}"
    : "${LOGOS_CLI_REPO:=logosnode/logosup}"
    # Bootstrap peers for the current testnet release. Update these whenever the
    # network rotates peer IDs (e.g. on a breaking-genesis release).
    # Source: https://github.com/logos-blockchain/logos-blockchain/releases/tag/0.1.2
    : "${LOGOS_BOOTSTRAP_PEERS:=/ip4/65.109.51.37/udp/3000/quic-v1,/ip4/65.109.51.37/udp/3001/quic-v1,/ip4/65.109.51.37/udp/3002/quic-v1,/ip4/65.109.51.37/udp/3003/quic-v1}"
    : "${LOGOS_GRAFANA_PORT:=3001}"
    : "${LOGOS_GRAFANA_AUTH:=false}"
    : "${LOGOS_GRAFANA_PASSWORD:=logos}"
    # Optional: public IPv4 for nodes with a known static IP. When set, we pass
    # --external-address /ip4/<ip>/udp/<port>/quic-v1 to init-config so the
    # node advertises this address to peers and disables NAT traversal.
    : "${LOGOS_EXTERNAL_IP:=}"

    export LOGOS_NETWORK LOGOS_NODE_VERSION LOGOS_CIRCUITS_VERSION LOGOS_API_PORT LOGOS_UDP_PORT
    export LOGOS_FAUCET_URL LOGOS_DASHBOARD_URL LOGOS_DOCKER_IMAGE LOGOS_CONTAINER_NAME
    export LOGOS_NODE_REPO LOGOS_CLI_REPO LOGOS_BOOTSTRAP_PEERS LOGOS_GRAFANA_PORT
    export LOGOS_GRAFANA_AUTH LOGOS_GRAFANA_PASSWORD LOGOS_EXTERNAL_IP
}

# ── Init & Load ───────────────────────────────────────────────────────

init_config() {
    mkdir -p "$LOGOS_NODE_DIR" && chmod 700 "$LOGOS_NODE_DIR"

    if [[ ! -f "$LOGOS_SETTINGS_FILE" ]]; then
        log_info "Creating default settings at $LOGOS_SETTINGS_FILE"
        cat > "$LOGOS_SETTINGS_FILE" << 'SETTINGS'
# Logos Node settings
# Network-specific values (peers, ports, URLs) come from network.yml.
# Override them here if needed.

LOGOS_NODE_VERSION=latest
LOGOS_DOCKER_IMAGE=logos-node
LOGOS_CONTAINER_NAME=logos-node

# Optional: set this to your public IPv4 if the node has a known static IP.
# When set, we advertise this address to peers and skip NAT traversal.
# LOGOS_EXTERNAL_IP=203.0.113.42
SETTINGS
        chmod 600 "$LOGOS_SETTINGS_FILE"
    fi
}

load_config() {
    # 1. Load network.yml from the CLI repo (source of truth for network config)
    local network_yml
    if [[ -n "${LOGOS_NODE_LIB:-}" ]]; then
        network_yml="$(dirname "$LOGOS_NODE_LIB")/network.yml"
    fi
    # Also check the installed CLI location
    if [[ ! -f "${network_yml:-}" ]] && [[ -f "$LOGOS_NODE_DIR/cli/network.yml" ]]; then
        network_yml="$LOGOS_NODE_DIR/cli/network.yml"
    fi
    if [[ -f "${network_yml:-}" ]]; then
        _parse_network_yml "$network_yml"
    fi

    # Snapshot network-identity fields so we can detect stale overrides in
    # settings.env (e.g. an old install that pinned LOGOS_BOOTSTRAP_PEERS to
    # peer IDs that have since been rotated).
    LOGOS_NET_BOOTSTRAP_PEERS="${LOGOS_BOOTSTRAP_PEERS:-}"
    LOGOS_NET_FAUCET_URL="${LOGOS_FAUCET_URL:-}"
    LOGOS_NET_DASHBOARD_URL="${LOGOS_DASHBOARD_URL:-}"
    LOGOS_NET_NETWORK="${LOGOS_NETWORK:-}"

    # 2. Override with user settings (settings.env takes precedence)
    if [[ -f "$LOGOS_SETTINGS_FILE" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$LOGOS_SETTINGS_FILE"
        set +a
    fi

    # 3. Fill in any remaining defaults
    _set_defaults

    # 4. Warn (once) if settings.env masks network-identity fields. Quiet by
    # default; loud when the override differs from the network.yml value.
    _warn_settings_drift
}

# Returns 0 (and echoes drifted key names, one per line) if settings.env
# overrides any network-identity field with a value that differs from
# network.yml. Returns 1 if there is no drift.
check_settings_drift() {
    [[ -f "$LOGOS_SETTINGS_FILE" ]] || return 1
    local drifted=()
    _drift_check() {
        local key="$1" net="$2" current="$3"
        [[ -z "$net" ]] && return
        [[ "$current" == "$net" ]] && return
        grep -q "^${key}=" "$LOGOS_SETTINGS_FILE" 2>/dev/null && drifted+=("$key")
    }
    _drift_check "LOGOS_BOOTSTRAP_PEERS" "$LOGOS_NET_BOOTSTRAP_PEERS" "$LOGOS_BOOTSTRAP_PEERS"
    _drift_check "LOGOS_FAUCET_URL"      "$LOGOS_NET_FAUCET_URL"      "$LOGOS_FAUCET_URL"
    _drift_check "LOGOS_DASHBOARD_URL"   "$LOGOS_NET_DASHBOARD_URL"   "$LOGOS_DASHBOARD_URL"
    _drift_check "LOGOS_NETWORK"         "$LOGOS_NET_NETWORK"         "$LOGOS_NETWORK"
    unset -f _drift_check
    [[ ${#drifted[@]} -eq 0 ]] && return 1
    printf '%s\n' "${drifted[@]}"
    return 0
}

# Strip drifted keys from settings.env so network.yml takes effect on next load.
clear_settings_drift() {
    [[ -f "$LOGOS_SETTINGS_FILE" ]] || return 0
    local key sed_args=()
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        sed_args+=("-e" "/^${key}=/d")
    done < <(check_settings_drift)
    [[ ${#sed_args[@]} -eq 0 ]] && return 0

    # Backup once, then strip the drifted lines.
    cp "$LOGOS_SETTINGS_FILE" "${LOGOS_SETTINGS_FILE}.pre-drift-cleanup-$(date +%Y%m%d-%H%M%S)"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i '' "${sed_args[@]}" "$LOGOS_SETTINGS_FILE"
    else
        sed -i "${sed_args[@]}" "$LOGOS_SETTINGS_FILE"
    fi
}

_warn_settings_drift() {
    # Single-fire guard: load_config runs both at dispatcher startup and inside
    # individual cmd_* functions, so without this the warning fires twice.
    # Also suppressed when the running command will prompt interactively
    # (cmd_update / cmd_reset set LOGOS_DRIFT_WARNED=1 ahead of time).
    [[ -n "${LOGOS_DRIFT_WARNED:-}" ]] && return 0
    local drifted
    drifted="$(check_settings_drift)" || return 0
    export LOGOS_DRIFT_WARNED=1
    # Inline message — common.sh may not be sourced yet at first load_config call,
    # so don't rely on log_* helpers / colors.
    {
        echo ""
        echo "⚠  settings.env overrides network.yml for:"
        while IFS= read -r k; do echo "    - $k"; done <<< "$drifted"
        echo "   These look like stale entries from a previous install."
        echo "   Run 'logos-node update' or 'logos-node reset' to clean them up,"
        echo "   or remove them manually from $LOGOS_SETTINGS_FILE"
        echo ""
    } >&2
}

# ── Settings helpers ──────────────────────────────────────────────────

save_setting() {
    local key="$1"
    local value="$2"

    if grep -q "^${key}=" "$LOGOS_SETTINGS_FILE" 2>/dev/null; then
        if [[ "$(uname -s)" == "Darwin" ]]; then
            sed -i '' "s|^${key}=.*|${key}=${value}|" "$LOGOS_SETTINGS_FILE"
        else
            sed -i "s|^${key}=.*|${key}=${value}|" "$LOGOS_SETTINGS_FILE"
        fi
    else
        echo "${key}=${value}" >> "$LOGOS_SETTINGS_FILE"
    fi
    export "$key=$value"
}

get_user_config_path() {
    echo "$LOGOS_NODE_DIR/user_config.yaml"
}

# Keystore file — separate from user_config.yaml since 0.2.0. Written by
# init-config alongside user_config.yaml, holds the operator's secret keys.
# Must stay chmod 600 like user_config.yaml.
get_keystore_path() {
    echo "$LOGOS_NODE_DIR/keystore.yaml"
}

get_compose_path() {
    echo "$LOGOS_NODE_DIR/docker-compose.yml"
}

# Look up the semantic role of a wallet public key from keystore.yaml.
# keystore.yaml has a `public_keys:` block mapping role names
# (LeaderFunding, VaucherMaster, Stake, SdpFunding, BlendZk, BlendSigning,
# NetworkSwarm, ...) to their hex public keys. Given a hex key, echoes the
# matching role, or nothing if unknown / keystore missing.
get_wallet_key_role() {
    local pk="$1"
    [[ -z "$pk" ]] && return 1
    local keystore
    keystore="$(get_keystore_path)"
    [[ -f "$keystore" ]] || return 1

    awk -v needle="$pk" '
        /^public_keys:[[:space:]]*$/ { in_block = 1; next }
        in_block && /^[a-zA-Z]/       { in_block = 0 }
        in_block && /^[[:space:]]+[A-Za-z][A-Za-z0-9]*:[[:space:]]*[a-f0-9]+/ {
            role = $1; sub(/:$/, "", role)
            if ($2 == needle) { print role; exit }
        }
    ' "$keystore"
}

# Read the LeaderFunding public key from keystore.yaml — this is the wallet
# key the cryptarchia leader service spends to claim slots, and the one
# operators need to fund from the faucet to participate in consensus.
# Echoes the 64-char hex, or nothing if keystore missing / role absent.
get_wallet_leader_pk() {
    local keystore
    keystore="$(get_keystore_path)"
    [[ -f "$keystore" ]] || return 1
    awk '
        /^public_keys:[[:space:]]*$/     { in_block = 1; next }
        in_block && /^[a-zA-Z]/          { exit }
        in_block && /^[[:space:]]+LeaderFunding:[[:space:]]*[a-f0-9]+/ {
            print $2; exit
        }
    ' "$keystore"
}

# Return the known_keys list with LeaderFunding first (if present) so status/
# wallet output leads with the address that matters most for consensus
# participation. Falls back to plain order when the keystore is absent or
# LeaderFunding isn't in known_keys.
get_wallet_keys_prioritized() {
    local keys leader
    keys="$(get_wallet_keys 2>/dev/null)" || return 1
    [[ -z "$keys" ]] && return 1
    leader="$(get_wallet_leader_pk 2>/dev/null)"
    if [[ -n "$leader" ]] && echo "$keys" | grep -qx "$leader"; then
        echo "$leader"
        echo "$keys" | grep -vx "$leader"
    else
        echo "$keys"
    fi
}

# Parse known_keys from user_config.yaml
get_wallet_keys() {
    local config
    config="$(get_user_config_path)"

    if [[ ! -f "$config" ]]; then
        return 1
    fi

    awk '/^[[:space:]]*known_keys:/{found=1; next} found && /^[[:space:]]+[a-f0-9]+:/{print $1; next} found{exit}' "$config" | tr -d ':'
}

# Extract the full known_keys block (public key: private key lines)
get_wallet_keys_full() {
    local config
    config="$(get_user_config_path)"

    if [[ ! -f "$config" ]]; then
        return 1
    fi

    awk '/^[[:space:]]*known_keys:/{found=1; print; next} found && /^[[:space:]]+[a-f0-9]+:/{print; next} found{exit}' "$config"
}
