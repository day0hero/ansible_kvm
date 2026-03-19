# Disconnected OpenShift 4 on Libvirt/KVM — Step-by-Step Procedure

This document walks through a manual UPI (User Provisioned Infrastructure) installation
of OpenShift 4 in a disconnected/airgapped environment using libvirt/KVM virtual machines.

---

## Prerequisites

- RHEL 9 or Fedora hypervisor with libvirt/KVM, `virt-install`, `qemu-img`, `genisoimage`
- RHEL 9 cloud image (`rhel-9-base.qcow2`) for the bastion
- RHCOS disk image (`rhcos-disc.qcow2`) for OpenShift nodes 
- Red Hat pull secret from https://console.redhat.com/openshift/downloads
- SSH keypair (`~/.ssh/id_rsa.pub`)
- Internet access on the hypervisor (for initial content mirroring)

## Environment Used in This Guide

| Item | Value |
|------|-------|
| Cluster name | `ocp` |
| Base domain | `rhuk.local` |
| Airgap network | `192.168.127.0/24` |
| Bastion airgap IP | `192.168.127.5` |
| Bootstrap IP | `192.168.127.10` |
| Control plane IPs | `192.168.127.11`, `.12`, `.13` |
| Quay registry | `bastion.ocp.rhuk.local:8443` |

---

## Phase 1: Prepare Libvirt Networks

### 1.1 Create the airgap (isolated) network

```
cat > /tmp/airgap-net.xml <<'EOF'
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>airgap</name>
  <domain name='ocp.rhuk.local' localOnly='yes'/>
  <bridge name='virbr-ag' stp='on' delay='0'/>
  <ip address='192.168.127.1' prefix='24'>
    <dhcp>
      <range start='192.168.127.2' end='192.168.127.254'/>
    </dhcp>
  </ip>
  <dns/>
  <dnsmasq:options>
    <dnsmasq:option value='address=/.apps.ocp.rhuk.local/192.168.127.5'/>
  </dnsmasq:options>
</network>
EOF

virsh net-define /tmp/airgap-net.xml
virsh net-start airgap
virsh net-autostart airgap
```

### 1.2 Add DNS host entries to the airgap network

These entries are served by the libvirt-managed dnsmasq on `192.168.127.1`.

```
virsh net-update airgap add-last dns-host \
  '<host ip="192.168.127.5"><hostname>bastion.ocp.rhuk.local</hostname><hostname>api.ocp.rhuk.local</hostname><hostname>api-int.ocp.rhuk.local</hostname></host>' \
  --live --config

virsh net-update airgap add-last dns-host \
  '<host ip="192.168.127.10"><hostname>bootstrap.ocp.rhuk.local</hostname></host>' \
  --live --config

virsh net-update airgap add-last dns-host \
  '<host ip="192.168.127.11"><hostname>cp0.ocp.rhuk.local</hostname></host>' \
  --live --config

virsh net-update airgap add-last dns-host \
  '<host ip="192.168.127.12"><hostname>cp1.ocp.rhuk.local</hostname></host>' \
  --live --config

virsh net-update airgap add-last dns-host \
  '<host ip="192.168.127.13"><hostname>cp2.ocp.rhuk.local</hostname></host>' \
  --live --config
```

### 1.3 Configure split DNS on the hypervisor

So the hypervisor can resolve `*.ocp.rhuk.local` via the airgap dnsmasq:

```
resolvectl dns virbr-ag 192.168.127.1
resolvectl domain virbr-ag ~ocp.rhuk.local
```

Make it persistent with a NetworkManager dispatcher script:

```
cat > /etc/NetworkManager/dispatcher.d/99-dns-airgap <<'SCRIPT'
#!/bin/bash
if [ "$1" = "virbr-ag" ] && [ "$2" = "up" ]; then
    resolvectl dns virbr-ag 192.168.127.1
    resolvectl domain virbr-ag ~ocp.rhuk.local
fi
SCRIPT
chmod 755 /etc/NetworkManager/dispatcher.d/99-dns-airgap
```

### 1.4 Download the rhcos image

```
curl -L https://mirror.openshift.com/pub/openshift-v4/x86_64/dependencies/rhcos/4.21/latest/rhcos-qemu.x86_64.qcow2.gz -o /tmp/rhcos-qemu.x86_64.qcow.gz

gunzip /tmp/rhcos-qemu.x86_64.qcow.gz

cp /tmp/rhcos-qemu.x86_64.qcow /var/lib/libvirt/images/
```

### 1.5 Register the rhel-9 qcow2 image 

Activation Key and Org ID from Red Hat Portal

**Only if using RedHat qcow images**

```
virt-customize -a /var/lib/libvirt/images/rhel-9.7-x86_64.qcow2 --run-command "subscription-manager register --org 1234567 --activationkey fb844399-cb19-5e4f4d3e-a06c-c8gegfegbdgd"

---

## Phase 2: Create the Bastion VM

### 2.1 Prepare the disk

```
qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/libvirt/images/rhel-9-base.qcow2 \
  /var/lib/libvirt/images/bastion.ocp.rhuk.local.qcow2 200G
```

### 2.2 Create cloud-init ISO

Create `meta-data`, `user-data`, and `network-config` files, then build the ISO:

**meta-data:**
```
instance-id: bastion
local-hostname: bastion.ocp.rhuk.local
```

**user-data:**
```
#cloud-config
hostname: bastion.ocp.rhuk.local
fqdn: bastion.ocp.rhuk.local
manage_etc_hosts: true
ssh_authorized_keys:
  - <your-ssh-public-key>
package_update: true
packages:
  - dnsmasq
  - tree
  - tmux
  - vim
  - podman
  - bind-utils
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
```

**network-config (two NICs — bridged + airgap):**
```
version: 2
ethernets:
  net0:
    match:
      macaddress: "<br0-mac>"
    addresses:
      - 192.168.0.147/24
    gateway4: 192.168.0.1
    nameservers:
      addresses:
        - 192.168.0.1
  net1:
    match:
      macaddress: "<airgap-mac>"
    addresses:
      - 192.168.127.5/24
    nameservers:
      addresses:
        - 192.168.127.1
      search:
        - ocp.rhuk.local
        - rhuk.local
```

**Build ISO:**
```
genisoimage -output /var/lib/libvirt/images/bastion-cidata.iso \
  -volid cidata -joliet -rock meta-data user-data network-config
```

### 2.3 Create the VM

```
virt-install \
  --name bastion.ocp.rhuk.local \
  --ram 8192 --vcpus 2 \
  --os-variant rhel9-unknown \
  --disk /var/lib/libvirt/images/bastion.ocp.rhuk.local.qcow2 \
  --disk /var/lib/libvirt/images/bastion-cidata.iso,device=cdrom \
  --network bridge=br0,model=virtio \
  --network network=airgap,model=virtio \
  --import --noautoconsole
```

### 2.4 Configure split DNS on the bastion

SSH into the bastion once it's up:

```
ssh cloud-user@bastion

# Install and configure local dnsmasq for split DNS
sudo tee /etc/dnsmasq.d/ocp-split-dns.conf <<'EOF'
server=/ocp.rhuk.local/192.168.127.1
server=/rhuk.local/192.168.127.1
server=192.168.0.1
listen-address=127.0.0.1
bind-interfaces
no-resolv
EOF

sudo systemctl enable --now dnsmasq

# Point resolv.conf to local dnsmasq
echo -e "nameserver 127.0.0.1\nsearch ocp.rhuk.local rhuk.local" | sudo tee /etc/resolv.conf

# Prevent cloud-init from overwriting resolv.conf
echo "manage_resolv_conf: false" | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

# Fix /etc/hosts so bastion resolves to airgap IP, not 127.0.0.1
sudo sed -i 's/^127.0.0.1 bastion.*/192.168.127.5 bastion.ocp.rhuk.local bastion/' /etc/hosts

sudo systemctl restart dnsmasq
```

Verify:
```
dig +short api.ocp.rhuk.local        # should return 192.168.127.5
dig +short bastion.ocp.rhuk.local    # should return 192.168.127.5
dig +short www.google.com            # should return public IPs
```

---

## Phase 3: Install OCP Tools on the Bastion

### 3.1 Download binaries

```
OCP_MIRROR=https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable-4.21

sudo curl -L -o /tmp/oc.tar.gz ${OCP_MIRROR}/openshift-client-linux.tar.gz
sudo tar xzf /tmp/oc.tar.gz -C /usr/local/bin oc kubectl

sudo curl -L -o /tmp/openshift-install.tar.gz ${OCP_MIRROR}/openshift-install-linux.tar.gz
sudo tar xzf /tmp/openshift-install.tar.gz -C /usr/local/bin openshift-install

sudo curl -L -o /tmp/oc-mirror.tar.gz ${OCP_MIRROR}/oc-mirror.rhel9.tar.gz
sudo tar xzf /tmp/oc-mirror.tar.gz -C /usr/local/bin

sudo chmod 755 /usr/local/bin/{oc,kubectl,openshift-install,oc-mirror}
```

Verify:
```
oc version --client
openshift-install version
oc-mirror version
```

---

## Phase 4: Install Mirror Registry (Quay)

### 4.1 Download and install

```
sudo mkdir -p /opt/mirror-registry
cd /opt/mirror-registry

curl -L -o /tmp/mirror-registry.tar.gz \
  https://developers.redhat.com/content-gateway/file/pub/openshift-v4/clients/mirror-registry/1.3.11/mirror-registry.tar.gz

tar xzf /tmp/mirror-registry.tar.gz -C /opt/mirror-registry

# Generate a password and save it
QUAY_PASSWORD=$(openssl rand -base64 12)
echo -n "$QUAY_PASSWORD" > /root/.quay-init-password
chmod 600 /root/.quay-init-password

./mirror-registry install \
  --quayHostname bastion.ocp.rhuk.local \
  --quayRoot /opt/mirror-registry \
  --initPassword "$QUAY_PASSWORD"
```

### 4.2 Wait for Quay to be healthy

```
until curl -sk https://localhost:8443/health/instance | grep -q '"status":"OK"'; do
  echo "Waiting for Quay..."
  sleep 10
done
echo "Quay is healthy"
```

### 4.3 Trust the Quay CA certificate

```
# Find the CA cert (location varies by mirror-registry version)
find /opt/mirror-registry /root/quay-install -name 'rootCA.pem' 2>/dev/null

sudo cp <path-to-rootCA.pem> /etc/pki/ca-trust/source/anchors/quay-rootCA.pem
sudo update-ca-trust
```

### 4.4 Merge pull secrets

```
QUAY_AUTH=$(echo -n "init:${QUAY_PASSWORD}" | base64 -w0)

# Copy your Red Hat pull secret to the bastion
scp ~/.pullsecret.json bastion:/root/.pullsecret.json

# Merge Quay credentials into the pull secret
jq --arg reg "bastion.ocp.rhuk.local:8443" --arg auth "$QUAY_AUTH" \
  '.auths[$reg] = {"auth": $auth}' \
  /root/.pullsecret.json > /root/.docker/config.json
```

---

## Phase 5: Mirror OCP Content

### 5.1 Create imageset-config.yaml

```
cat > /opt/ocp-mirror/imageset-config.yaml <<'EOF'
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  platform:
    channels:
      - name: stable-4.21
        minVersion: 4.21.0
        maxVersion: 4.21.0
  operators:
    - catalog: registry.redhat.io/redhat/redhat-operator-index:v4.21
      packages:
        - name: local-storage-operator
  additionalImages:
    - name: registry.redhat.io/ubi9/ubi:latest
    - name: registry.redhat.io/ubi9/ubi-minimal:latest
EOF
```

### 5.2 Run oc-mirror

This will take a long time (30min to several hours depending on bandwidth).

```
mkdir -p /opt/ocp-mirror/working-dir

oc-mirror \
  --config /opt/ocp-mirror/imageset-config.yaml \
  docker://bastion.ocp.rhuk.local:8443 \
  --v2 \
  --workspace file:///opt/ocp-mirror/working-dir \
  --authfile /root/.docker/config.json
```

If it fails partway through (common with operator images), re-run the same command.
It is idempotent and will resume. Check for success:

```
ls /opt/ocp-mirror/working-dir/cluster-resources/idms-*.yaml
```

If IDMS files exist, the mirror is complete.

---

## Phase 6: Create install-config.yaml

### 6.1 Gather IDMS mirror entries

Extract `imageDigestSources` from the IDMS files generated by oc-mirror:

```
for f in /opt/ocp-mirror/working-dir/cluster-resources/idms-*.yaml; do
  yq '.spec.imageDigestMirrors[]' "$f"
done
```

### 6.2 Build install-config.yaml

```
export INSTALL_DIR=/root/ocp
mkdir -p ${INSTALL_DIR}

PULL_SECRET=$(cat /root/.docker/config.json)
SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
CA_CERT=$(cat /etc/pki/ca-trust/source/anchors/quay-rootCA.pem)

cat > ${INSTALL_DIR}/install-config.yaml <<EOF
apiVersion: v1
baseDomain: rhuk.local
metadata:
  name: ocp
networking:
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: 192.168.127.0/24
  serviceNetwork:
    - 172.30.0.0/16
  networkType: OVNKubernetes
compute:
  - name: worker
    replicas: 0
controlPlane:
  name: master
  replicas: 3
platform:
  none: {}
fips: false
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_KEY}'
additionalTrustBundle: |
$(echo "$CA_CERT" | sed 's/^/  /')
imageDigestSources:
  - mirrors:
      - bastion.ocp.rhuk.local:8443/openshift/release
    source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
  - mirrors:
      - bastion.ocp.rhuk.local:8443/openshift/release-images
    source: quay.io/openshift-release-dev/ocp-release
EOF
```

> **Note:** The `imageDigestSources` section must match the output from the IDMS files.
> The example above covers the core release images; add operator mirrors as needed.

### 6.3 Backup install-config.yaml

`openshift-install` consumes and deletes this file, so back it up:

```
cp ${INSTALL_DIR}/install-config.yaml ${INSTALL_DIR}-backup/install-config.yaml
```

---

## Phase 7: Generate Manifests and Ignition Configs

```
openshift-install create manifests --dir ${INSTALL_DIR}
openshift-install create ignition-configs --dir ${INSTALL_DIR}
```

This produces:
- `bootstrap.ign`
- `master.ign`
- `worker.ign`
- `auth/kubeconfig`
- `auth/kubeadmin-password`

---

## Phase 8: Set Up Load Balancer (HAProxy)

### 8.1 Create haproxy.cfg

```
cat > ${INSTALL_DIR}/haproxy.cfg <<'EOF'
global
    log stdout format raw local0
    maxconn 4096

defaults
    log     global
    timeout connect 10s
    timeout client  60s
    timeout server  60s

listen stats
    bind *:9000
    mode http
    stats enable
    stats uri /
    stats refresh 10s

frontend api
    bind *:6443
    mode tcp
    default_backend api-backends

backend api-backends
    mode tcp
    balance roundrobin
    option ssl-hello-chk
    server bootstrap 192.168.127.10:6443 check
    server cp0 192.168.127.11:6443 check
    server cp1 192.168.127.12:6443 check
    server cp2 192.168.127.13:6443 check

frontend machine-config
    bind *:22623
    mode tcp
    default_backend machine-config-backends

backend machine-config-backends
    mode tcp
    balance roundrobin
    server bootstrap 192.168.127.10:22623 check
    server cp0 192.168.127.11:22623 check
    server cp1 192.168.127.12:22623 check
    server cp2 192.168.127.13:22623 check

frontend ingress-https
    bind *:443
    mode tcp
    default_backend ingress-https-backends

backend ingress-https-backends
    mode tcp
    balance roundrobin
    server cp0 192.168.127.11:443 check
    server cp1 192.168.127.12:443 check
    server cp2 192.168.127.13:443 check

frontend ingress-http
    bind *:80
    mode tcp
    default_backend ingress-http-backends

backend ingress-http-backends
    mode tcp
    balance roundrobin
    server cp0 192.168.127.11:80 check
    server cp1 192.168.127.12:80 check
    server cp2 192.168.127.13:80 check
EOF
```

### 8.2 Build and run the HAProxy container

```
cat > ${INSTALL_DIR}/Containerfile.haproxy <<'EOF'
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
RUN microdnf install -y haproxy && microdnf clean all
CMD ["haproxy", "-f", "/etc/haproxy/haproxy.cfg", "-db"]
EOF

podman build -t ocp-haproxy -f ${INSTALL_DIR}/Containerfile.haproxy ${INSTALL_DIR}

podman run -d --name ocp-haproxy --restart always --net host \
  -v ${INSTALL_DIR}/haproxy.cfg:/etc/haproxy/haproxy.cfg:Z \
  ocp-haproxy
```

---

## Phase 9: Serve Ignition Configs via HTTP

```
mkdir -p /opt/ocp-webroot
cp ${INSTALL_DIR}/bootstrap.ign /opt/ocp-webroot/
cp ${INSTALL_DIR}/master.ign /opt/ocp-webroot/
cp ${INSTALL_DIR}/worker.ign /opt/ocp-webroot/

podman run -d --name ocp-httpd --restart always \
  -p 8080:8080 \
  -v /opt/ocp-webroot:/var/www/html:Z \
  registry.access.redhat.com/ubi9/httpd-24
```

Verify:
```
curl -s http://localhost:8080/master.ign | head -c 100
```

---

## Phase 10: Create OpenShift VMs (on the hypervisor)

For each RHCOS VM, you need a **pointer ignition file** that tells the node where to
fetch its full ignition config and configures static networking.

### 10.1 Create pointer ignition files

Example for `bootstrap` (repeat pattern for cp0, cp1, cp2 with their respective IPs,
MACs, and ignition source — `master.ign` for control plane nodes):

```
cat > /var/lib/libvirt/ignition/bootstrap.ocp.rhuk.local.ign <<'EOF'
{
  "ignition": {
    "version": "3.2.0",
    "config": {
      "merge": [
        {
          "source": "http://192.168.127.5:8080/bootstrap.ign"
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
          "source": "data:,bootstrap.ocp.rhuk.local"
        }
      },
      {
        "path": "/etc/NetworkManager/system-connections/static-airgap.nmconnection",
        "mode": 384,
        "overwrite": true,
        "contents": {
          "source": "data:text/plain;charset=utf-8;base64,<BASE64-ENCODED-NM-KEYFILE>"
        }
      }
    ]
  }
}
EOF
```

The NM keyfile (base64-encode this and insert above):
```
[connection]
id=static-airgap
type=ethernet
autoconnect=true

[ethernet]
mac-address=<VM-MAC-ADDRESS>

[ipv4]
method=manual
address1=192.168.127.10/24,192.168.127.1
dns=192.168.127.1;
dns-search=ocp.rhuk.local;

[ipv6]
method=disabled
```

> **Tip:** Get the MAC address from virt-install's output or pre-assign one.

### 10.2 Create the VMs

Each RHCOS VM is created with the pointer ignition injected via QEMU fw_cfg:

**Bootstrap:**
```
qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/libvirt/images/rhcos-disc.qcow2 \
  /var/lib/libvirt/images/bootstrap.ocp.rhuk.local.qcow2 140G

virt-install \
  --name bootstrap.ocp.rhuk.local \
  --ram 8192 --vcpus 2 \
  --os-variant rhel9-unknown \
  --disk /var/lib/libvirt/images/bootstrap.ocp.rhuk.local.qcow2 \
  --network network=airgap,model=virtio \
  --import --noautoconsole \
  --qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=/var/lib/libvirt/ignition/bootstrap.ocp.rhuk.local.ign"
```

**Control plane (repeat for cp0, cp1, cp2):**
```
qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/libvirt/images/rhcos-disc.qcow2 \
  /var/lib/libvirt/images/cp0.ocp.rhuk.local.qcow2 140G

virt-install \
  --name cp0.ocp.rhuk.local \
  --ram 12288 --vcpus 4 \
  --os-variant rhel9-unknown \
  --disk /var/lib/libvirt/images/cp0.ocp.rhuk.local.qcow2 \
  --network network=airgap,model=virtio \
  --import --noautoconsole \
  --qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=/var/lib/libvirt/ignition/cp0.ocp.rhuk.local.ign"
```

---

## Phase 11: Monitor Installation

### 11.1 Wait for bootstrap to complete

From the bastion:

```
openshift-install wait-for bootstrap-complete --dir ${INSTALL_DIR} --log-level debug
```

This typically takes 15-30 minutes. You'll see:
```
INFO It is now safe to remove the bootstrap resources
```

### 11.2 Remove bootstrap from HAProxy

Edit `haproxy.cfg` — remove the `server bootstrap ...` lines from `api-backends`
and `machine-config-backends`, then restart:

```
podman restart ocp-haproxy
```

### 11.3 Destroy the bootstrap VM (on the hypervisor)

```
virsh destroy bootstrap.ocp.rhuk.local
virsh undefine bootstrap.ocp.rhuk.local --nvram
```

### 11.4 Wait for installation to complete

```
openshift-install wait-for install-complete --dir ${INSTALL_DIR} --log-level debug
```

This takes another 15-30 minutes. On success you'll get:
```
INFO Install complete!
INFO To access the cluster as the system:admin user...
  export KUBECONFIG=/root/ocp/auth/kubeconfig
INFO Access the OpenShift web-console here:
  https://console-openshift-console.apps.ocp.rhuk.local
INFO Login to the console with user: kubeadmin, password: <password>
```

---

## Phase 12: Post-Install Verification

```
export KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig

oc get nodes
oc get clusterversion
oc get clusteroperators
oc get pods -A | grep -v Running | grep -v Completed
```

All cluster operators should eventually reach `Available=True`.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Nodes can't pull images | DNS not resolving `bastion.ocp.rhuk.local` | Check `virsh net-dumpxml airgap` for correct DNS entries |
| `dial tcp: lookup api.ocp.rhuk.local: no such host` | Bastion resolv.conf not pointing to local dnsmasq | Fix `/etc/resolv.conf` to `nameserver 127.0.0.1` |
| `connection refused` on `:8443` | Quay not running or bastion resolving to wrong IP | Verify `podman ps`, check DNS points to airgap IP |
| HAProxy won't start | Can't resolve backend hostnames | Use IPs instead of hostnames in `haproxy.cfg` |
| `oc-mirror` fails repeatedly | Transient registry errors, port 55000 in use | Run `fuser -k 55000/tcp` then retry; check for IDMS files |
| Bootstrap stuck pulling images | Missing `imageDigestSources` or wrong mirror paths | Compare IDMS output with `install-config.yaml` entries |
| `openshift-install` hangs at API wait | HAProxy not forwarding :6443 or DNS broken | Check `curl -k https://api.ocp.rhuk.local:6443/version` |

---

## Teardown

To destroy everything and start over:

```
# On hypervisor — destroy VMs
for vm in bootstrap.ocp.rhuk.local cp0.ocp.rhuk.local cp1.ocp.rhuk.local cp2.ocp.rhuk.local; do
  virsh destroy $vm 2>/dev/null
  virsh undefine $vm --nvram 2>/dev/null
  rm -f /var/lib/libvirt/images/${vm}.qcow2
  rm -f /var/lib/libvirt/ignition/${vm}.ign
done

# On bastion — clean install directory
rm -rf /root/ocp
podman rm -f ocp-httpd ocp-haproxy

# To also destroy bastion and networks:
virsh destroy bastion.ocp.rhuk.local
virsh undefine bastion.ocp.rhuk.local --nvram
virsh net-destroy airgap
virsh net-undefine airgap
```
