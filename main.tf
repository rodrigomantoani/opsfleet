data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  name = var.cluster_name
  tags = {
    Environment = "demo"
    Terraform   = "true"
    GithubRepo  = "terraform-aws-eks"
    GithubOrg   = "terraform-aws-modules"
  }
}

# Create EIP for NAT Gateway
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = local.tags
}

# Create NAT Gateway
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = var.public_subnet_ids[0]

  tags = merge(
    local.tags,
    {
      Name = "${var.cluster_name}-nat"
    }
  )
}

# Create route table for private subnets
resource "aws_route_table" "private" {
  vpc_id = var.vpc_id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = merge(
    local.tags,
    {
      Name = "${var.cluster_name}-private"
    }
  )
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name                   = var.cluster_name
  cluster_version               = "1.28"
  cluster_endpoint_public_access = true

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    initial = {
      instance_types = var.instance_types

      min_size     = 1
      max_size     = 2
      desired_size = 1

      capacity_type = "ON_DEMAND"
    }
    karpenter = {
      instance_types = var.instance_types

      min_size     = 1
      max_size     = 2
      desired_size = 1

      capacity_type = "SPOT"
    }
  }

  tags = local.tags
}

# Create IAM role for Karpenter node group
resource "aws_iam_role" "karpenter_node" {
  name = "karpenter-node-${local.name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "karpenter-node-${local.name}"
  role = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_policies" {
  for_each = {
    AmazonEKSWorkerNodePolicy          = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    AmazonEKS_CNI_Policy              = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    AmazonSSMManagedInstanceCore       = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  policy_arn = each.value
  role       = aws_iam_role.karpenter_node.name
}

# Create IAM role for Karpenter controller
module "karpenter_controller_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                          = "karpenter-controller-${local.name}"
  attach_karpenter_controller_policy = true

  karpenter_controller_cluster_name = module.eks.cluster_name
  karpenter_controller_node_iam_role_arns = [
    aws_iam_role.karpenter_node.arn
  ]

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["karpenter:karpenter"]
    }
  }

  # Attach additional required policies
  role_policy_arns = {
    AmazonEKSWorkerNodePolicy         = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
    AmazonEKS_CNI_Policy             = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
    AmazonEC2ContainerRegistryReadOnly = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
    AmazonSSMManagedInstanceCore      = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

# Tag subnets for Karpenter auto-discovery
resource "aws_ec2_tag" "subnet_tags" {
  for_each    = toset(var.private_subnet_ids)
  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = local.name
}

# Tag subnets for cluster
resource "aws_ec2_tag" "cluster_subnet_tags" {
  for_each    = toset(var.private_subnet_ids)
  resource_id = each.value
  key         = "kubernetes.io/cluster/${local.name}"
  value       = "owned"
}

# Create aws-auth ConfigMap for EKS authentication
resource "kubectl_manifest" "aws_auth" {
  depends_on = [module.eks]
  yaml_body = <<-YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapUsers: |
    - userarn: arn:aws:iam::559050207966:user/paygw
      username: admin
      groups:
        - system:masters
  mapRoles: |
    - rolearn: ${aws_iam_role.karpenter_node.arn}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
    - rolearn: ${module.eks.eks_managed_node_groups["initial"].iam_role_arn}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
YAML
}
