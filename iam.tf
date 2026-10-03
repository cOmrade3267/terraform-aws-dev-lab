data "aws_caller_identity" "current" {}

resource "aws_iam_role" "mtc_labreadonly" {
  name = var.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${var.trusted_user}"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "mtc_labreadonly" {
  role       = aws_iam_role.mtc_labreadonly.name
  policy_arn = var.role_policy_arn
}

output "mtc_labreadonly_arn" {
  value = aws_iam_role.mtc_labreadonly.arn
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "mtc_ec2_role" {
  name               = "mtc_ec2_role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_instance_profile" "mtc_ec2_profile" {
  name = "mtc_ec2_profile"
  role = aws_iam_role.mtc_ec2_role.name
}

resource "aws_iam_role_policy" "mtc_ec2_describe_vpcs" {
  name = "describe-vpcs-only"
  role = aws_iam_role.mtc_ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ec2:DescribeVpcs"
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "mtc_ec2_read_bucket" {
  name = "read-lab-bucket-only"
  role = aws_iam_role.mtc_ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListThisBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.mtc_bucket.arn
      },
      {
        Sid      = "ReadObjectsInThisBucket"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.mtc_bucket.arn}/*"
      }
    ]
  })
}