#!/usr/bin/env bash
set -eo pipefail
source "$HOME/taller-aws/scripts/lib.sh"

red() {
  VPC=$(vpc_default); save VPC_ID "$VPC"
  IP=$(mi_ip); echo "Tu IP pública actual: $IP"
  SG_NEPTUNE=$(sg_limpio neptune-sg "Neptune 8182 desde mi IP" "$VPC")
  aws ec2 authorize-security-group-ingress --group-id "$SG_NEPTUNE" --protocol tcp --port 8182 --cidr "$IP/32" >/dev/null
  save SG_NEPTUNE "$SG_NEPTUNE"
  aws neptune create-db-subnet-group --db-subnet-group-name taller-neptune-subnets \
     --db-subnet-group-description "Subredes taller Neptune" --subnet-ids $(subredes "$VPC") >/dev/null 2>&1 \
     || echo "(el grupo de subredes ya existía)"
  echo "GRUPO | PUERTO | CIDR"
  aws ec2 describe-security-groups --group-ids "$SG_NEPTUNE" --query 'SecurityGroups[0].[GroupName,IpPermissions[0].FromPort,IpPermissions[0].IpRanges[0].CidrIp]' --output text
}

ver() {
  aws neptune describe-db-clusters --db-cluster-identifier neptune-taller --query 'DBClusters[0].{Cluster:DBClusterIdentifier,Estado:Status,Motor:EngineVersion,AutenticacionIAM:IAMDatabaseAuthenticationEnabled,Endpoint:Endpoint,Puerto:Port}' --output json
  aws neptune describe-db-instances --db-instance-identifier neptune-taller-1 --query 'DBInstances[0].{Instancia:DBInstanceIdentifier,Clase:DBInstanceClass,Estado:DBInstanceStatus,AccesoPublico:PubliclyAccessible}' --output json
}

crear() {
  VER=$(aws neptune describe-db-engine-versions --engine neptune --query 'DBEngineVersions[].EngineVersion' --output text | tr '\t' '\n' | sort -V | tail -1)
  echo "Versión del motor: $VER (el endpoint público exige 1.4.6.0 o superior)"
  aws neptune create-db-cluster --db-cluster-identifier neptune-taller --engine neptune --engine-version "$VER" \
     --db-subnet-group-name taller-neptune-subnets --vpc-security-group-ids "$SG_NEPTUNE" \
     --enable-iam-database-authentication --backup-retention-period 1 --no-deletion-protection --storage-encrypted >/dev/null
  aws neptune create-db-instance --db-instance-identifier neptune-taller-1 --db-instance-class db.t4g.medium \
     --engine neptune --db-cluster-identifier neptune-taller --publicly-accessible >/dev/null
  echo "Creando Neptune (≈10-15 min). Deja esta ventana abierta..."
  aws neptune wait db-instance-available --db-instance-identifier neptune-taller-1
  save NEPTUNE_ENDPOINT "$(aws neptune describe-db-clusters --db-cluster-identifier neptune-taller --query 'DBClusters[0].Endpoint' --output text)"
  ver
}

probar() {
  aws neptunedata get-engine-status --endpoint-url "https://$NEPTUNE_ENDPOINT:8182"
}

estado() {
  echo "== Clústeres Neptune ==";  aws neptune describe-db-clusters --filters Name=engine,Values=neptune --query 'DBClusters[].DBClusterIdentifier' --output text
  echo "== Instancias Neptune =="; aws neptune describe-db-instances --filters Name=engine,Values=neptune --query 'DBInstances[].DBInstanceIdentifier' --output text
  echo "== Grupos de seguridad =="; aws ec2 describe-security-groups --filters Name=group-name,Values=neptune-sg --query 'SecurityGroups[].GroupName' --output text
  echo "== Snapshots Neptune ==";  aws neptune describe-db-cluster-snapshots --query 'DBClusterSnapshots[].DBClusterSnapshotIdentifier' --output text
}

borrar() {
  echo ">> Borrando Neptune..."
  aws neptune delete-db-instance --db-instance-identifier neptune-taller-1 --skip-final-snapshot >/dev/null 2>&1 || true
  aws neptune wait db-instance-deleted --db-instance-identifier neptune-taller-1 2>/dev/null || true
  aws neptune delete-db-cluster --db-cluster-identifier neptune-taller --skip-final-snapshot >/dev/null 2>&1 || true
  while aws neptune describe-db-clusters --db-cluster-identifier neptune-taller >/dev/null 2>&1; do
    echo "  esperando a que desaparezca el clúster..."; sleep 20
  done
  borrar_sg neptune-sg
  aws neptune delete-db-subnet-group --db-subnet-group-name taller-neptune-subnets 2>/dev/null || true
  echo ">> Verificación final:"
  estado
}

accion="${1:-}"; shift || true
case "$accion" in
  red|crear|ver|probar|estado|borrar) "$accion" "$@" 2>&1 | tee "$EVID/p4_${accion}.txt" ;;
  *) echo "Uso: p4 {red|crear|ver|probar|estado|borrar}"; exit 1 ;;
esac
