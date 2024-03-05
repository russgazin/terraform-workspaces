# vpc:
module "vpc" {
  source = "github.com/russgazin/b11-modules.git//vpc_module"

  cidr_block        = var.vpc_cidr_block
  create_attach_igw = var.create_attach_igw
  vpc_tag           = var.vpc_tag
}

# subnets:
module "subnets" {
  source = "github.com/russgazin/b11-modules.git//subnet_module"

  for_each = var.subnet_for_each

  vpc_id                  = module.vpc.id
  cidr_block              = each.value[0]
  availability_zone       = each.value[1]
  map_public_ip_on_launch = each.value[2]
  subnet_tag              = each.key
}

# natgw:
module "natgw" {
  source = "github.com/russgazin/b11-modules.git//natgw_module"

  subnet_id = module.subnets["public_1a"].id
  natgw_tag = var.natgw_tag
}

# public rtb:
module "public_rtb" {
  source = "github.com/russgazin/b11-modules.git//rtb_module"

  vpc_id         = module.vpc.id
  gateway_id     = module.vpc.igw_id
  nat_gateway_id = null
  subnets        = [module.subnets["public_1a"].id, module.subnets["public_1b"].id]
}

# private rtb:
module "private_rtb" {
  source = "github.com/russgazin/b11-modules.git//rtb_module"

  vpc_id         = module.vpc.id
  gateway_id     = null
  nat_gateway_id = module.natgw.id
  subnets        = [module.subnets["private_1a"].id, module.subnets["private_1b"].id]
}

# ec2 sgrp:
module "ec2_sgrp" {
  source = "github.com/russgazin/b11-modules.git//sg_module"

  name        = "${terraform.workspace}-sgrp"
  description = "${terraform.workspace}-sgrp"
  vpc_id      = module.vpc.id
  sg_tag      = "${terraform.workspace}_sgrp"
  sg_rules    = var.ec2_sgrp_rules
}

data "aws_ami" "ami" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-kernel-5.10-hvm*x86_64-gp2"]
  }
}

data "aws_key_pair" "mykey" {
  key_name = "virginia"
}

# ec2:
module "instances" {
  source = "github.com/russgazin/b11-modules.git//ec2_module"

  #for_each = toset([module.subnets["public_1a"].id, [module.subnets["public_1b"].id]])

  for_each = {
    #             KEY                                     VALUE
    "${terraform.workspace}_instance_pub_1a" = module.subnets["public_1a"].id
    "${terraform.workspace}_instance_pub_1b" = module.subnets["public_1b"].id
  }

  ami                    = data.aws_ami.ami.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [module.ec2_sgrp.id]
  instance_tag           = each.key
  subnet_id              = each.value
  key_name               = data.aws_key_pair.mykey.key_name
  user_data              = file("${terraform.workspace}_user_data.sh")
}

# alb sgrp:
module "alb_sgrp" {
  source = "github.com/russgazin/b11-modules.git//sg_module"

  name        = "${terraform.workspace}-alb-sgrp"
  description = "${terraform.workspace}-alb-sgrp"
  vpc_id      = module.vpc.id
  sg_tag      = "${terraform.workspace}_alb_sgrp"
  sg_rules    = var.alb_sgrp_rules
}

data "aws_route53_zone" "my_zone" {
  name         = "rustemtentech.com"
  private_zone = false
}

# ssl/tls cert:
module "cert" {
  source = "github.com/russgazin/b11-modules.git//acm_module"

  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  cert_tag                  = "${terraform.workspace}_certificate"
  zone_id                   = data.aws_route53_zone.my_zone.id
}

module "tg" {
  source = "github.com/russgazin/b11-modules.git//tg_module"

  tg_name     = "${terraform.workspace}-tg"
  tg_port     = 80
  tg_protocol = "HTTP"
  tg_vpc_id   = module.vpc.id
  tg_tag      = "${terraform.workspace}_tg"
  instance_ids = [
    module.instances["${terraform.workspace}_instance_pub_1a"].id,
    module.instances["${terraform.workspace}_instance_pub_1b"].id,
  ]
}

module "alb" {
  source = "github.com/russgazin/b11-modules.git//alb_module"

  name               = "${terraform.workspace}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [module.alb_sgrp.id]
  subnets = [
    module.subnets["public_1a"].id,
    module.subnets["public_1b"].id
  ]

  alb_tag          = "${terraform.workspace}_alb"
  certificate_arn  = module.cert.arn
  target_group_arn = module.tg.tg_arn
}

module "cname" {
  source = "github.com/russgazin/b11-modules.git//dns_module"

  zone_id = data.aws_route53_zone.my_zone.id
  name    = "${terraform.workspace}.rustemtentech.com"
  type    = "CNAME"
  ttl     = 60
  records = [module.alb.dns_name]
}

# rds sgrp:
module "rds_sgrp" {
  source = "github.com/russgazin/b11-modules.git//sg_module"

  name        = "${terraform.workspace}-rds-sgrp"
  description = "${terraform.workspace}-rds-sgrp"
  vpc_id      = module.vpc.id
  sg_tag      = "${terraform.workspace}_rds_sgrp"
  sg_rules    = var.rds_sgrp_rules
}

# subnet group:
resource "aws_db_subnet_group" "db_subnet_group" {
  name = "rds-subnet-group"

  subnet_ids = [
    module.subnets["private_1a"].id,
    module.subnets["private_1b"].id
  ]

  tags = {
    Name = "My DB subnet group"
  }
}

locals {
  db_credentials = jsondecode(data.aws_secretsmanager_secret_version.creds.secret_string)
}

# data call to get our secret from secret manager:
# this will be in json format, but we need text:
data "aws_secretsmanager_secret_version" "creds" {
  #secret name = name
  secret_id = "rds-creds"
}

# create database:
resource "aws_db_instance" "db" {
  allocated_storage           = "20"
  allow_major_version_upgrade = false
  auto_minor_version_upgrade  = false
  apply_immediately           = false
  db_subnet_group_name        = aws_db_subnet_group.db_subnet_group.name
  engine                      = "mysql"
  engine_version              = "5.7.37"
  instance_class              = "db.t2.micro"
  multi_az                    = false
  db_name                     = "pracdb"
  username                    = local.db_credentials.USERNAME
  password                    = local.db_credentials.PASSWORD
  publicly_accessible         = false
  skip_final_snapshot         = true
  storage_encrypted           = false
  storage_type                = "standard"
  vpc_security_group_ids      = [module.rds_sgrp.id]
}

resource "random_string" "username" {
  length  = 8
  special = false
}

resource "aws_ssm_parameter" "save_username_to_ssm" {
  name        = "/rds/username"
  description = "RDS DB name"
  type        = "SecureString"
  value       = random_string.username.result
}

resource "random_string" "password" {
  length  = 16
  special = true
}

resource "aws_ssm_parameter" "save_password_to_ssm" {
  name        = "/rds/password"
  description = "RDS DB password"
  type        = "SecureString"
  value       = random_string.password.result
}


# create 2nd database:
resource "aws_db_instance" "db2" {
  allocated_storage           = "20"
  allow_major_version_upgrade = false
  auto_minor_version_upgrade  = false
  apply_immediately           = false
  db_subnet_group_name        = aws_db_subnet_group.db_subnet_group.name
  engine                      = "mysql"
  engine_version              = "5.7.37"
  instance_class              = "db.t2.micro"
  multi_az                    = false
  db_name                     = "pracdb"
  username                    = random_string.username.result
  password                    = random_string.password.result
  publicly_accessible         = false
  skip_final_snapshot         = true
  storage_encrypted           = false
  storage_type                = "standard"
  vpc_security_group_ids      = [module.rds_sgrp.id]
}
