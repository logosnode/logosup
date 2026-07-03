#!/usr/bin/env bash
# DESCRIPTION: Docker and docker-compose helpers

DOCKER_COMPOSE=""
DOCKER_CMD="docker"

# Check Docker is installed and running
check_docker() {
    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed."
        echo ""
        case "${LOGOS_OS:-}" in
            linux)
                log_info "Install Docker Engine: https://docs.docker.com/engine/install/"
                ;;
            macos)
                log_info "Install Docker Desktop: https://docs.docker.com/desktop/install/mac-install/"
                ;;
        esac
        if [[ "${LOGOS_WSL:-false}" == "true" ]]; then
            log_info "For WSL: enable Docker Desktop WSL 2 integration"
            log_info "https://docs.docker.com/desktop/wsl/"
        fi
        exit 1
    fi

    if ! docker info &>/dev/null 2>&1 && ! sudo docker info &>/dev/null 2>&1; then
        log_warn "Docker daemon is not running."
        case "${LOGOS_OS:-}" in
            linux)
                if confirm "Start Docker service now?"; then
                    log_info "Starting Docker..."
                    sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || true
                    sleep 3
                    local attempts=0
                    while [[ $attempts -lt 10 ]]; do
                        if docker info &>/dev/null 2>&1 || sudo docker info &>/dev/null 2>&1; then
                            log_success "Docker is running"
                            break
                        fi
                        sleep 2
                        attempts=$((attempts + 1))
                    done
                    if [[ $attempts -ge 10 ]]; then
                        die "Failed to start Docker. Please start it manually and try again."
                    fi
                else
                    die "Docker must be running. Start it and try again."
                fi
                ;;
            macos)
                log_info "Please open Docker Desktop from your Applications folder."
                die "Start Docker Desktop and try again."
                ;;
        esac
    fi

    # Determine if sudo is needed for docker daemon access
    if docker info &>/dev/null 2>&1; then
        DOCKER_CMD="docker"
    elif id -nG 2>/dev/null | grep -qw docker; then
        # User is in docker group but it's not active in this shell session.
        # Re-exec the entire logos-node command under the docker group.
        log_info "Activating docker group for this session..."
        exec sg docker -c "$(printf '%q ' "$LOGOS_NODE_ENTRY" "${LOGOS_NODE_ARGS[@]}")"
    elif sudo docker info &>/dev/null 2>&1; then
        DOCKER_CMD="sudo docker"
        log_warn "Docker requires sudo (user not in docker group)"
        log_dim "To fix permanently: ${BOLD}sudo usermod -aG docker \$USER${RESET}${DIM} then log out and back in"
    else
        die "Cannot connect to Docker daemon"
    fi

    # Detect docker compose command
    if $DOCKER_CMD compose version &>/dev/null 2>&1; then
        DOCKER_COMPOSE="$DOCKER_CMD compose"
    elif command -v docker-compose &>/dev/null; then
        if [[ "$DOCKER_CMD" == "sudo docker" ]]; then
            DOCKER_COMPOSE="sudo docker-compose"
        else
            DOCKER_COMPOSE="docker-compose"
        fi
    else
        log_error "Docker Compose is required but not found."
        log_info "Install: https://docs.docker.com/compose/install/"
        exit 1
    fi

    export DOCKER_COMPOSE DOCKER_CMD
}

# Generate docker-compose.yml from settings
generate_compose_file() {
    local compose_path
    compose_path="$(get_compose_path)"
    local dockerfile_dir
    dockerfile_dir="$(resolve_path "$(dirname "${BASH_SOURCE[0]}")/../docker")"

    local host_uid
    host_uid="$(id -u)"
    local host_gid
    host_gid="$(id -g)"

    cat > "$compose_path" << YAML
services:
  logos-node:
    build:
      context: ${dockerfile_dir}
      args:
        NODE_VERSION: "${LOGOS_NODE_VERSION}"
    image: ${LOGOS_DOCKER_IMAGE}:${LOGOS_NODE_VERSION}
    container_name: ${LOGOS_CONTAINER_NAME}
    restart: unless-stopped
    user: "${host_uid}:${host_gid}"
    ports:
      - "${LOGOS_API_PORT}:8080"
      - "${LOGOS_UDP_PORT}:3000/udp"
    working_dir: /app/data
    # Config lives OUTSIDE /app/data on purpose — mounting a file inside a
    # bind-mounted directory gets shadowed by the directory mount, and every
    # patch to the host file (init-config output, migrate-from-0.1.2 output,
    # OTLP/log/bind patches) becomes invisible to the running container.
    # /app/config.yaml sidesteps the overlap; command: overrides the
    # Dockerfile CMD to pick it up.
    volumes:
      - ${LOGOS_NODE_DIR}/user_config.yaml:/app/config.yaml:ro
      - ${LOGOS_NODE_DIR}/data:/app/data
    command: ["/app/config.yaml"]
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8080/cryptarchia/info"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 120s
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
    networks:
      - logosnode-net

networks:
  logosnode-net:
    name: logosnode-net
YAML

    log_success "Generated docker-compose.yml"
}

# Build the Docker image
docker_build() {
    local compose_path
    compose_path="$(get_compose_path)"

    log_step "Building Logos Node Docker image..."
    log_dim "This may take a few minutes on first run (downloading node binary + circuits)"

    $DOCKER_COMPOSE -f "$compose_path" build 2>&1 | while IFS= read -r line; do
        echo -e "  ${DIM}${line}${RESET}"
    done

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        log_error "Docker build failed"
        return 1
    fi
    log_success "Docker image built successfully"
}

# Run the node init-config command inside the container to generate
# user_config.yaml + keystore.yaml. Renamed from `init` in 0.2.0.
docker_init_config() {
    local compose_path
    compose_path="$(get_compose_path)"
    local config_path
    config_path="$(get_user_config_path)"
    local keystore_path
    keystore_path="$(get_keystore_path)"

    # Build init-config args. --http-host takes a full SocketAddr (host:port),
    # not just a host; port 8080 matches the container-internal API port that
    # the compose file forwards. --ibd populates
    # cryptarchia.network.bootstrap.ibd.peers from the -p peer IDs so the
    # node actually downloads historical blocks from bootstrap peers instead
    # of waiting on gossip forever (gossip only carries new blocks; without
    # IBD a fresh node hovers at height 0 with peers connected).
    local init_args=(
        --output /app/user_config.yaml
        --keystore /app/keystore.yaml
        --http-host 0.0.0.0:8080
        --ibd
    )

    # Bootstrap peers as -p /ip4/.../p2p/... (comma-separated in LOGOS_BOOTSTRAP_PEERS)
    IFS=',' read -ra peers <<< "$LOGOS_BOOTSTRAP_PEERS"
    for peer in "${peers[@]}"; do
        init_args+=("-p" "$peer")
    done

    # Optional public-IP hint: disables NAT traversal and advertises the
    # operator's known external address. Format: /ip4/<ip>/udp/<port>/quic-v1
    if [[ -n "${LOGOS_EXTERNAL_IP:-}" ]]; then
        init_args+=("--external-address" "/ip4/${LOGOS_EXTERNAL_IP}/udp/${LOGOS_UDP_PORT}/quic-v1")
        log_dim "Advertising external address: /ip4/${LOGOS_EXTERNAL_IP}/udp/${LOGOS_UDP_PORT}/quic-v1"
    fi

    log_step "Generating node configuration..."
    log_dim "Running logos-blockchain-node init-config with bootstrap peers"

    # Run init as the host user so it can write to the mounted volume
    local host_uid
    host_uid="$(id -u)"
    local host_gid
    host_gid="$(id -g)"

    # Ensure data directory exists
    mkdir -p "${LOGOS_NODE_DIR}/data"

    # Run init-config in a temporary container, writing outputs to the mounted volume
    $DOCKER_CMD run --rm \
        --user "${host_uid}:${host_gid}" \
        -v "${LOGOS_NODE_DIR}:/app" \
        -w /app \
        "${LOGOS_DOCKER_IMAGE}:${LOGOS_NODE_VERSION}" \
        init-config "${init_args[@]}" 2>&1 | while IFS= read -r line; do
            echo -e "  ${DIM}${line}${RESET}"
        done

    if [[ -f "$config_path" ]]; then
        chmod 600 "$config_path"
        if [[ -f "$keystore_path" ]]; then
            chmod 600 "$keystore_path"
            log_dim "Keystore written to $keystore_path (chmod 600)"
        else
            log_warn "Expected keystore.yaml alongside user_config.yaml but did not find it"
        fi

        # Safety net for the API bind — --http-host on init-config should
        # already put us on 0.0.0.0, but re-assert idempotently in case a
        # flag change or hand-edit slips 127.0.0.1 back in (silently
        # unreachable via the port map).
        patch_user_config_for_http_bind "$config_path"

        # Enable OTLP metrics push so the monitoring stack can scrape native
        # node metrics (mempool, consensus, blend, KMS, storage, etc.) via the
        # OTel collector. Idempotent — only patches `metrics: None`.
        patch_user_config_for_otlp "$config_path"

        # Disable redundant disk-based tracing logs. By default the node's
        # tracing module writes ~10GB/hour of DEBUG output to data/<prefix>.<hour>
        # files in the data dir, ON TOP OF streaming the same content to stdout
        # (which Docker captures with caps). Net effect: 100GB+ disk in a day,
        # the chain DB shares the same partition, operators get squeezed out.
        # Stdout via `logos-node logs` is sufficient for diagnostics. Idempotent.
        patch_user_config_for_log_files "$config_path"

        log_success "Node configuration generated at $config_path"
        return 0
    else
        log_error "Failed to generate node configuration"
        log_info "You may need to generate it manually. See: logos-blockchain-node init-config --help"
        return 1
    fi
}

# Run migrate-from-0.1.2 inside a temporary 0.2.0 container. Consumes the
# operator's existing user_config.yaml (with 0.1.2 shape and inline secret
# keys), produces a new user_config.yaml (0.2.0 shape) plus keystore.yaml.
# Preserves wallet identities across the genesis reset — funds do not carry
# over, but the operator's public keys stay stable.
#
# Idempotent guardrail: refuses to overwrite an already-migrated config
# (detects 0.2.0 shape via the presence of the `wallet:` top-level key).
docker_migrate_from_012() {
    local config_path
    config_path="$(get_user_config_path)"
    local keystore_path
    keystore_path="$(get_keystore_path)"

    [[ -f "$config_path" ]] || {
        log_error "No user_config.yaml found — nothing to migrate"
        return 1
    }

    # Detect if the file is already in 0.2.0 shape. Both 0.1.2 and 0.2.0 have
    # top-level `wallet:` and `kms:` sections; the discriminator is the presence
    # of `tip_poll:` under `cryptarchia.network.sync` — a stable 0.2.0-unique
    # marker. Re-running migrate-from-0.1.2 on an already-migrated config would
    # silently rotate the leader funding key, so this guard is load-bearing.
    if grep -qE '^[[:space:]]+tip_poll:[[:space:]]*$' "$config_path"; then
        log_dim "Config already in 0.2.0 shape — skipping migrate-from-0.1.2"
        return 0
    fi

    local host_uid
    host_uid="$(id -u)"
    local host_gid
    host_gid="$(id -g)"

    # migrate-from-0.1.2 does NOT carry initial_peers over from the old
    # config — the output always has network.backend.initial_peers: [] and
    # cryptarchia.network.bootstrap.ibd.peers: [] unless we pass -p peers
    # here (the release notes' quick-start relies on this too). Without
    # this, migrated nodes come up with zero fleet contacts and only find
    # peers through leftover DHT cache, which almost never surfaces the
    # 0.2.0 fleet. Reuse the same LOGOS_BOOTSTRAP_PEERS the fresh-install
    # path uses.
    local migrate_args=(
        migrate-from-0.1.2
        --old-config /app/user_config.yaml
        --new-config /app/user_config.migrated.yaml
        --keystore /app/keystore.yaml
        --http-host 0.0.0.0:8080
        --ibd
    )
    local _p
    IFS=',' read -ra _peers <<< "$LOGOS_BOOTSTRAP_PEERS"
    for _p in "${_peers[@]}"; do
        migrate_args+=("-p" "$_p")
    done
    if [[ -n "${LOGOS_EXTERNAL_IP:-}" ]]; then
        migrate_args+=("--external-address" "/ip4/${LOGOS_EXTERNAL_IP}/udp/${LOGOS_UDP_PORT}/quic-v1")
    fi

    log_step "Migrating 0.1.2 config to 0.2.0 (preserving wallet keys)..."

    # Old config passed in; new config written to a sibling path we rename after.
    $DOCKER_CMD run --rm \
        --user "${host_uid}:${host_gid}" \
        -v "${LOGOS_NODE_DIR}:/app" \
        -w /app \
        "${LOGOS_DOCKER_IMAGE}:${LOGOS_NODE_VERSION}" \
        "${migrate_args[@]}" 2>&1 | while IFS= read -r line; do
            echo -e "  ${DIM}${line}${RESET}"
        done

    if [[ ! -f "${LOGOS_NODE_DIR}/user_config.migrated.yaml" ]]; then
        log_error "migrate-from-0.1.2 did not produce a new config"
        return 1
    fi

    mv "${LOGOS_NODE_DIR}/user_config.migrated.yaml" "$config_path"
    chmod 600 "$config_path"
    [[ -f "$keystore_path" ]] && chmod 600 "$keystore_path"

    # Re-apply our compose-friendly tracing + bind patches (all idempotent).
    # patch_user_config_for_http_bind is a safety net: --http-host on
    # migrate-from-0.1.2 covers new runs, but any config that predates that
    # fix (or was hand-edited) is silently unreachable via the port map.
    patch_user_config_for_http_bind "$config_path"
    patch_user_config_for_otlp "$config_path"
    patch_user_config_for_log_files "$config_path"

    log_success "Migrated to 0.2.0 config shape; wallet keys preserved in $keystore_path"
    return 0
}

# Rewrite api.backend.listen_address so the node binds 0.0.0.0 inside the
# container. Docker's port map forwards host:8080 to container_ip:8080 — if
# the node listens on 127.0.0.1:8080 inside the container, the forward can't
# reach it and every host-side connection is reset by peer.
#
# init-config gets this right via --http-host, but migrate-from-0.1.2 in
# older code paths didn't pass it, so 0.1.2 configs that carried
# 127.0.0.1 through would land here silently broken. Idempotent: no-op if
# the address is already 0.0.0.0:*.
patch_user_config_for_http_bind() {
    local config_path="$1"
    [[ -f "$config_path" ]] || return 0
    grep -qE '^[[:space:]]+listen_address:[[:space:]]*127\.0\.0\.1:' "$config_path" || return 0

    sed_inplace 's|^\([[:space:]]\+\)listen_address:[[:space:]]*127\.0\.0\.1:|\1listen_address: 0.0.0.0:|' "$config_path"
    log_dim "Patched api.backend.listen_address 127.0.0.1 → 0.0.0.0 (for Docker port map)"
}

# Enable OTLP metrics push in user_config.yaml so logos-otel can collect
# native node metrics. Idempotent: only rewrites `metrics: None`. If metrics
# is already configured (e.g. operator customized it) we leave it alone.
# If the otel-collector container is absent the node tolerates the missing
# endpoint — push retries quietly in the background.
patch_user_config_for_otlp() {
    local config_path="$1"
    [[ -f "$config_path" ]] || return 0
    grep -qE '^[[:space:]]+metrics: None$' "$config_path" || return 0

    awk '
      /^[[:space:]]+metrics: None$/ {
        match($0, /^[[:space:]]+/)
        indent = substr($0, 1, RLENGTH)
        print indent "metrics: !Otlp"
        print indent "  endpoint: \"http://logos-otel:4317\""
        print indent "  host_identifier: \"logos-node\""
        next
      }
      { print }
    ' "$config_path" > "${config_path}.tmp" && mv "${config_path}.tmp" "$config_path"
    chmod 600 "$config_path"
    log_dim "Enabled OTLP metrics push to logos-otel (for monitoring stack)"
}

# Disable the tracing module's disk-based file output. The default config
# emits the SAME log lines to both stdout (which Docker captures, capped via
# our compose `logging:` block) AND to per-hour files in the data dir, which
# are NOT capped — DEBUG-level logs hit ~10GB/hour and fill any operator's
# disk in <a day. Stdout suffices; remove the file output.
#
# Replaces:
#     logger:
#       file:
#         directory: .
#         prefix: '...'
#       stdout: true
#       ...
# with:
#     logger:
#       file: null
#       stdout: true
#       ...
#
# Idempotent: only fires when the file: block has child fields.
patch_user_config_for_log_files() {
    local config_path="$1"
    [[ -f "$config_path" ]] || return 0
    # Detect the multi-line file: block. If file: is already null (or absent)
    # we don't need to patch.
    grep -qE '^[[:space:]]+file:[[:space:]]*$' "$config_path" || return 0

    awk '
      /^[[:space:]]+file:[[:space:]]*$/ {
        match($0, /^[[:space:]]+/)
        parent_indent = RLENGTH
        print substr($0, 1, parent_indent) "file: null"
        in_file_block = 1
        next
      }
      in_file_block {
        match($0, /^[[:space:]]+/)
        if (RLENGTH > parent_indent) {
          next   # skip indented children of file:
        }
        in_file_block = 0
      }
      { print }
    ' "$config_path" > "${config_path}.tmp" && mv "${config_path}.tmp" "$config_path"
    chmod 600 "$config_path"
    log_dim "Disabled disk-based tracing logs (redundant with stdout/Docker)"
}

# Remove the legacy `logos-net` network if it's orphaned (no containers attached).
# Pre-0.4.2 used `logos-net` which collided with any other Docker workload using
# that generic name. We renamed to `logosnode-net`; this cleans up the stale one
# on installs that have been migrated. Idempotent; never removes a network that
# still has containers attached.
docker_cleanup_legacy_network() {
    $DOCKER_CMD network inspect logos-net &>/dev/null || return 0
    local attached
    attached="$($DOCKER_CMD network inspect logos-net --format '{{range .Containers}}x{{end}}' 2>/dev/null)"
    [[ -n "$attached" ]] && return 0
    $DOCKER_CMD network rm logos-net &>/dev/null || true
}

# Repair a `logosnode-net` network that exists but was NOT created by compose.
#
# Both stacks declare this network with `name: logosnode-net` (see
# generate_compose_file and the monitoring compose). Compose refuses to adopt a
# same-named network that lacks its own labels, aborting with "network
# logosnode-net was found but has incorrect label" — which breaks `start`.
#
# This bites installs done before the monitoring stack switched from
# `external: true` + a manual `docker network create` to a compose-managed
# network: that manual network has no compose labels, and on those boxes the
# monitoring containers are already attached to it, so it isn't orphaned and
# can't simply be removed in place.
#
# Fix: when the network is unmanaged, bring our stacks down to detach from it,
# drop it, and let the normal bring-up recreate it with the right labels (the
# node and monitoring stacks are restarted by the regular flow right after).
# No-op when the network is already compose-managed or absent, so healthy
# installs are untouched. Idempotent; never force-disconnects foreign
# containers — if a non-compose workload holds the name, `network rm` simply
# fails and the (now surfaced) compose error tells the operator.
docker_repair_unmanaged_network() {
    $DOCKER_CMD network inspect logosnode-net &>/dev/null || return 0

    # Compose always tags networks it owns with com.docker.compose.network=<key>;
    # our key is "logosnode-net". Anything else (empty/manual) is unmanaged.
    local net_label
    net_label="$($DOCKER_CMD network inspect logosnode-net \
        --format '{{index .Labels "com.docker.compose.network"}}' 2>/dev/null)" || true
    [[ "$net_label" == "logosnode-net" ]] && return 0

    log_warn "Found a 'logosnode-net' network not managed by compose — repairing it"
    log_dim "Detaching and recreating it so compose can adopt it cleanly"

    # Detach our containers by bringing both stacks down. Data lives in named
    # volumes, so this is safe; both are (re)started by the normal flow after.
    local mon_compose="$LOGOS_NODE_DIR/docker-compose.monitoring.yml"
    if [[ -f "$mon_compose" ]]; then
        COMPOSE_IGNORE_ORPHANS=true $DOCKER_COMPOSE -f "$mon_compose" down &>/dev/null || true
    fi
    $DOCKER_COMPOSE -f "$(get_compose_path)" down &>/dev/null || true

    $DOCKER_CMD network rm logosnode-net &>/dev/null || true
}

# Start the node
docker_up() {
    local compose_path
    compose_path="$(get_compose_path)"

    docker_cleanup_legacy_network
    docker_repair_unmanaged_network
    $DOCKER_COMPOSE -f "$compose_path" up -d
}

# Stop the node
docker_down() {
    local compose_path
    compose_path="$(get_compose_path)"
    $DOCKER_COMPOSE -f "$compose_path" down
}

# Check if the node container is running
docker_is_running() {
    $DOCKER_CMD ps --filter "name=${LOGOS_CONTAINER_NAME}" --format '{{.Names}}' 2>/dev/null | grep -q "^${LOGOS_CONTAINER_NAME}$"
}

# Wait for the node to become healthy.
# Returns:
#   0  — container reached "healthy"
#   1  — timed out (container still running but not yet healthy)
#   2  — container exited/crashed
docker_health_wait() {
    local timeout="${1:-120}"
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        # Bail out early if the container is not running
        if ! docker_is_running; then
            echo -en "\r\033[K"
            return 2
        fi

        local status
        status="$($DOCKER_CMD inspect --format='{{.State.Health.Status}}' "$LOGOS_CONTAINER_NAME" 2>/dev/null)" || true

        case "$status" in
            healthy)
                echo -en "\r\033[K"
                return 0
                ;;
            unhealthy)
                echo -en "\r\033[K"
                return 1
                ;;
        esac

        echo -en "\r${CYAN}⠼${RESET} Waiting for node to start... (${elapsed}s)"
        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo -en "\r\033[K"
    return 1
}

# Tail logs
docker_logs() {
    local compose_path
    compose_path="$(get_compose_path)"
    $DOCKER_COMPOSE -f "$compose_path" logs "$@"
}
