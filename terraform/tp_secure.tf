############################
# TP SecureCloud - Terraform final
# - Tiering AD (Tier0/Tier1/Tier2)
# - SG stateful + chiffrement + AMI maintenue
# - Aucun secret/clé AWS en dur
############################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

############################
# PROVIDER (sans clés en dur)
############################

# Auth via AWS CLI profile
provider "aws" {
  region = var.aws_region
}

############################
# VARIABLES (toutes injectées via terraform.tfvars)
############################
variable "allowed_ssh_cidr" {
  type        = string
  description = "IP publique autorisée en SSH (format /32)"
}

variable "ssh_public_key" {
  type        = string
  description = "Clé publique SSH (contenu de ~/.ssh/id_rsa.pub)"
}

variable "aws_region" {
  type        = string
  description = "Région AWS"
}

variable "db_username" {
  type        = string
  description = "Utilisateur DB"
  default     = "admin"
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "Mot de passe DB (sensible)"
}

############################
# DATA: AZ + AMI maintenue (Ubuntu 22.04 LTS)
############################
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu_22_04" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

############################
# RESEAU / TIERING
############################

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "securecloud-vpc"
  }
}

# Internet Gateway (uniquement pour Tier1 public)
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "securecloud-igw"
  }
}

# Subnet Tier 1 (Web) - PUBLIC
resource "aws_subnet" "tier1_web" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "tier1-web-public"
    Tier = "1"
  }
}

# Subnets Tier 2 (DB) - PRIVES (2 AZ)
resource "aws_subnet" "tier2_db_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name = "tier2-db-private-a"
    Tier = "2"
  }
}

resource "aws_subnet" "tier2_db_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false

  tags = {
    Name = "tier2-db-private-b"
    Tier = "2"
  }
}

# Subnet Tier 0 (isolé) - pas de route Internet
resource "aws_subnet" "tier0_admin" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.10.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name = "tier0-isolated"
    Tier = "0"
  }
}

############################
# ROUTING
############################

# Route table PUBLIQUE (Tier1)
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "public-rt-tier1"
  }
}

resource "aws_route_table_association" "tier1_assoc" {
  subnet_id      = aws_subnet.tier1_web.id
  route_table_id = aws_route_table.public_rt.id
}

# Route table PRIVEE (Tier2) - aucune route vers Internet (pas de NAT)
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "private-rt-tier2"
  }
}

resource "aws_route_table_association" "tier2_a_assoc" {
  subnet_id      = aws_subnet.tier2_db_a.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "tier2_b_assoc" {
  subnet_id      = aws_subnet.tier2_db_b.id
  route_table_id = aws_route_table.private_rt.id
}

# Route table ISOLEE (Tier0) - aucune route Internet
resource "aws_route_table" "isolated_rt" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "isolated-rt-tier0"
  }
}

resource "aws_route_table_association" "tier0_assoc" {
  subnet_id      = aws_subnet.tier0_admin.id
  route_table_id = aws_route_table.isolated_rt.id
}

############################
# SECURITY GROUPS (STATEFUL)
############################

# SG Web (Tier1): HTTP/HTTPS public + SSH seulement depuis ton IP (/32)
resource "aws_security_group" "web_sg" {
  name        = "web-tier1-sg"
  description = "Tier1 Web SG: HTTP/HTTPS public, SSH only from management IP"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from management IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    description = "All outbound (stateful return traffic allowed automatically)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "web-tier1-sg"
    Tier = "1"
  }
}

# SG DB (Tier2): MySQL uniquement depuis le SG Web
resource "aws_security_group" "db_sg" {
  name        = "db-tier2-sg"
  description = "Tier2 DB SG: MySQL only from Tier1 SG"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL from Web SG only"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  egress {
    description = "Outbound (needed for AWS internal services)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "db-tier2-sg"
    Tier = "2"
  }
}

############################
# KEYPAIR (depuis ssh_public_key)
############################
resource "aws_key_pair" "deployer" {
  key_name   = "securecloud-key"
  public_key = var.ssh_public_key
}

############################
# INSTANCE (Tier1)
############################
resource "aws_instance" "web_vm" {
  ami                         = data.aws_ami.ubuntu_22_04.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.tier1_web.id
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.deployer.key_name

  root_block_device {
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "Web-Prod-Tier1"
    Tier = "1"
  }
}

############################
# DATABASE MANAGEE (Tier2) - RDS MySQL
############################

resource "aws_db_subnet_group" "db_subnets" {
  name       = "db-subnet-group"
  subnet_ids = [aws_subnet.tier2_db_a.id, aws_subnet.tier2_db_b.id]

  tags = {
    Name = "db-subnet-group"
    Tier = "2"
  }
}

resource "aws_db_instance" "secure_db" {
  identifier        = "securecloud-mysql"
  allocated_storage = 20
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = "db.t3.micro"

  db_name  = "critique_db"
  username = var.db_username
  password = var.db_password

  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]

  storage_encrypted       = true
  backup_retention_period = 1

  skip_final_snapshot       = false
  final_snapshot_identifier = "securecloud-final-snapshot"

  tags = {
    Name = "Secure-DB-Tier2"
    Tier = "2"
  }
}

############################
# OUTPUTS
############################
output "web_public_ip" {
  value       = aws_instance.web_vm.public_ip
  description = "IP publique de la VM Tier1 (pour SSH/HTTP/HTTPS)"
}

output "web_private_ip" {
  value       = aws_instance.web_vm.private_ip
  description = "IP privée de la VM Tier1 (flux vers la DB)"
}

output "db_endpoint" {
  value       = aws_db_instance.secure_db.address
  description = "Endpoint DNS de la base RDS (accessible seulement depuis la VM Tier1 via réseau privé)"
}
