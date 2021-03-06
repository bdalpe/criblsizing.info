terraform {
  backend "s3" {
    bucket = "criblsizing.info.tfbackend"
    key = "state"
    region = "us-east-1"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

variable "aws_region" { default = "us-east-1" }
variable "domain_name" { default = "criblsizing.info" }

provider "aws" {
  region = var.aws_region
}

// S3 Bucket to hold all static assets
resource "aws_s3_bucket" "site_assets" {
  bucket = var.domain_name
  acl = "private"

  server_side_encryption_configuration {
    rule {
      bucket_key_enabled = false

      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

// Bucket is not publicly accessible
resource "aws_s3_bucket_public_access_block" "bucket_acls" {
  bucket = aws_s3_bucket.site_assets.id

  block_public_acls   = true
  block_public_policy = true
  ignore_public_acls = true
  restrict_public_buckets = true
}

// Must use OAI to access bucket. Add this to bucket policy.
// https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html
data aws_iam_policy_document s3_policy {
  statement {
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = ["${aws_s3_bucket.site_assets.arn}/*", aws_s3_bucket.site_assets.arn]

    principals {
      identifiers = [aws_cloudfront_origin_access_identity.oai.iam_arn]
      type = "AWS"
    }
  }
}

// Required separate, otherwise cycle occurs when trying to create the bucket
resource "aws_s3_bucket_policy" "static_bucket_policy" {
  bucket = aws_s3_bucket.site_assets.id
  policy = data.aws_iam_policy_document.s3_policy.json
}

// Use ACM to generate an SSL certificate for the Cloudfront Distribution
resource "aws_acm_certificate" "certificate" {
  domain_name = var.domain_name
  validation_method = "DNS"
  subject_alternative_names = ["www.${var.domain_name}"]
}

resource "aws_acm_certificate_validation" "validation" {
  certificate_arn         = aws_acm_certificate.certificate.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_cert_validation : record.fqdn]
}

// OAI for the S3 Bucket
resource "aws_cloudfront_origin_access_identity" "oai" {}

// Cloudfront Distribution
resource "aws_cloudfront_distribution" "cloudfront" {
  // S3 Bucket Origin - Static files
  origin {
    domain_name = aws_s3_bucket.site_assets.bucket_regional_domain_name
    origin_id = "s3_bucket"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.oai.cloudfront_access_identity_path
    }
  }

  enabled = true
  is_ipv6_enabled = true
  aliases = [var.domain_name, "www.${var.domain_name}"]
  default_root_object = "index.html"

  // Default all requests to the S3 bucket origin
  default_cache_behavior {
    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods = ["GET", "HEAD"]
    target_origin_id = "s3_bucket"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl = 0
    default_ttl = 3600
    max_ttl = 86400
  }

  price_class = "PriceClass_100"

  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate.certificate.arn
    ssl_support_method = "sni-only"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}

// Route53 Records
data "aws_route53_zone" "route53_zone" {
  name = var.domain_name
}

// ACM DNS Validation Records
resource "aws_route53_record" "acm_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.certificate.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  zone_id = data.aws_route53_zone.route53_zone.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

// Route 53 records
resource "aws_route53_record" "site_a_record" {
  for_each = {
    for entry in setproduct([var.domain_name, "www.${var.domain_name}"], ["A", "AAAA"]) : "${entry[0]}-${entry[1]}" => {
      name = entry[0]
      type = entry[1]
    }
  }

  zone_id = data.aws_route53_zone.route53_zone.zone_id
  name = each.value.name
  type = each.value.type

  alias {
    name = aws_cloudfront_distribution.cloudfront.domain_name
    zone_id = aws_cloudfront_distribution.cloudfront.hosted_zone_id
    evaluate_target_health = false
  }
}