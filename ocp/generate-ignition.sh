#!/bin/bash
# Run this on the BASTION
# Generates ignition configs and per-node pointer files with static IPs
set -euo pipefail

INSTALL_DIR="${1:-/opt/ocp-install}"
WEBROOT="${2:-/opt/ocp-webroot}"
POINTER_DIR="${3:-/tmp/ignition}"
BASTION_IP="192.168.127.5"
HTTP_PORT="8080"
GATEWAY="192.168.127.1"
DNS_SERVER="192.168.127.1"
CLUSTER_DOMAIN="ocp.rhuk.local"
PREFIX="24"

declare -A NODES=(
    ["bootstrap"]="192.168.127.10|52:54:00:00:01:10"
    ["master-0"]="192.168.127.11|52:54:00:00:01:11"
    ["master-1"]="192.168.127.12|52:54:00:00:01:12"
    ["master-2"]="192.168.127.13|52:54:00:00:01:13"
)

echo "==> Generating ignition configs from ${INSTALL_DIR}"

if [[ ! -f "${INSTALL_DIR}/install-config.yaml" ]]; then
    echo "Error: ${INSTALL_DIR}/install-config.yaml not found"
    exit 1
fi

cp "${INSTALL_DIR}/install-config.yaml" "${INSTALL_DIR}/install-config.yaml.bak"

openshift-install create manifests --dir "${INSTALL_DIR}"
openshift-install create ignition-configs --dir "${INSTALL_DIR}"

echo "==> Copying ignition files to webroot ${WEBROOT}"
mkdir -p "${WEBROOT}"
cp "${INSTALL_DIR}/bootstrap.ign" "${WEBROOT}/"
cp "${INSTALL_DIR}/master.ign" "${WEBROOT}/"
cp "${INSTALL_DIR}/worker.ign" "${WEBROOT}/"
chmod 644 "${WEBROOT}"/*.ign

echo "==> Generating per-node pointer ignitions in ${POINTER_DIR}"
mkdir -p "${POINTER_DIR}"

for NODE in "${!NODES[@]}"; do
    IFS='|' read -r IP MAC <<< "${NODES[$NODE]}"
    FQDN="${NODE}.${CLUSTER_DOMAIN}"

    if [[ "$NODE" == bootstrap ]]; then
        IGN_SOURCE="bootstrap.ign"
    elif [[ "$NODE" == master-* ]]; then
        IGN_SOURCE="master.ign"
    else
        IGN_SOURCE="worker.ign"
    fi

    NM_KEYFILE="[connection]
id=static-airgap
type=ethernet
autoconnect=true

[ethernet]
mac-address=${MAC}

[ipv4]
method=manual
address1=${IP}/${PREFIX},${GATEWAY}
dns=${DNS_SERVER};
dns-search=${CLUSTER_DOMAIN};

[ipv6]
method=disabled"

    NM_B64=$(echo "$NM_KEYFILE" | base64 -w0)

    cat > "${POINTER_DIR}/${NODE}.ign" <<IGNEOF
{
  "ignition": {
    "version": "3.2.0",
    "config": {
      "merge": [
        {
          "source": "http://${BASTION_IP}:${HTTP_PORT}/${IGN_SOURCE}"
        }
      ]
    }
  },
  "storage": {
    "files": [
      {
        "path": "/etc/hostname",
        "mode": 420,
        "overwrite": true,
        "contents": {
          "source": "data:,${FQDN}"
        }
      },
      {
        "path": "/etc/NetworkManager/system-connections/static-airgap.nmconnection",
        "mode": 384,
        "overwrite": true,
        "contents": {
          "source": "data:text/plain;charset=utf-8;base64,${NM_B64}"
        }
      }
    ]
  }
}
IGNEOF

    echo "  Created ${POINTER_DIR}/${NODE}.ign (${FQDN} @ ${IP})"
done

echo ""
echo "==> Done. Next steps:"
echo "  1. Start the HTTP server:  podman run -d --name httpd -p 8080:8080 -v ${WEBROOT}:/var/www/html:Z registry.access.redhat.com/ubi9/httpd-24"
echo "  2. Copy pointer ignitions to hypervisor:  scp ${POINTER_DIR}/*.ign pn50:/tmp/"
echo "  3. Run deploy-masters.sh on the hypervisor"
