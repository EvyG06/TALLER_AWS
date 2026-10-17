#!/usr/bin/env bash
export AWS_DEFAULT_REGION="us-east-1"
export AWS_REGION="us-east-1"
export AWS_PAGER=""
BASE="$HOME/taller-aws"
PY="$BASE/.venv/bin/python"
STATE="$BASE/state.env"
EVID="$BASE/evidencias"
mkdir -p "$EVID"
touch "$STATE"
source "$STATE"

# guarda NOMBRE=VALOR en state.env
save() {
  grep -v "^export $1=" "$STATE" > "$STATE.tmp" || true
  echo "export $1=\"$2\"" >> "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
  export "$1=$2"
}
mi_ip()        { curl -s https://checkip.amazonaws.com | tr -d '[:space:]'; }
vpc_default()  { aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text; }
subredes()     { aws ec2 describe-subnets --filters Name=vpc-id,Values="$1" Name=default-for-az,Values=true --query 'Subnets[].SubnetId' --output text; }

# crea (o reutiliza) un grupo de seguridad y le BORRA todas las reglas de entrada
sg_limpio() {   # sg_limpio NOMBRE DESCRIPCION VPC
  local id reglas
  id=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$1" Name=vpc-id,Values="$3" --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$id" = "None" ]; then
    id=$(aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$3" --query GroupId --output text)
  fi
  reglas=$(aws ec2 describe-security-groups --group-ids "$id" --query 'SecurityGroups[0].IpPermissions' --output json)
  if [ "$reglas" != "[]" ]; then
    aws ec2 revoke-security-group-ingress --group-id "$id" --ip-permissions "$reglas" >/dev/null
  fi
  echo "$id"
}

borrar_sg() {   # borrar_sg NOMBRE (reintenta mientras AWS libera las interfaces)
  local id i
  for i in 1 2 3 4 5 6; do
    id=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$1" --query 'SecurityGroups[0].GroupId' --output text)
    [ "$id" = "None" ] && return 0
    aws ec2 delete-security-group --group-id "$id" 2>/dev/null && return 0
    echo "  reintentando borrar $1 ..."; sleep 20
  done
}
