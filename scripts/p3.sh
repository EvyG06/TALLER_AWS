#!/usr/bin/env bash
set -eo pipefail
source "$HOME/taller-aws/scripts/lib.sh"

ver_red() {
  echo "GRUPO | PUERTO | CIDR | DESDE-SG"
  for sg in "$SG_EC2" "$SG_DOCDB"; do
    aws ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].[GroupName,IpPermissions[0].FromPort,IpPermissions[0].IpRanges[0].CidrIp,IpPermissions[0].UserIdGroupPairs[0].GroupId]' --output text
  done
}

red() {
  VPC=$(vpc_default); save VPC_ID "$VPC"
  IP=$(mi_ip); echo "Tu IP pública actual: $IP"
  SG_EC2=$(sg_limpio ec2-bastion-sg "SSH al bastion" "$VPC")
  aws ec2 authorize-security-group-ingress --group-id "$SG_EC2" --protocol tcp --port 22 --cidr "$IP/32" >/dev/null
  SG_DOCDB=$(sg_limpio docdb-sg "DocumentDB solo desde el bastion" "$VPC")
  aws ec2 authorize-security-group-ingress --group-id "$SG_DOCDB" --protocol tcp --port 27017 --source-group "$SG_EC2" >/dev/null
  save SG_EC2 "$SG_EC2"; save SG_DOCDB "$SG_DOCDB"
  aws docdb create-db-subnet-group --db-subnet-group-name taller-docdb-subnets \
     --db-subnet-group-description "Subredes taller DocumentDB" --subnet-ids $(subredes "$VPC") >/dev/null 2>&1 \
     || echo "(el grupo de subredes ya existía)"
  if aws ec2 describe-key-pairs --key-names docdb-key >/dev/null 2>&1 && [ -f "$HOME/.ssh/docdb-key.pem" ]; then
    echo "Llave docdb-key ya existe: se reutiliza"
  else
    aws ec2 delete-key-pair --key-name docdb-key >/dev/null 2>&1 || true
    mkdir -p ~/.ssh; rm -f ~/.ssh/docdb-key.pem
    aws ec2 create-key-pair --key-name docdb-key --query KeyMaterial --output text > ~/.ssh/docdb-key.pem
    chmod 400 ~/.ssh/docdb-key.pem
  fi
  ls -l ~/.ssh/docdb-key.pem
  ver_red
}

db() {
  MODO="${1:-serverless}"
  VER=$(aws docdb describe-db-engine-versions --engine docdb --query 'DBEngineVersions[].EngineVersion' --output text | tr '\t' '\n' | grep '^5\.0' | sort -V | tail -1)
  VER="${VER:-5.0.0}"
  EXTRA=(); CLASE="db.t4g.medium"
  if [ "$MODO" = "serverless" ]; then
    EXTRA=(--serverless-v2-scaling-configuration MinCapacity=0.5,MaxCapacity=2); CLASE="db.serverless"
  fi
  echo "Modo: $MODO | clase: $CLASE | motor: $VER"
  aws docdb create-db-cluster --db-cluster-identifier docdb-taller --engine docdb --engine-version "$VER" \
     --master-username docdbadmin --manage-master-user-password \
     --db-subnet-group-name taller-docdb-subnets --vpc-security-group-ids "$SG_DOCDB" \
     --backup-retention-period 1 --no-deletion-protection "${EXTRA[@]}" >/dev/null
  aws docdb create-db-instance --db-instance-identifier docdb-taller-1 --db-instance-class "$CLASE" \
     --engine docdb --db-cluster-identifier docdb-taller >/dev/null
  echo "Creando DocumentDB (≈10 min). Deja esta ventana abierta..."
  aws docdb wait db-instance-available --db-instance-identifier docdb-taller-1
  save DOCDB_ENDPOINT "$(aws docdb describe-db-clusters --db-cluster-identifier docdb-taller --query 'DBClusters[0].Endpoint' --output text)"
  save DOCDB_SECRET_ARN "$(aws docdb describe-db-clusters --db-cluster-identifier docdb-taller --query 'DBClusters[0].MasterUserSecret.SecretArn' --output text)"
  ver_db
}

ver_db() {
  aws docdb describe-db-clusters --db-cluster-identifier docdb-taller --query 'DBClusters[0].{Cluster:DBClusterIdentifier,Estado:Status,Motor:EngineVersion,Endpoint:Endpoint,SecretoAdministrado:MasterUserSecret.SecretArn,EstadoSecreto:MasterUserSecret.SecretStatus,Serverless:ServerlessV2ScalingConfiguration}' --output json
  aws docdb describe-db-instances --db-instance-identifier docdb-taller-1 --query 'DBInstances[0].{Instancia:DBInstanceIdentifier,Clase:DBInstanceClass,Estado:DBInstanceStatus}' --output json
}

bastion() {
  AMI=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
  [ "$AMI" = "None" ] && { echo "No encontré la AMI de Amazon Linux 2023. Avísame."; exit 1; }
  SUBNET=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" Name=availability-zone,Values=us-east-1a Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)
  echo "AMI: $AMI | Subred: $SUBNET"
  ID=$(aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro --key-name docdb-key \
        --security-group-ids "$SG_EC2" --subnet-id "$SUBNET" --associate-public-ip-address \
        --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=docdb-bastion}]' \
        --query 'Instances[0].InstanceId' --output text)
  save EC2_ID "$ID"
  echo "Esperando a que la EC2 arranque..."
  aws ec2 wait instance-running --instance-ids "$ID"
  aws ec2 wait instance-status-ok --instance-ids "$ID"
  save EC2_IP "$(aws ec2 describe-instances --instance-ids "$ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
  echo "EC2 lista: $EC2_ID | IP pública: $EC2_IP"
}

ssh_test() {
  ssh -i ~/.ssh/docdb-key.pem -o StrictHostKeyChecking=accept-new ec2-user@"$EC2_IP" 'echo "SSH OK desde:" $(hostname)'
}

certificado() {
  mkdir -p ~/certs /mnt/c/certs
  curl -s -o ~/certs/global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
  cp ~/certs/global-bundle.pem /mnt/c/certs/
  ls -l ~/certs/global-bundle.pem /mnt/c/certs/global-bundle.pem
}

tunel() {
  echo "Túnel abierto: localhost:27017 -> $DOCDB_ENDPOINT:27017   (Ctrl+C para cerrarlo)"
  ssh -i ~/.ssh/docdb-key.pem -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 \
      -N -L 27017:"$DOCDB_ENDPOINT":27017 ec2-user@"$EC2_IP"
}

password() {
  aws secretsmanager get-secret-value --secret-id "$DOCDB_SECRET_ARN" --query SecretString --output text \
    | python3 -c "import sys,json; sys.stdout.write(json.load(sys.stdin)['password'])" | clip.exe
  echo "Contraseña copiada al portapapeles de Windows (pégala en Compass con Ctrl+V). Usuario: docdbadmin"
}

estado() {
  echo "== Clústeres DocumentDB ==";  aws docdb describe-db-clusters --filters Name=engine,Values=docdb --query 'DBClusters[].DBClusterIdentifier' --output text
  echo "== Instancias DocumentDB =="; aws docdb describe-db-instances --filters Name=engine,Values=docdb --query 'DBInstances[].DBInstanceIdentifier' --output text
  echo "== EC2 activas ==";           aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text
  echo "== Grupos de seguridad del taller =="; aws ec2 describe-security-groups --filters Name=group-name,Values=ec2-bastion-sg,docdb-sg --query 'SecurityGroups[].GroupName' --output text
  echo "== Secretos ==";              aws secretsmanager list-secrets --query 'SecretList[].Name' --output text
  echo "== Volúmenes EBS ==";         aws ec2 describe-volumes --query 'Volumes[].VolumeId' --output text
  echo "== Snapshots DocumentDB =="; aws docdb describe-db-cluster-snapshots --query 'DBClusterSnapshots[].DBClusterSnapshotIdentifier' --output text
}

borrar() {
  echo ">> Borrando DocumentDB..."
  aws docdb delete-db-instance --db-instance-identifier docdb-taller-1 >/dev/null 2>&1 || true
  aws docdb wait db-instance-deleted --db-instance-identifier docdb-taller-1 2>/dev/null || true
  aws docdb delete-db-cluster --db-cluster-identifier docdb-taller --skip-final-snapshot >/dev/null 2>&1 || true
  while aws docdb describe-db-clusters --db-cluster-identifier docdb-taller >/dev/null 2>&1; do
    echo "  esperando a que desaparezca el clúster..."; sleep 20
  done
  echo ">> Terminando EC2..."
  if [ -n "${EC2_ID:-}" ]; then
    aws ec2 terminate-instances --instance-ids "$EC2_ID" >/dev/null 2>&1 || true
    aws ec2 wait instance-terminated --instance-ids "$EC2_ID" 2>/dev/null || true
  fi
  echo ">> Borrando red..."
  borrar_sg docdb-sg; borrar_sg ec2-bastion-sg
  aws docdb delete-db-subnet-group --db-subnet-group-name taller-docdb-subnets 2>/dev/null || true
  echo ">> Verificación final:"
  estado
}

borrar_llave() {
  aws ec2 delete-key-pair --key-name docdb-key; rm -f ~/.ssh/docdb-key.pem; echo "Llave borrada (AWS y local)"
}

accion="${1:-}"; shift || true
case "$accion" in
  tunel) tunel ;;
  red|ver_red|db|ver_db|bastion|ssh_test|certificado|password|estado|borrar|borrar_llave)
     "$accion" "$@" 2>&1 | tee "$EVID/p3_${accion}.txt" ;;
  *) echo "Uso: p3 {red|db [serverless|provisioned]|bastion|ssh_test|certificado|tunel|password|ver_db|estado|borrar}"; exit 1 ;;
esac
