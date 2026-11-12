#!/bin/bash
set -o errexit -o pipefail -o nounset

readonly endpoint="$ARG_ENDPOINT"
readonly endpoint_public_key="$ARG_ENDPOINT_PUBLIC_KEY"
readonly ips="$ARG_ASSIGNED_IPS"
readonly allowed_ips="$ARG_ALLOWED_IPS"
readonly private_key="$ARG_PRIVATE_KEY"
readonly preshared_key="${ARG_PRESHARED_KEY:-}"
readonly keepalive="${ARG_KEEPALIVE:-}"
readonly dns="${ARG_DNS:-}"

readonly minport=51000
readonly maxport=51999

ifname="wg$( openssl rand -hex 4 )"
readonly ifname
port="$( shuf "--input-range=$minport-$maxport" --head-count=1 )"
readonly port

APT_OPTS=(
  -o Acquire::ForceIPv4=true
  -o Acquire::http::Timeout=15
  -o Acquire::https::Timeout=15
  -o Acquire::Retries=2
)
readonly APT_UPDATE_TIMEOUT_SECS=120
readonly APT_UPDATE_ATTEMPTS=2

apt_update_with_timeout() {
  echo "Refreshing apt indexes (timeout ${APT_UPDATE_TIMEOUT_SECS}s)..."
  timeout "$APT_UPDATE_TIMEOUT_SECS" sudo apt-get "${APT_OPTS[@]}" update
}

install_wg_tools() {
  if command -v wg >/dev/null 2>&1; then
    echo "wireguard-tools already installed; skipping package install."
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    # Workaround: GDBus.Error:org.freedesktop.systemd1.TransactionIsDestructive
    # when packagekit.service is started during apt on GitHub-hosted runners.
    sudo systemctl stop packagekit.service 2>/dev/null || true

    # GitHub runner images already ship reasonably fresh apt lists. A full
    # `apt-get update` often hangs for minutes on slow/IPv6 Ubuntu mirrors
    # (azure.archive.ubuntu.com), so try installing from the baked lists first.
    echo "Installing wireguard-tools from the runner image's apt lists (no apt-get update)..."
    if sudo DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install -yq --no-install-recommends wireguard-tools; then
      echo "wireguard-tools installed."
      return 0
    fi

    echo "Install without apt-get update failed; refreshing indexes and retrying."
    local attempt
    for attempt in $(seq 1 "$APT_UPDATE_ATTEMPTS"); do
      echo "apt-get update attempt ${attempt}/${APT_UPDATE_ATTEMPTS}"
      if apt_update_with_timeout; then
        sudo DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install -yq --no-install-recommends wireguard-tools
        echo "wireguard-tools installed."
        return 0
      fi
      echo "apt-get update timed out or failed (attempt ${attempt}/${APT_UPDATE_ATTEMPTS})."
    done

    echo "Failed to install wireguard-tools after ${APT_UPDATE_ATTEMPTS} timed apt-get update attempts."
    exit 1
  elif command -v yum >/dev/null 2>&1; then
    sudo amazon-linux-extras install -y epel
    sudo yum install -y wireguard-tools
    echo "wireguard-tools installed."
  else
    echo "Unsupported package manager"
    exit 1
  fi
}

readonly key_dir=/etc/wireguard
readonly private_key_path=$key_dir/setup-wireguard-private.key
readonly preshared_key_path=$key_dir/setup-wireguard-preshared.key

wg_tools_cleanup() {
    sudo rm -f -- "$private_key_path"
    sudo rm -f -- "$preshared_key_path"
}

# On Ubuntu 26.04 AppArmor confines wg: it may not read another user's files even under sudo, and
# reads keys from /etc/wireguard. So root owns the key files, there.
write_root_key_file() {
    sudo install -d -m 700 -o root -g root "$key_dir"
    sudo install -m 600 -o root -g root /dev/null "$2"
    printf '%s\n' "$1" | sudo tee "$2" > /dev/null
}

via_wg_tools() {
    install_wg_tools
    trap wg_tools_cleanup EXIT

    (
        set -o errexit -o nounset -o pipefail
        write_root_key_file "$private_key" "$private_key_path"
        if [ -n "$preshared_key" ]; then
            write_root_key_file "$preshared_key" "$preshared_key_path"
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
