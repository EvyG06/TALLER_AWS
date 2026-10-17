terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
  }
}

provider "aws" {
  region  = "us-east-2"
  profile = "user_cli"
  default_tags {
    tags = {
      proyecto = "taller-aws"
      punto    = "2"
      metodo   = "terraform"
    }
  }
}

# ---------- Lecturas (no crean nada) ----------
data "aws_caller_identity" "yo" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# ---------- S3 ----------
resource "aws_s3_bucket" "bucket" {
  bucket        = "taller-eve-p2-tf-${data.aws_caller_identity.yo.account_id}"
  force_destroy = true
}

# ---------- Red ----------
resource "aws_security_group" "ec2" {
  name        = "taller-p2-tf-ec2"
  description = "EC2 punto 2"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  name        = "taller-p2-tf-rds"
  description = "RDS punto 2, solo desde la EC2"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }
}

resource "aws_db_subnet_group" "rds" {
  name       = "taller-p2-tf"
  subnet_ids = data.aws_subnets.default.ids
}

# ---------- EC2 ----------
resource "aws_instance" "ec2" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  associate_public_ip_address = false

  tags = {
    Name = "taller-p2-tf"
  }
}

# ---------- RDS ----------
resource "aws_db_instance" "rds" {
  identifier                  = "taller-p2-tf"
  engine                      = "postgres"
  instance_class              = "db.t4g.micro"
  allocated_storage           = 20
  storage_type                = "gp3"
  username                    = "taller_admin"
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.rds.name
  vpc_security_group_ids      = [aws_security_group.rds.id]
  publicly_accessible         = false
  backup_retention_period     = 0
  skip_final_snapshot         = true
  delete_automated_backups    = true
  apply_immediately           = true
}

# ---------- Salidas ----------
output "bucket" {
  value = aws_s3_bucket.bucket.id
}

output "ec2_id" {
  value = aws_instance.ec2.id
}

output "rds_endpoint" {
  value = aws_db_instance.rds.address
}

output "rds_secret_arn" {
  value = aws_db_instance.rds.master_user_secret[0].secret_arn
}
