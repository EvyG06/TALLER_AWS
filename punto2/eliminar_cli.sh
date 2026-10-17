#!/bin/zsh
# Eliminacion punto 2 con AWS CLI. Ejecutar desde punto2/ con ./eliminar_cli.sh
set -euo pipefail
export AWS_PROFILE=user_cli
export AWS_REGION=us-east-2
NOMBRE=taller-p2-cli
source ./estado_cli.txt

aws ec2 terminate-instances --instance-ids $INST > /dev/null
aws rds delete-db-instance --db-instance-identifier $NOMBRE \
  --skip-final-snapshot --delete-automated-backups > /dev/null
aws s3api delete-bucket --bucket $BUCKET
echo "Bucket borrado. Esperando EC2 y RDS..."

aws ec2 wait instance-terminated --instance-ids $INST
echo "EC2 terminada"
aws rds wait db-instance-deleted --db-instance-identifier $NOMBRE
echo "RDS eliminada"
aws rds delete-db-subnet-group --db-subnet-group-name $NOMBRE
echo "Subnet group borrado"

for SG in $SG_RDS $SG_EC2; do
  for i in {1..12}; do
    if aws ec2 delete-security-group --group-id $SG 2>/dev/null; then
      echo "SG borrado $SG"; break
    fi
    echo "SG $SG aun en uso, reintento en 10 s"; sleep 10
  done
done
echo "Todo eliminado"
