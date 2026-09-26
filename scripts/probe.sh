#!/bin/bash
# End-to-end check of the deployer and the tinsnip cloud-init: deploy a
# throwaway private box, prove a repeat run plans no changes, verify the
# box over SSH, destroy it, and confirm the tenancy is back to baseline.
# Costs a few pence and about ten minutes. Run from the repo root.
#   scripts/probe.sh [--keep]
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/tf_env.sh
KEEP=${1:-}
export TIN_SERVICE_NAME=probe TIN_SERVICE_ENVIRONMENT=test
export TF_VAR_public=false TF_VAR_ssh_public=true TF_VAR_ubuntu_version=24.04
export TF_VAR_user_data_template="$PWD/setup_tinsnip_box.sh.tpl" GATEWAY_RETRY_DEADLINE_HOURS=1
STATE="$XDG_STATE_HOME/$TIN_NAMESPACE/probe/terraform/terraform.tfstate"
fail=0
destroyed=0
check() { if eval "$2"; then echo "[/] $1"; else echo "[x] $1"; fail=1; fi; }

destroy_probe() {
  [ "$destroyed" = 1 ] && return 0
  [ "$KEEP" = "--keep" ] && { echo "keeping probe; destroy later with: TIN_SERVICE_NAME=probe scripts/probe.sh"; return 0; }
  [ -f "$STATE" ] || return 0
  echo "=== destroy ==="
  export TF_VAR_service=probe TF_VAR_environment=test TF_DATA_DIR=/tmp/tfdata-probe
  ( cd terraform && terraform init -input=false -no-color -backend-config="path=$STATE" >/dev/null \
      && terraform destroy -auto-approve -input=false -no-color -lock=false ) > /tmp/probe-destroy.txt 2>&1 \
    || { echo "[x] destroy failed; probe state kept at $STATE"; tail -10 /tmp/probe-destroy.txt; return 1; }
  grep -E '^Destroy complete' /tmp/probe-destroy.txt || tail -3 /tmp/probe-destroy.txt
  rm -rf "$XDG_STATE_HOME/$TIN_NAMESPACE/probe"
  destroyed=1
}
# Whatever happens after deploy, do not leave a probe box behind
trap 'destroy_probe' EXIT

baseline=$(uv run --no-cache python scripts/oci_inventory.py | grep -c '^RUNNING' || true)
echo "baseline running instances: $baseline"

echo "=== deploy ==="
rm -rf /tmp/terraform-work
uv run --no-cache python terraform_deploy.py > /tmp/probe-deploy.log 2>&1 || { echo "[x] deploy failed"; tail -20 /tmp/probe-deploy.log; exit 1; }
IP=$(grep -oE 'instance_public_ip: [0-9.]+' /tmp/probe-deploy.log | awk '{print $2}')
echo "probe at $IP"

echo "=== repeat run plans no changes (container-restart test) ==="
export TF_VAR_service=probe TF_VAR_environment=test TF_DATA_DIR=/tmp/tfdata-probe
( cd terraform && terraform init -input=false -no-color -backend-config="path=$STATE" >/dev/null )
set +e; ( cd terraform && terraform plan -input=false -no-color -detailed-exitcode -lock=false ) > /tmp/probe-replan.txt 2>&1; code=$?; set -e
check "repeat plan is clean" "[ $code -eq 0 ]"

echo "=== wait for first boot and self-reboot ==="
SSH="ssh -i ${OCI_PUBLIC_SSH_KEY%.pub} -o ConnectTimeout=6 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR ubuntu@$IP"
ok=0
for n in $(seq 1 40); do
  out=$($SSH 'test -f /var/log/tinsnip-first-boot.done && [ "$(systemctl is-enabled netfilter-persistent 2>/dev/null | tail -1)" = disabled ] && journalctl --list-boots --no-pager 2>/dev/null | wc -l' 2>/dev/null || true)
  if [ "${out:-0}" -ge 2 ] 2>/dev/null; then ok=1; break; fi
  sleep 10
done
check "first boot completed and box self-rebooted (boots seen: ${out:-0})" "[ $ok -eq 1 ]"

echo "=== verify box ==="
report=$($SSH 'echo "foreign=$(sudo iptables -S INPUT | awk "/ufw-before-input/{exit} /-A INPUT/ && !/ufw-/{c++} END{print c+0}")";
echo "nfp=$(systemctl is-enabled netfilter-persistent 2>&1 | tail -1)"; echo "rules=$(ls /etc/iptables/ 2>/dev/null | wc -l)";
echo "isvc=$(sudo iptables -S ufw-before-output | grep -c InstanceServices)"; echo "wg=$(command -v wg >/dev/null && echo yes)";
echo "ufw80=$(sudo ufw status | grep -c "^80/tcp")"; echo "ufw51820=$(sudo ufw status | grep -c "^51820/udp ")"; echo "ufwssh=$(sudo ufw status | grep -c "^OpenSSH ")";
echo "host=$(hostname -s)"; echo "podman=$(podman --version | awk "{print \$3}")"; echo "linger=$(loginctl show-user ubuntu -p Linger | cut -d= -f2)";
echo "github=$(curl -sI -m 8 -o /dev/null -w "%{http_code}" https://api.github.com)"' 2>/dev/null || true)
get() { echo "$report" | awk -F= -v k="$1" '$1==k{print $2}'; }
check "no foreign rules ahead of ufw" "[ \"$(get foreign)\" = 0 ]"
check "netfilter-persistent disabled and rules files gone" "[ \"$(get nfp)\" = disabled ] && [ \"$(get rules)\" = 0 ]"
check "InstanceServices chain in ufw output path" "[ \"$(get isvc)\" = 1 ]"
check "wireguard installed" "[ \"$(get wg)\" = yes ]"
check "ufw allows SSH and 51820 but not 80" "[ \"$(get ufwssh)\" = 1 ] && [ \"$(get ufw51820)\" = 1 ] && [ \"$(get ufw80)\" = 0 ]"
check "hostname is probe" "[ \"$(get host)\" = probe ]"
check "podman and linger" "[ -n \"$(get podman)\" ] && [ \"$(get linger)\" = yes ]"
check "outbound to GitHub" "[ \"$(get github)\" = 200 ]"
check "public 443 closed" "! nc -z -w 4 $IP 443 2>/dev/null"
check "boot volume tagged free tier" "uv run --no-cache python scripts/oci_inventory.py | grep 'probe-test (Boot Volume)' | grep -q 'free-tier=yes'"

destroy_probe || fail=1
if [ "$destroyed" = 1 ]; then
  sleep 20
  after=$(uv run --no-cache python scripts/oci_inventory.py | tee /tmp/probe-inventory.txt | grep -c '^RUNNING' || true)
  check "inventory back to baseline ($baseline running)" "[ \"$after\" = \"$baseline\" ] && grep -q '^\[/\]' /tmp/probe-inventory.txt"
fi

echo "=== destroy ==="
( cd terraform && terraform destroy -auto-approve -input=false -no-color -lock=false ) > /tmp/probe-destroy.txt 2>&1 || { echo "[x] destroy failed"; tail -10 /tmp/probe-destroy.txt; exit 1; }
grep -E '^Destroy complete' /tmp/probe-destroy.txt || tail -3 /tmp/probe-destroy.txt
rm -rf "$XDG_STATE_HOME/$TIN_NAMESPACE/probe"
sleep 20
after=$(uv run --no-cache python scripts/oci_inventory.py | tee /tmp/probe-inventory.txt | grep -c '^RUNNING' || true)
check "inventory back to baseline ($baseline running)" "[ \"$after\" = \"$baseline\" ] && grep -q '^\[/\]' /tmp/probe-inventory.txt"
exit $fail
