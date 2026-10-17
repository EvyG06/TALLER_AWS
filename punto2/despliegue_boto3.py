import json
import sys
import time

import boto3
from botocore.exceptions import ClientError

REGION = "us-east-2"
PERFIL = "user_cli"
ESTADO = "estado_boto3.json"
NOMBRE = "taller-p2-boto3"
TAGS = [{"Key": "proyecto", "Value": "taller-aws"},
        {"Key": "punto", "Value": "2"},
        {"Key": "metodo", "Value": "boto3"}]

s = boto3.Session(profile_name=PERFIL, region_name=REGION)
ec2, rds, s3 = s.client("ec2"), s.client("rds"), s.client("s3")
cuenta = s.client("sts").get_caller_identity()["Account"]


def crear():
    vpc_id = ec2.describe_vpcs(Filters=[{"Name": "isDefault", "Values": ["true"]}])["Vpcs"][0]["VpcId"]
    subnets = [x["SubnetId"] for x in ec2.describe_subnets(
        Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])["Subnets"]]
    imagenes = ec2.describe_images(Owners=["amazon"], Filters=[
        {"Name": "name", "Values": ["al2023-ami-2023.*-x86_64"]}])["Images"]
    ami = sorted(imagenes, key=lambda i: i["CreationDate"])[-1]["ImageId"]
    print("VPC", vpc_id, "| subnets", len(subnets), "| AMI", ami)

    bucket = f"taller-eve-p2-boto3-{cuenta}"
    s3.create_bucket(Bucket=bucket,
                     CreateBucketConfiguration={"LocationConstraint": REGION})
    s3.put_bucket_tagging(Bucket=bucket, Tagging={"TagSet": TAGS})
    print("Bucket", bucket)

    sg_ec2 = ec2.create_security_group(
        GroupName=f"{NOMBRE}-ec2", Description="EC2 punto 2", VpcId=vpc_id,
        TagSpecifications=[{"ResourceType": "security-group", "Tags": TAGS}])["GroupId"]
    sg_rds = ec2.create_security_group(
        GroupName=f"{NOMBRE}-rds", Description="RDS punto 2, solo desde la EC2", VpcId=vpc_id,
        TagSpecifications=[{"ResourceType": "security-group", "Tags": TAGS}])["GroupId"]
    ec2.authorize_security_group_ingress(GroupId=sg_rds, IpPermissions=[{
        "IpProtocol": "tcp", "FromPort": 5432, "ToPort": 5432,
        "UserIdGroupPairs": [{"GroupId": sg_ec2}]}])
    print("SGs", sg_ec2, sg_rds)

    inst = ec2.run_instances(
        ImageId=ami, InstanceType="t3.micro", MinCount=1, MaxCount=1,
        NetworkInterfaces=[{"DeviceIndex": 0, "SubnetId": subnets[0],
                            "Groups": [sg_ec2], "AssociatePublicIpAddress": False}],
        TagSpecifications=[{"ResourceType": "instance",
                            "Tags": TAGS + [{"Key": "Name", "Value": NOMBRE}]}],
    )["Instances"][0]["InstanceId"]
    print("EC2", inst)

    rds.create_db_subnet_group(DBSubnetGroupName=NOMBRE, DBSubnetGroupDescription="punto 2",
                               SubnetIds=subnets, Tags=TAGS)
    rds.create_db_instance(
        DBInstanceIdentifier=NOMBRE, Engine="postgres", DBInstanceClass="db.t4g.micro",
        AllocatedStorage=20, StorageType="gp3", MasterUsername="taller_admin",
        ManageMasterUserPassword=True, DBSubnetGroupName=NOMBRE,
        VpcSecurityGroupIds=[sg_rds], PubliclyAccessible=False,
        BackupRetentionPeriod=0, Tags=TAGS)

    with open(ESTADO, "w") as f:
        json.dump({"bucket": bucket, "sg_ec2": sg_ec2, "sg_rds": sg_rds, "instancia": inst}, f, indent=2)

    print("Esperando EC2 running y RDS available (5 a 10 min)...")
    ec2.get_waiter("instance_running").wait(InstanceIds=[inst])
    rds.get_waiter("db_instance_available").wait(
        DBInstanceIdentifier=NOMBRE, WaiterConfig={"Delay": 30, "MaxAttempts": 40})
    db = rds.describe_db_instances(DBInstanceIdentifier=NOMBRE)["DBInstances"][0]
    print("Listo")
    print("  RDS endpoint ", db["Endpoint"]["Address"])
    print("  RDS secreto  ", db["MasterUserSecret"]["SecretArn"])


def borrar_sg(sg_id):
    for intento in range(12):
        try:
            ec2.delete_security_group(GroupId=sg_id)
            print("SG borrado", sg_id)
            return
        except ClientError as e:
            if e.response["Error"]["Code"] != "DependencyViolation":
                raise
            print("SG", sg_id, "aun en uso, reintento en 10 s")
            time.sleep(10)
    raise SystemExit(f"No se pudo borrar {sg_id}")


def eliminar():
    with open(ESTADO) as f:
        e = json.load(f)
    ec2.terminate_instances(InstanceIds=[e["instancia"]])
    rds.delete_db_instance(DBInstanceIdentifier=NOMBRE,
                           SkipFinalSnapshot=True, DeleteAutomatedBackups=True)
    s3.delete_bucket(Bucket=e["bucket"])
    print("Bucket borrado. Esperando EC2 y RDS...")
    ec2.get_waiter("instance_terminated").wait(InstanceIds=[e["instancia"]])
    print("EC2 terminada")
    rds.get_waiter("db_instance_deleted").wait(
        DBInstanceIdentifier=NOMBRE, WaiterConfig={"Delay": 30, "MaxAttempts": 40})
    print("RDS eliminada")
    rds.delete_db_subnet_group(DBSubnetGroupName=NOMBRE)
    print("Subnet group borrado")
    borrar_sg(e["sg_rds"])
    borrar_sg(e["sg_ec2"])
    print("Todo eliminado")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("crear", "eliminar"):
        raise SystemExit("Uso: python despliegue_boto3.py crear|eliminar")
    {"crear": crear, "eliminar": eliminar}[sys.argv[1]]()
