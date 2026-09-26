#!/bin/bash
# Plan against every live box's state and expect no changes. Run from the
# repo root on a host that has the state files under
# $XDG_STATE_HOME/dynamicalsystem/<box>/terraform/terraform.tfstate.
#
# Box table: name:service:environment:public:ssh_public:ubuntu:template
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/tf_env.sh
BOXES="${BOXES:-gateway:gateway:prod:true:true:22.04:setup_secure_tunnel.sh.tpl agent:agent:prod:false:false:24.04:setup_tinsnip_box.sh.tpl}"
rc=0
for row in $BOXES; do
  IFS=: read -r box service env public ssh_public ubuntu tpl <<<"$row"
  state="$XDG_STATE_HOME/$TIN_NAMESPACE/$box/terraform/terraform.tfstate"
  if [ ! -f "$state" ]; then echo "[x] $box: no state at $state"; rc=1; continue; fi
  export TF_VAR_service=$service TF_VAR_environment=$env TF_VAR_public=$public TF_VAR_ssh_public=$ssh_public
  export TF_VAR_ubuntu_version=$ubuntu TF_VAR_user_data_template="$PWD/$tpl" TF_DATA_DIR="/tmp/tfdata-plan-$box"
  ( cd terraform && terraform init -input=false -no-color -backend-config="path=$state" >/dev/null )
  set +e; ( cd terraform && terraform plan -input=false -no-color -detailed-exitcode -lock=false ) > "/tmp/plan-$box.txt" 2>&1; code=$?; set -e
  case $code in
    0) echo "[/] $box: no changes";;
    2) echo "[x] $box: changes pending"; grep -E '^\s+# .* will be|^Plan:' "/tmp/plan-$box.txt"; rc=1;;
    *) echo "[x] $box: plan failed"; tail -5 "/tmp/plan-$box.txt"; rc=1;;
  esac
done
exit $rc
