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