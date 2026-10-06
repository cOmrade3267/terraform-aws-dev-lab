module "dev_network" {
  source = "./modules/network"

  name_prefix         = "dev"
  vpc_cidr            = "10.0.0.0/16"
  public_subnet_cidr  = "10.0.1.0/24"
  private_subnet_cidr = "10.0.2.0/24"
  availability_zone   = "us-west-2a"
}

resource "aws_security_group" "mtc_security_group" {
  name        = "dev-sg"
  description = "dev security group"
  vpc_id      = module.dev_network.vpc_id

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
  subnet_id              = module.dev_network.public_subnet_id
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
# NOTE: if uncommented, subnet_id must change to module.dev_network.private_subnet_id
/*
resource "aws_instance" "mtc_private_test" {
  ami                    = data.aws_ami.mtc_ami.id
  instance_type          = "t2.micro"
  subnet_id              = module.dev_network.private_subnet_id
  vpc_security_group_ids = [aws_security_group.mtc_security_group.id]
  key_name               = aws_key_pair.mtc_auth.key_name

  tags = {
    Name = "private-subnet-test"
  }
}
*/