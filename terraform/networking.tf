data "aws_availability_zones" "azs_available" {
  state = "available"
}

resource "aws_vpc" "vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.vpc_name
  }
}

resource "aws_subnet" "subnet_eks_public" {
  count = length(local.selected_public_cidrs)

  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = local.selected_public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                              = "${local.eks_subnet_name}-public-${count.index + 1}"
    "kubernetes.io/cluster/${local.eks_cluster_name}" = "shared"
    "kubernetes.io/role/elb"                          = "1"
  }
}

resource "aws_subnet" "subnet_eks_private" {
  count = length(local.selected_private_cidrs)

  vpc_id            = aws_vpc.vpc.id
  cidr_block        = local.selected_private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name                                              = "${local.eks_subnet_name}-private-${count.index + 1}"
    "kubernetes.io/cluster/${local.eks_cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"                 = "1"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id

  tags = {
    Name = "igw-${var.project_name}"
  }
}

resource "aws_eip" "eip_natgw" {
  domain = "vpc"

  tags = {
    Name = "eip-natgw-${var.project_name}"
  }
}

resource "aws_nat_gateway" "natgw" {
  allocation_id = aws_eip.eip_natgw.id
  subnet_id     = aws_subnet.subnet_eks_public[0].id

  tags = {
    Name = "natgw-${var.project_name}"
  }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "rt_public" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "rt-public-${var.project_name}"
  }
}

resource "aws_route_table_association" "rtassoc_public" {
  count = length(aws_subnet.subnet_eks_public)

  subnet_id      = aws_subnet.subnet_eks_public[count.index].id
  route_table_id = aws_route_table.rt_public.id
}

resource "aws_route_table" "rt_private" {
  vpc_id = aws_vpc.vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.natgw.id
  }

  tags = {
    Name = "rt-private-${var.project_name}"
  }
}

resource "aws_route_table_association" "rtassoc_private" {
  count = length(aws_subnet.subnet_eks_private)

  subnet_id      = aws_subnet.subnet_eks_private[count.index].id
  route_table_id = aws_route_table.rt_private.id
}
