#!/usr/bin/env bash
# DESCRIPTION: Monitoring stack helpers (Prometheus, Grafana, exporter)

get_monitoring_compose_path() {
    echo "$LOGOS_NODE_DIR/docker-compose.monitoring.yml"
}

generate_monitoring_compose_file() {
    local compose_path
    compose_path="$(get_monitoring_compose_path)"

    # Resolve the monitoring directory in the CLI repo
    local monitoring_dir
    if [[ -n "${LOGOS_NODE_LIB:-}" ]]; then
        monitoring_dir="$(dirname "$LOGOS_NODE_LIB")/monitoring"
    elif [[ -d "$LOGOS_NODE_DIR/cli/monitoring" ]]; then
        monitoring_dir="$LOGOS_NODE_DIR/cli/monitoring"
    else
        log_error "Cannot find monitoring directory"
        return 1
    fi

    # Create data directories
    mkdir -p "$LOGOS_NODE_DIR/monitoring/prometheus-data"
    mkdir -p "$LOGOS_NODE_DIR/monitoring/grafana-data"
    mkdir -p "$LOGOS_NODE_DIR/monitoring/certs"
    # Grafana runs as UID 472 inside the container
    chmod 777 "$LOGOS_NODE_DIR/monitoring/grafana-data"

    # Generate self-signed SSL certificate if it doesn't exist
    if [[ ! -f "$LOGOS_NODE_DIR/monitoring/certs/grafana.crt" ]]; then
        log_step "Generating self-signed SSL certificate for Grafana..."
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$LOGOS_NODE_DIR/monitoring/certs/grafana.key" \
            -out "$LOGOS_NODE_DIR/monitoring/certs/grafana.crt" \
            -days 3650 \
            -subj "/CN=logos-node/O=Logos Node" \
            -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
            2>/dev/null
        # Grafana container runs as UID 472
        chmod 644 "$LOGOS_NODE_DIR/monitoring/certs/grafana.crt"
        chmod 644 "$LOGOS_NODE_DIR/monitoring/certs/grafana.key"
        log_success "SSL certificate generated (valid for 10 years)"
    fi

    local host_uid host_gid
    host_uid="$(id -u)"
    host_gid="$(id -g)"

    # Resolve auth settings (defaults for older installs that lack these in settings.env)
    : "${LOGOS_GRAFANA_AUTH:=false}"
    : "${LOGOS_GRAFANA_PASSWORD:=logos}"
    local grafana_anon_enabled="true"
    if [[ "${LOGOS_GRAFANA_AUTH}" == "true" ]]; then
        grafana_anon_enabled="false"
    fi

    log_step "Generating monitoring compose file..."

    # Under host networking the node container leaves the bridge, so the
    # exporter can no longer reach it via compose DNS (logos-node:8080) and
    # the node can no longer reach the otel collector via DNS either. Re-point
    # both via host.docker.internal / loopback. Bridge mode is unchanged.
    local node_api_url exporter_host_block otel_host_ports
    if [[ "$LOGOS_DOCKER_NETWORK_MODE" == "host" ]]; then
        node_api_url="http://host.docker.internal:${LOGOS_API_PORT}"
        exporter_host_block=$'    extra_hosts:\n      - "host.docker.internal:host-gateway"'
        # Bind 4317 to loopback only — never publish OTLP to the LAN.
        otel_host_ports=$'    ports:\n      - "127.0.0.1:4317:4317"'
    else
        node_api_url="http://${LOGOS_CONTAINER_NAME}:8080"
        exporter_host_block=""
        otel_host_ports=""
    fi

    cat > "$compose_path" << COMPOSE
services:
  logos-exporter:
    build:
      context: ${monitoring_dir}/exporter
    container_name: logos-exporter
    restart: unless-stopped
    ports:
      - "9100:9100"
    environment:
      - NODE_API_URL=${node_api_url}
      - CONTAINER_NAME=${LOGOS_CONTAINER_NAME}
      - POLL_INTERVAL=15
    pid: host
${exporter_host_block}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /proc:/host/proc:ro
      - /sys/fs/cgroup:/host/sys/fs/cgroup:ro
      - ${LOGOS_NODE_DIR}/user_config.yaml:/app/user_config.yaml:ro
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
    networks:
      - logosnode-net

  logos-otel:
    image: otel/opentelemetry-collector-contrib:latest
    container_name: logos-otel
    restart: unless-stopped
    command: ["--config=/etc/otel/otel.yaml"]
    volumes:
      - ${monitoring_dir}/otel/otel.yaml:/etc/otel/otel.yaml:ro
    expose:
      - "4317"  # OTLP gRPC (node pushes here)
      - "4318"  # OTLP HTTP
      - "8889"  # Prometheus scrape
${otel_host_ports}
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
    networks:
      - logosnode-net

  logos-prometheus:
    image: prom/prometheus:latest
    container_name: logos-prometheus
    restart: unless-stopped
    user: "${host_uid}:${host_gid}"
    volumes:
      - ${monitoring_dir}/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ${LOGOS_NODE_DIR}/monitoring/prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.retention.time=30d'
      - '--storage.tsdb.retention.size=1GB'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
    networks:
      - logosnode-net

  logos-grafana:
    image: grafana/grafana:latest
    container_name: logos-grafana
    restart: unless-stopped
    ports:
      - "${LOGOS_GRAFANA_PORT}:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=${LOGOS_GRAFANA_PASSWORD}
      - GF_AUTH_ANONYMOUS_ENABLED=${grafana_anon_enabled}
      - GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
      - GF_SERVER_PROTOCOL=https
      - GF_SERVER_CERT_FILE=/etc/grafana/certs/grafana.crt
      - GF_SERVER_CERT_KEY=/etc/grafana/certs/grafana.key
    volumes:
      - ${monitoring_dir}/grafana/provisioning/datasources:/etc/grafana/provisioning/datasources:ro
      - ${monitoring_dir}/grafana/provisioning/dashboards:/etc/grafana/provisioning/dashboards:ro
      - ${monitoring_dir}/grafana/dashboards:/var/lib/grafana/dashboards:ro
      - ${LOGOS_NODE_DIR}/monitoring/grafana-data:/var/lib/grafana
      - ${LOGOS_NODE_DIR}/monitoring/certs:/etc/grafana/certs:ro
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
    networks:
      - logosnode-net

networks:
  logosnode-net:
    name: logosnode-net
COMPOSE

    log_success "Monitoring compose file generated at $compose_path"
}

monitoring_build() {
    local compose_path
    compose_path="$(get_monitoring_compose_path)"

    log_step "Building monitoring containers..."
    COMPOSE_IGNORE_ORPHANS=true $DOCKER_COMPOSE -f "$compose_path" build 2>&1 | while IFS= read -r line; do
        echo -e "  ${DIM}${line}${RESET}"
    done

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        log_error "Monitoring build failed"
        return 1
    fi
    log_success "Monitoring containers built"
}

monitoring_up() {
    # Monitoring may come up before the node (during install, or `monitor start`
    # on a stopped node). If a stale, non-compose `logosnode-net` lingers from an
    # older install, repair it first so compose can adopt the shared network
    # cleanly instead of aborting on a label mismatch. No-op on healthy installs.
    docker_repair_unmanaged_network

    local compose_path
    compose_path="$(get_monitoring_compose_path)"
    COMPOSE_IGNORE_ORPHANS=true $DOCKER_COMPOSE -f "$compose_path" up -d
}

monitoring_down() {
    local compose_path
    compose_path="$(get_monitoring_compose_path)"
    COMPOSE_IGNORE_ORPHANS=true $DOCKER_COMPOSE -f "$compose_path" down
}

monitoring_is_running() {
    $DOCKER_CMD ps --filter "name=logos-grafana" --format '{{.Names}}' 2>/dev/null | grep -q "^logos-grafana$"
}
