# ansible-libvirt

Ansible role to provision KVM virtual machines with multi-network support, automatic disk resize, cloud-init guest customization, and DNS via NetworkManager dnsmasq.

## Prerequisites

Host packages:

```
qemu-img virt-install genisoimage libvirt
```

Ansible collections:

```bash
ansible-galaxy collection install -r requirements.yml
```

Your user must have permission to manage libvirt (e.g. member of the `libvirt` group, polkit rules, or socket activation).

Base images must be placed manually in the image cache directory (default `/var/lib/libvirt/images/.cache/`).

## Quick Start

```bash
cp group_vars/all/vars.yml.example group_vars/all/vars.yml
# edit vars.yml with your values
ansible-galaxy collection install -r requirements.yml
ansible-playbook provision.yml
```

## Variables

| Variable | Default | Description |
|---|---|---|
| `cluster_name` | `""` | Optional cluster prefix (e.g. `ocp`). Becomes part of the FQDN. |
| `dns_domain` | `example.local` | DNS domain for all VMs |
| `ssh_public_key` | `~/.ssh/id_rsa.pub` | SSH public key injected into every VM |
| `base_image` | (required) | Filename of the qcow2 image in `image_cache_dir` (e.g. `rhel-9.7-base.qcow2`) |
| `os_variant` | `centos-stream9` | `virt-install --os-variant` value |
| `storage_pool_path` | `/var/lib/libvirt/images` | Where VM disks are stored |
| `manage_dns` | `true` | Whether to configure NetworkManager dnsmasq |
| `apps_wildcard_ip` | `""` | IP for `*.apps.[cluster.]domain` wildcard DNS |
| `vms` | `[]` | List of VM definitions (see below) |

Both `base_image` and `os_variant` can be overridden per-VM (see example below).

### VM Definition

```yaml
vms:
  - name: bastion
    vcpus: 2
    memory: 4096        # MiB
    disk_size: 200       # GiB -- the cloud image disk is resized to this
    extra_disks:         # optional additional disks
      - name: data       # creates <fqdn>-data.qcow2
        size: 50         # GiB
    networks:
      - type: bridge     # host bridge -- DHCP from your router
        source: br0
      - type: network    # libvirt NAT network
        source: default
      - type: network    # libvirt isolated/airgap network
        source: airgap
        ip: 192.168.127.5
        prefix: 24

  - name: master-0
    base_image: rhcos-disc.qcow2          # per-VM override
    os_variant: fedora-coreos-stable       # per-VM override
    vcpus: 4
    memory: 16384
    disk_size: 120
    networks:
      - type: bridge
        source: br0
      - type: network
        source: default
      - type: network
        source: airgap
        ip: 192.168.127.10
        prefix: 24
```

Each VM gets the FQDN `<name>[.<cluster_name>].<dns_domain>`:

- `cluster_name: ""` -> `bastion.rhuk.local`
- `cluster_name: ocp` -> `bastion.ocp.rhuk.local`

NICs with a static `ip` get a cloud-init static config; NICs without `ip` use DHCP.
Guest NICs are renamed to `net0`, `net1`, `net2`, etc. via cloud-init `set-name` for consistent naming regardless of the underlying driver.

## Hostnames and DNS

The role configures NetworkManager to use its built-in dnsmasq instance, then drops config files into `/etc/NetworkManager/dnsmasq.d/`:

- **Host entries** -- each VM with a static IP gets an `address=/fqdn/ip` record so you can `ssh bastion.ocp.rhuk.local` from the hypervisor.
- **Wildcard** -- when `apps_wildcard_ip` is set, `*.apps.[cluster.]domain` resolves to that IP (useful for OpenShift / ingress).

## Networks

| Name | Mode | Purpose |
|---|---|---|
| bridge (`br0`) | Host bridge | Reachable from LAN |
| `default` | NAT | Internet access for guests |
| `airgap` | Isolated | Private / air-gapped traffic |

The bridge is assumed to already exist on the host. The NAT and airgap networks are created by the role if they don't exist.

## Teardown

Destroy VMs, disks, ISOs, and DNS config:

```bash
ansible-playbook teardown.yml
```

Destroy libvirt networks (NAT and airgap):

```bash
ansible-playbook teardown-networks.yml
```
