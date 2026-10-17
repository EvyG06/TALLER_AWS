#!/usr/bin/env bash
source "$HOME/taller-aws/scripts/lib.sh"
t() { if "${@:2}" >/dev/null 2>&1; then echo "OK     $1"; else echo "FALLA  $1"; fi; }
echo "Estás autenticado como:"; aws sts get-caller-identity --query Arn --output text
t "EC2 / VPC"        aws ec2 describe-vpcs
t "DocumentDB"       aws docdb describe-db-clusters
t "Neptune"          aws neptune describe-db-clusters
t "Secrets Manager"  aws secretsmanager list-secrets
t "S3"               aws s3 ls
t "Glue"             aws glue get-databases
t "Athena"           aws athena list-work-groups
t "IAM (roles)"      aws iam list-roles --max-items 1
