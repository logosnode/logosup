#!/usr/bin/env bash
# DESCRIPTION: GitHub release detection and download helpers

# Versions that introduce breaking on-chain changes (genesis reset, incompatible
# state). Updating across one of these requires wiping local data and
# regenerating user_config.yaml. Add new entries here as the chain evolves.
LOGOS_BREAKING_VERSIONS=("0.1.2" "0.2.0" "0.2.1")

is_breaking_version() {
    local v="${1#v}"
    local b
    for b in "${LOGOS_BREAKING_VERSIONS[@]}"; do
        [[ "$v" == "${b#v}" ]] && return 0
    done
    return 1
}

# Fetch the latest release tag from a GitHub repo
# Usage: get_latest_release "owner/repo"
get_latest_release() {
    local repo="$1"
    local url="https://api.github.com/repos/${repo}/releases/latest"
    local response

    response="$(curl -sL -H "Accept: application/vnd.github.v3+json" "$url" 2>/dev/null)" || {
        log_error "Failed to fetch release info from $url"
        return 1
    }

    local tag
    tag="$(echo "$response" | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"

    if [[ -z "$tag" ]]; then
        log_error "Could not determine latest release for $repo"
        log_dim "API response may be rate-limited. Try again in a minute."
        return 1
    fi

    echo "$tag"
}

# List release assets for a given tag
# Usage: get_release_assets "owner/repo" "v0.2.1"
get_release_assets() {
    local repo="$1"
    local tag="$2"
    local url="https://api.github.com/repos/${repo}/releases/tags/${tag}"

    curl -sL -H "Accept: application/vnd.github.v3+json" "$url" 2>/dev/null | \
        grep '"browser_download_url"' | \
        sed -E 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

# Build the download URL for the node binary
# Pattern: logos-blockchain-node-linux-{arch}-{version}.tar.gz
get_node_binary_url() {
    local version="$1"
    local arch="$2"
    local repo="${LOGOS_NODE_REPO:-logos-blockchain/logos-blockchain}"

    echo "https://github.com/${repo}/releases/download/${version}/logos-blockchain-node-linux-${arch}-${version}.tar.gz"
}

# Fetch latest node release and set LOGOS_NODE_VERSION.
# Circuits used to be a separate tarball asset; since 0.1.3-rc.13 they're
# bundled into the node binary, so there is no per-arch circuits asset to
# probe or track anymore.
fetch_latest_versions() {
    log_step "Checking for latest Logos Blockchain release..."

    local tag
    tag="$(get_latest_release "$LOGOS_NODE_REPO")" || return 1

    # Strip leading 'v' if present for consistency
    LOGOS_NODE_VERSION="${tag#v}"

    log_info "Latest release: ${BOLD}${tag}${RESET}"
    log_info "Node version:   ${BOLD}${LOGOS_NODE_VERSION}${RESET}"
}

# Check for CLI tool updates
check_cli_update() {
    local cli_dir="$LOGOS_NODE_DIR/cli"

    if [[ ! -d "$cli_dir/.git" ]]; then
        return 0
    fi

    local local_head remote_head
    local_head="$(git -C "$cli_dir" rev-parse HEAD 2>/dev/null)"
    git -C "$cli_dir" fetch --quiet 2>/dev/null || return 0
    remote_head="$(git -C "$cli_dir" rev-parse '@{u}' 2>/dev/null)" || return 0

    if [[ "$local_head" != "$remote_head" ]]; then
        return 1  # update available
    fi
    return 0  # up to date
}
