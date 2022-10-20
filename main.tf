provider "aws" {
  region     = var.aws_region
}

data "aws_ami" "os" {
  most_recent = true
  owners      = ["${var.ami_owner}"]
  name_regex  = var.ami_owner == "961395268858" ? "^CentOS 7.9.2009*" : ".*"

  filter {
    name   = "name"
    values = ["${var.ami_filter_name}*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Key Pair
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

module "key_pair" {
  source = "terraform-aws-modules/key-pair/aws"

  key_name = "rke2-cluster"
  public_key = trimspace(tls_private_key.ssh.public_key_openssh)
}

resource "local_file" "ssh_pem" {
  filename        = "${var.cluster_name}.pem"
  content         = tls_private_key.ssh.private_key_pem
  file_permission = "0600"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "rke2-${var.cluster_name}"
  cidr = "10.88.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  public_subnets  = ["10.88.1.0/24", "10.88.2.0/24", "10.88.3.0/24"]
  private_subnets = ["10.88.101.0/24", "10.88.102.0/24", "10.88.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_vpn_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Add in required tags for proper AWS CCM integration
  public_subnet_tags = merge({
    "kubernetes.io/cluster/${module.rke2.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                            = "1"
  }, var.tags)

  private_subnet_tags = merge({
    "kubernetes.io/cluster/${module.rke2.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"                   = "1"
  }, var.tags)

  tags = merge({
    "kubernetes.io/cluster/${module.rke2.cluster_name}" = "shared"
  }, var.tags)
}

module "rke2" {
  source = "git::https://github.com/rancherfederal/rke2-aws-tf.git"

  cluster_name = var.cluster_name
  vpc_id       = module.vpc.vpc_id
  subnets      = module.vpc.private_subnets # Note: Public subnets used for demo purposes, this is not recommended in production

  ami                   = data.aws_ami.os.image_id # Note: Multi OS is primarily for example purposes
  ssh_authorized_keys   = [tls_private_key.ssh.public_key_openssh]
  instance_type         = var.server_instance_type
  controlplane_internal = false # Note this defaults to best practice of true, but is explicitly set to public for demo purposes
  servers               = 3

  # Enable AWS Cloud Controller Managerssh
  enable_ccm = true

  rke2_version          = var.rke2_version
  rke2_config = <<-EOT
node-label:
  - "name=server"
EOT

  tags = var.tags

  # install_rancher = var.install_rancher
}

module "agents" {
  source = "git::https://github.com/rancherfederal/rke2-aws-tf.git//modules/agent-nodepool"

  name    = "generic"
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets 
  ami                 = data.aws_ami.os.image_id
  ssh_authorized_keys = [tls_private_key.ssh.public_key_openssh]
  spot                = false
  asg                 = { min : 1, max : 10, desired : 3 }
  instance_type       = var.agent_instance_type

  # Enable AWS Cloud Controller Manager and Cluster Autoscaler
  enable_ccm        = true
  enable_autoscaler = true

  rke2_version          = var.rke2_version
  rke2_config = <<-EOT
node-label:
  - "name=generic"
  
EOT

  cluster_data = module.rke2.cluster_data

  tags = var.tags
}

# For demonstration only, lock down ssh access in production
resource "aws_security_group_rule" "quickstart_ssh" {
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  security_group_id = module.rke2.cluster_data.cluster_sg
  type              = "ingress"
  cidr_blocks       = ["0.0.0.0/0"]
}

output "lb_url" {
  value = module.rke2.server_url
}

# Generic outputs as examples
# output "rke2" {
#   value = module.rke2
# }
# # Example method of fetching kubeconfig from state store, requires aws cli and bash locally
# resource "null_resource" "kubeconfig" {
#   depends_on = [module.rke2]

#   provisioner "local-exec" {
#     interpreter = ["bash", "-c"]
#     command     = "aws s3 cp ${module.rke2.kubeconfig_path} rke2.yaml"
#   }
# }
# output "rancher_bootstrap_password" {
#   # value = module.rke2.rancher_bootstrap_password
#   sensitive = true
# }

