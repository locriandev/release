#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - failed to acquire lease"
    exit 1
fi

export HOME=/tmp

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
declare target_hw_version
declare vsphere_datacenter
declare vsphere_datastore
source "${SHARED_DIR}/vsphere_context.sh"

cluster_name=$(<"${SHARED_DIR}"/cluster-name.txt)
installer_dir=/tmp/installer

echo "$(date -u --rfc-3339=seconds) - Copying agent files from shared dir..."

mkdir -p "${installer_dir}/auth"
pushd ${installer_dir}

cp -t "${installer_dir}" \
    "${SHARED_DIR}/.openshift_install_state.json"

cp -t "${installer_dir}/auth" \
    "${SHARED_DIR}/kubeadmin-password" \
    "${SHARED_DIR}/kubeconfig"

export KUBECONFIG="${installer_dir}/auth/kubeconfig"

vm_name="${cluster_name}"-master-0
agent_iso=$(<"${SHARED_DIR}"/agent-iso.txt)

source "${SHARED_DIR}/govc.sh"

echo "creating Vm $vm_name.."
govc vm.create \
-m=16384 \
-g=coreos64Guest \
-c=8 \
-disk=120GB \
-net="${LEASED_RESOURCE}" \
-firmware=efi \
-on=false \
-version vmx-"${target_hw_version}" \
-folder=/"${vsphere_datacenter}"/vm/ \
-iso-datastore="${vsphere_datastore}" \
-iso=agent-installer-isos/"${agent_iso}" \
"$vm_name"

govc vm.change \
-e="disk.EnableUUID=1" \
-vm="/${vsphere_datacenter}/vm/${vm_name}"

govc vm.change \
-nested-hv-enabled=true \
-vm="/${vsphere_datacenter}/vm/${vm_name}"

govc device.boot \
-secure \
-vm="/${vsphere_datacenter}/vm/${vm_name}"

mac_address=$(<"${SHARED_DIR}"/mac-address.txt)

govc vm.network.change \
-vm="/${vsphere_datacenter}/vm/${vm_name}" \
-net "${LEASED_RESOURCE}" \
-net.address "${mac_address}" ethernet-0

govc vm.power \
-on=true "/${vsphere_datacenter}/vm/${vm_name}"

## Monitor for `bootstrap-complete`
echo "$(date -u --rfc-3339=seconds) - Monitoring for bootstrap to complete"
openshift-install --dir="${installer_dir}" agent wait-for bootstrap-complete &

if ! wait $!; then
  echo "ERROR: Bootstrap failed. Aborting execution."
  # TODO: gather logs??
  exit 1
fi

## Monitor for cluster completion
echo "$(date -u --rfc-3339=seconds) - Monitoring for cluster completion..."

# When using line-buffering there is a potential issue that the buffer is not filled (or no new line) and this waits forever
# or in our case until the four hour CI timer is up.
openshift-install --dir="${installer_dir}" agent wait-for install-complete 2>&1 | stdbuf -o0 grep -v password &

if ! wait "$!"; then
  echo "ERROR: Installation failed. Aborting execution."
  # TODO: gather logs??
  exit 1
fi

