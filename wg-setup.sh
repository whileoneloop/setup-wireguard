#!/bin/bash
set -o errexit -o pipefail -o nounset

readonly endpoint="$ARG_ENDPOINT"
readonly endpoint_public_key="$ARG_ENDPOINT_PUBLIC_KEY"
readonly ips="$ARG_ASSIGNED_IPS"
readonly allowed_ips="$ARG_ALLOWED_IPS"
readonly private_key="$ARG_PRIVATE_KEY"
readonly preshared_key="$ARG_PRESHARED_KEY"
readonly keepalive="$ARG_KEEPALIVE"
readonly dns="$ARG_DNS"

readonly minport=51000
readonly maxport=51999

ifname="wg$( openssl rand -hex 4 )"
readonly ifname
port="$( shuf "--input-range=$minport-$maxport" --head-count=1 )"
readonly port

install_wg_tools() {
  sudo apt-get update || sudo yum update -y
  if command -v apt-get >/dev/null 2>&1; then
    # attempt workaround for Error: GDBus.Error:org.freedesktop.systemd1.TransactionIsDestructive: Transaction for packagekit.service/start is destructive (system-systemd\x2dfsck.slice has 'stop' job queued, but 'start' is included in transaction).
    sudo systemctl stop packagekit.service
    # end workaround
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends wireguard-tools
    echo "wireguard-tools installed."
  elif command -v yum >/dev/null 2>&1; then
    sudo amazon-linux-extras install -y epel
    sudo yum install -y wireguard-tools
  else
    echo "Unsupported package manager"
    exit 1
  fi
}

readonly private_key_path=/tmp/private.key
readonly preshared_key_path=/tmp/preshared.key

wg_tools_cleanup() {
    rm -f -- "$private_key_path"
    rm -f -- "$preshared_key_path"
}

via_wg_tools() {
    install_wg_tools
    trap wg_tools_cleanup EXIT

    (
        set -o errexit -o nounset -o pipefail
        umask 0077
        echo "$private_key" > "$private_key_path"
        if [ -n "$preshared_key" ]; then
            echo "$preshared_key" > "$preshared_key_path"
        fi
    )

    echo "run: ip link add dev '$ifname' type wireguard"
    sudo ip link add dev "$ifname" type wireguard

    local delim=,
    local ip
    while IFS= read -d "$delim" -r ip; do
        sudo ip addr add "$ip" dev "$ifname"
    done < <( printf -- "%s$delim\\0" "$ips" )

    echo "call wg set for port and private key"
    sudo wg set "$ifname" \
        listen-port "$port" \
        private-key "$private_key_path"

    additional_wg_args=()

    if [ -n "$preshared_key" ]; then
        additional_wg_args+=(preshared-key "${preshared_key_path}")
    fi

    if [ -n "$keepalive" ]; then
        additional_wg_args+=(persistent-keepalive "${keepalive}")
    fi

    # Add nameservers
    echo "configure name servers"
    if [[ -n ${dns} ]]; then
        resolv_file="/etc/resolv.conf"
        sudo tee ${resolv_file} <<< "$(sed '/^nameserver/d' ${resolv_file})"
        for d in ${dns//,/ }; do echo "nameserver ${d}" | sudo tee -a ${resolv_file}; done
    fi

    echo "call wg set for peer"
    sudo wg set "$ifname" \
        peer "$endpoint_public_key" \
        endpoint "$endpoint" \
        allowed-ips "$allowed_ips" \
        "${additional_wg_args[@]}"

    echo "ip link set '$ifname' up"
    sudo ip link set "$ifname" up

    # Add routes for allowed_ips
    for i in ${allowed_ips//,/ }; do sudo ip route replace "$i" dev "$ifname"; done
}

via_wg_tools
echo "after via_wg_tools"
