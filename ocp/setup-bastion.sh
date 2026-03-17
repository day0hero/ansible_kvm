#!/bin/bash
# Run this on the BASTION
# Builds and starts the HTTP and HAProxy containers
set -euo pipefail

WEBROOT="${1:-/opt/ocp-webroot}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Ensuring webroot exists"
sudo mkdir -p "${WEBROOT}"
sudo chown "$(id -u):$(id -g)" "${WEBROOT}"

# --- HTTP Server ---
echo "==> Starting HTTP server (port 8080)"
podman rm -f ocp-httpd 2>/dev/null || true
podman run -d \
    --name ocp-httpd \
    --restart always \
    -p 8080:8080 \
    -v "${WEBROOT}:/var/www/html:Z" \
    registry.access.redhat.com/ubi9/httpd-24

# --- HAProxy ---
echo "==> Building HAProxy container"
podman build -t ocp-haproxy -f "${SCRIPT_DIR}/Containerfile.haproxy" "${SCRIPT_DIR}"

echo "==> Starting HAProxy (ports 6443, 22623, 80, 443, 9000)"
podman rm -f ocp-haproxy 2>/dev/null || true
podman run -d \
    --name ocp-haproxy \
    --restart always \
    --net host \
    -v "${SCRIPT_DIR}/haproxy.cfg:/etc/haproxy/haproxy.cfg:Z" \
    ocp-haproxy

echo ""
echo "==> Services running:"
echo "  HTTP:    http://192.168.127.5:8080"
echo "  HAProxy: stats at http://192.168.127.5:9000"
echo "  API LB:  192.168.127.5:6443"
echo "  MCS LB:  192.168.127.5:22623"
echo ""
echo "==> Verify:"
echo "  curl http://192.168.127.5:8080/"
echo "  curl http://192.168.127.5:9000/"
