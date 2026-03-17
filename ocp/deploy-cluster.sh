#!/bin/bash
# Run this on the HYPERVISOR (pn50)
# Creates disks, DNS entries, DHCP reservations, and provisions VMs
set -euo pipefail

RHCOS_IMAGE="/var/lib/libvirt/images/rhcos-disc.qcow2"
DISK_DIR="/var/lib/libvirt/images"
IGN_DIR="/var/lib/libvirt/ignition"
AIRGAP_NET="airgap"
CLUSTER_DOMAIN="ocp.rhuk.local"
BASTION_IP="192.168.127.5"
CONNECT="--connect qemu:///system"

declare -A NODES=(
    ["bootstrap"]="192.168.127.10|52:54:00:00:01:10|16384|4|120"
    ["master-0"]="192.168.127.11|52:54:00:00:01:11|16384|4|120"
    ["master-1"]="192.168.127.12|52:54:00:00:01:12|16384|4|120"
    ["master-2"]="192.168.127.13|52:54:00:00:01:13|16384|4|120"
)

add_dns() {
    local fqdn=$1 ip=$2
    virsh net-update "${AIRGAP_NET}" add-last dns-host \
        "<host ip='${ip}'><hostname>${fqdn}</hostname></host>" \
        --live --config 2>/dev/null || true
}

add_dhcp() {
    local fqdn=$1 mac=$2 ip=$3
    virsh net-update "${AIRGAP_NET}" add-last ip-dhcp-host \
        "<host mac='${mac}' name='${fqdn}' ip='${ip}'/>" \
        --live --config 2>/dev/null || true
}

echo "==> Adding API DNS entries"
add_dns "api.${CLUSTER_DOMAIN}" "${BASTION_IP}"
add_dns "api-int.${CLUSTER_DOMAIN}" "${BASTION_IP}"

for NODE in bootstrap master-0 master-1 master-2; do
    IFS='|' read -r IP MAC MEM VCPU DISK <<< "${NODES[$NODE]}"
    FQDN="${NODE}.${CLUSTER_DOMAIN}"
    DISK_PATH="${DISK_DIR}/${FQDN}.qcow2"
    IGN_FILE="${IGN_DIR}/${NODE}.ign"

    echo "==> Setting up ${FQDN} (${IP})"

    # DNS + DHCP reservation
    add_dns "${FQDN}" "${IP}"
    add_dhcp "${FQDN}" "${MAC}" "${IP}"

    # Skip if VM already exists
    if virsh dominfo "${FQDN}" &>/dev/null; then
        echo "  VM already exists, skipping"
        continue
    fi

    if [[ ! -f "${IGN_FILE}" ]]; then
        echo "  Error: ${IGN_FILE} not found"
        exit 1
    fi

    # Create COW overlay disk
    if [[ ! -f "${DISK_PATH}" ]]; then
        echo "  Creating ${DISK}G disk"
        qemu-img create -f qcow2 -F qcow2 \
            -b "${RHCOS_IMAGE}" \
            "${DISK_PATH}" "${DISK}G"
    fi

    echo "  Starting VM"
    virt-install ${CONNECT} \
        --name "${FQDN}" \
        --memory "${MEM}" \
        --vcpus "${VCPU}" \
        --disk "path=${DISK_PATH},format=qcow2,bus=virtio" \
        --network "network=${AIRGAP_NET},model=virtio,mac=${MAC}" \
        --os-variant rhel9-unknown \
        --virt-type kvm \
        --graphics none \
        --console pty,target_type=serial \
        --import \
        --noautoconsole \
        --qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=${IGN_FILE}"
done

echo ""
echo "==> All VMs started. Monitor with:"
echo "  virsh console bootstrap.${CLUSTER_DOMAIN}"
echo "  openshift-install wait-for bootstrap-complete --dir /opt/ocp-install --log-level debug"
echo ""
echo "==> After bootstrap completes:"
echo "  1. Remove bootstrap from haproxy.cfg (comment out the bootstrap server lines)"
echo "  2. Restart haproxy container"
echo "  3. virsh destroy bootstrap.${CLUSTER_DOMAIN} && virsh undefine bootstrap.${CLUSTER_DOMAIN}"
echo "  4. openshift-install wait-for install-complete --dir /opt/ocp-install --log-level debug"
