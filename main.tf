resource "aws_vpc" "mtc_vpc" {

  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "dev"
  }

}

resource "aws_subnet" "mtc_subnet" {

  vpc_id                  = aws_vpc.mtc_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-west-2a"

  tags = {
    Name = "dev-subnet"
  }
}

resource "aws_subnet" "mtc_private_subnet" {
  vpc_id            = aws_vpc.mtc_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-west-2a"

  tags = {
    Name = "dev-private-subnet"
  }
}

resource "aws_route_table" "mtc_private_route_table" {
  vpc_id = aws_vpc.mtc_vpc.id

  tags = {
    Name = "dev-private-route-table"
  }
}

resource "aws_route_table_association" "mtc_private_route_table_association" {
  subnet_id      = aws_subnet.mtc_private_subnet.id
  route_table_id = aws_route_table.mtc_private_route_table.id
}

resource "aws_internet_gateway" "mtc_internet_gateway" {

  vpc_id = aws_vpc.mtc_vpc.id

  tags = {
    Name = "dev-igw"
  }
}

resource "aws_route_table" "mtc_route_table" {

  vpc_id = aws_vpc.mtc_vpc.id

  tags = {
    Name = "dev-route-table"
  }
}


resource "aws_route" "mtc_default_route" {

  route_table_id         = aws_route_table.mtc_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.mtc_internet_gateway.id
}

resource "aws_route_table_association" "mtc_route_table_association" {

  subnet_id      = aws_subnet.mtc_subnet.id
  route_table_id = aws_route_table.mtc_route_table.id
}

resource "aws_security_group" "mtc_security_group" {
  name        = "dev-sg"
  description = "dev security group"
  vpc_id      = aws_vpc.mtc_vpc.id

  ingress {
    description = "SSH from my IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  ingress {
    description = "ICMP from within the VPC (NACL test)"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.0.0.0/16"]
  }
  ingress {
    description = "SSH from within the VPC (NACL ephemeral-port test)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }
  egress {
    description = "Allow all outbound (apt and Docker downloads)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_key_pair" "mtc_auth" {

  key_name   = "mtc_auth"
  public_key = file(pathexpand("~/.ssh/mtckey.pub"))
}

resource "aws_instance" "mtc_instance" {
  ami                    = data.aws_ami.mtc_ami.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.mtc_subnet.id
  vpc_security_group_ids = [aws_security_group.mtc_security_group.id]
  key_name               = aws_key_pair.mtc_auth.key_name
  user_data              = templatefile("${path.module}/userdata.tpl", {})
  iam_instance_profile   = aws_iam_instance_profile.mtc_ec2_profile.name
  tags = {
    Name = "dev-instance"
  }
  root_block_device {
    volume_size = 10
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  provisioner "local-exec" {
    command = templatefile("${path.module}/linux-ssh-config.tpl", {
      hostname     = self.public_ip
      user         = "ubuntu"
      identityfile = pathexpand("~/.ssh/mtckey")
    })
    interpreter = var.host_os == "windows" ? ["PowerShell", "-Command"] : ["/bin/bash", "-c"]
  }
}

# Commented out: was a throwaway test instance for the NACL/SG exercise (section 22).
# Uncomment and `terraform apply` if you want to rebuild it for further testing.
/*
resource "aws_instance" "mtc_private_test" {
  ami                    = data.aws_ami.mtc_ami.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.mtc_private_subnet.id
  vpc_security_group_ids = [aws_security_group.mtc_security_group.id]
  key_name               = aws_key_pair.mtc_auth.key_name

  tags = {
    Name = "private-subnet-test"
  }
}
*/

resource "aws_network_acl" "mtc_private_nacl" {
  vpc_id     = aws_vpc.mtc_vpc.id
  subnet_ids = [aws_subnet.mtc_private_subnet.id]

  ingress {
    rule_no    = 100
    protocol   = "icmp"
    icmp_type  = -1
    icmp_code  = -1
    action     = "allow"
    cidr_block = "10.0.0.0/16"
    from_port  = 0
    to_port    = 0
  }

  egress {
    rule_no    = 100
    protocol   = "icmp"
    icmp_type  = -1
    icmp_code  = -1
    action     = "allow"
    cidr_block = "10.0.0.0/16"
    from_port  = 0
    to_port    = 0
  }

  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "10.0.0.0/16"
    from_port  = 22
    to_port    = 22
  }

  egress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "10.0.0.0/16"
    from_port  = 22
    to_port    = 22
  }

  egress {
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "10.0.0.0/16"
    from_port  = 1024
    to_port    = 65535
  }

  tags = {
    Name = "dev-private-nacl"
  }
}