resource "aws_s3_bucket" "mtc_bucket" {
  bucket        = "mtc-lab-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name = "mtc-lab-bucket"
  }
}

resource "aws_s3_bucket_public_access_block" "mtc_bucket" {
  bucket                  = aws_s3_bucket.mtc_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "mtc_bucket" {
  bucket = aws_s3_bucket.mtc_bucket.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "mtc_bucket" {
  bucket = aws_s3_bucket.mtc_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mtc_bucket" {
  bucket = aws_s3_bucket.mtc_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}