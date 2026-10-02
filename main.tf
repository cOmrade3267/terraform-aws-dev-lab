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
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
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

  tags = {
    Name = "dev-instance"
  }
  root_block_device {
    volume_size = 10
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