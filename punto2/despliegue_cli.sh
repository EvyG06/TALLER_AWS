#!/bin/zsh
# Despliegue punto 2 con AWS CLI. Ejecutar desde punto2/ con ./despliegue_cli.sh
set -euo pipefail
export AWS_PROFILE=user_cli
export AWS_REGION=us-east-2
NOMBRE=taller-p2-cli
TAGS=(Key=proyecto,Value=taller-aws Key=punto,Value=2 Key=metodo,Value=cli)

CUENTA=$(aws sts get-caller-identity --query Account --output text)
BUCKET="taller-eve-p2-cli-$CUENTA"

VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNETS=($(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC --query 'Subnets[].SubnetId' --output text))
AMI=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=al2023-ami-2023.*-x86_64" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
echo "VPC $VPC | subnets ${#SUBNETS[@]} | AMI $AMI"

aws s3api create-bucket --bucket $BUCKET \
  --create-bucket-configuration LocationConstraint=$AWS_REGION > /dev/null
aws s3api put-bucket-tagging --bucket $BUCKET \
  --tagging 'TagSet=[{Key=proyecto,Value=taller-aws},{Key=punto,Value=2},{Key=metodo,Value=cli}]'
echo "Bucket $BUCKET"

SG_EC2=$(aws ec2 create-security-group --group-name $NOMBRE-ec2 --description "EC2 punto 2" --vpc-id $VPC \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=metodo,Value=cli},{Key=proyecto,Value=taller-aws}]" \
  --query GroupId --output text)
SG_RDS=$(aws ec2 create-security-group --group-name $NOMBRE-rds --description "RDS punto 2, solo desde la EC2" --vpc-id $VPC \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=metodo,Value=cli},{Key=proyecto,Value=taller-aws}]" \
  --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_RDS --protocol tcp --port 5432 --source-group $SG_EC2 > /dev/null
echo "SGs $SG_EC2 $SG_RDS"

INST=$(aws ec2 run-instances --image-id $AMI --instance-type t3.micro \
  --network-interfaces "DeviceIndex=0,SubnetId=${SUBNETS[1]},Groups=$SG_EC2,AssociatePublicIpAddress=false" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NOMBRE},{Key=metodo,Value=cli},{Key=proyecto,Value=taller-aws},{Key=punto,Value=2}]" \
  --query 'Instances[0].InstanceId' --output text)
echo "EC2 $INST"

aws rds create-db-subnet-group --db-subnet-group-name $NOMBRE \
  --db-subnet-group-description "punto 2" --subnet-ids ${SUBNETS[@]} --tags ${TAGS[@]} > /dev/null
aws rds create-db-instance --db-instance-identifier $NOMBRE --engine postgres \
  --db-instance-class db.t4g.micro --allocated-storage 20 --storage-type gp3 \
  --master-username taller_admin --manage-master-user-password \
  --db-subnet-group-name $NOMBRE --vpc-security-group-ids $SG_RDS \
  --no-publicly-accessible --backup-retention-period 0 --tags ${TAGS[@]} > /dev/null

printf 'BUCKET=%s\nINST=%s\nSG_EC2=%s\nSG_RDS=%s\n' $BUCKET $INST $SG_EC2 $SG_RDS > estado_cli.txt

echo "Esperando EC2 running y RDS available (5 a 10 min)..."
aws ec2 wait instance-running --instance-ids $INST
aws rds wait db-instance-available --db-instance-identifier $NOMBRE
aws rds describe-db-instances --db-instance-identifier $NOMBRE \
  --query 'DBInstances[0].[Endpoint.Address,MasterUserSecret.SecretArn]' --output text
echo "Listo"
