# Input variables
variable "access_key" {}
variable "secret_key" {}
variable "region" {
  default = "us-east-1"
}
variable "email_dmarc_report" {}


provider "aws" {
  access_key = "${var.access_key}"
  secret_key = "${var.secret_key}"
  region = "${var.region}"
}

data "aws_caller_identity" "current" {}


#Archive the lambdas python files into zip files
data "archive_file" "dmarc_extractor_lambda_zip" {
  type = "zip"
  source_file = "${path.module}/functions/dmarc-compressed-extractor.py"
  output_path = "${path.module}/functions/dmarc-compressed-extractor.zip"
}

data "archive_file" "dmarc_transformation_zip" {
  type = "zip"
  source_file = "${path.module}/functions/dmarc-transformation.py"
  output_path = "${path.module}/functions/dmarc-transformation.zip"
}

# 3 Buckets:
# terraform-dmarc-email-ses-received
# terraform-dmarc-xml-files
# terraform-dmarc-json-files
resource "aws_s3_bucket" "dmarc_email_ses_received" {
  bucket = "terraform-dmarc-email-ses-received"
  acl = "private"
  force_destroy = true

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowSESPuts",
            "Effect": "Allow",
            "Principal": {
                "Service": "ses.amazonaws.com"
            },
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::terraform-dmarc-email-ses-received/*",
            "Condition": {
                "StringEquals": {
                    "aws:Referer": "${data.aws_caller_identity.current.account_id}"
                }
            }
        }
    ]
}
EOF
}

resource "aws_s3_bucket" "dmarc_xml_files" {
  bucket = "terraform-dmarc-xml-files"
  acl = "private"
  force_destroy = true
}

resource "aws_s3_bucket" "dmarc_json_files" {
  bucket = "terraform-dmarc-json-files"
  acl = "private"
  force_destroy = true
}

# AWS SES configuration - Rule, RuleSet and activating RuleSet
resource "aws_ses_receipt_rule" "dmarc_report_ses_rule" {
  name = "terraform-dmarc-report"
  rule_set_name = "${aws_ses_receipt_rule_set.terraform_dmarc_ruleset.rule_set_name}"
  recipients = [
    "${var.email_dmarc_report}"]
  enabled = true
  scan_enabled = true

  s3_action {
    bucket_name = "${aws_s3_bucket.dmarc_email_ses_received.bucket}"
    position = 1
  }
}

resource "aws_ses_receipt_rule_set" "terraform_dmarc_ruleset" {
  rule_set_name = "terraform-dmarc-ruleset"
}

resource "aws_ses_active_receipt_rule_set" "main" {
  rule_set_name = "${aws_ses_receipt_rule_set.terraform_dmarc_ruleset.rule_set_name}"
}


# Lambda terraform-dmarc-extractor configuration - role, policy & lambda
resource "aws_iam_role" "dmarc_extractor_lambda_role" {
  name = "terraform-dmarc-lambda-extractor-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_policy" "dmarc_extract_lambda_policy" {
  name = "terraform-dmarc-lambda-extractor-lambda-policy"
  description = "DMARC Extract Lambda Policy"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ListBuckets",
            "Effect": "Allow",
            "Action": [
                "s3:List*",
                "s3:Head*"
            ],
            "Resource": "*"
        },
        {
            "Sid": "AllowGetListEmails",
            "Effect": "Allow",
            "Action": "s3:Get*",
            "Resource": "arn:aws:s3:::${aws_s3_bucket.dmarc_email_ses_received.bucket}/*"
        },
        {
            "Sid": "AllowPutDmarcXML",
            "Effect": "Allow",
            "Action": [
                "s3:Put*"
            ],
            "Resource": "arn:aws:s3:::${aws_s3_bucket.dmarc_xml_files.bucket}/*"
        }
    ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "dmarc_extract_lambda_attach" {
  role = "${aws_iam_role.dmarc_extractor_lambda_role.name}"
  policy_arn = "${aws_iam_policy.dmarc_extract_lambda_policy.arn}"
}


resource "aws_lambda_permission" "allow_dmarc_email_ses_received_bucket" {
  statement_id = "AllowExecutionFromS3Bucket"
  action = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.dmarc_extractor_xml.arn}"
  principal = "s3.amazonaws.com"
  source_arn = "${aws_s3_bucket.dmarc_email_ses_received.arn}"
}

resource "aws_lambda_function" "dmarc_extractor_xml" {
  filename = "${path.module}/functions/dmarc-compressed-extractor.zip"
  function_name = "terraform-dmarc-extractor"
  role = "${aws_iam_role.dmarc_extractor_lambda_role.arn}"
  handler = "dmarc-compressed-extractor.lambda_handler"
  runtime = "python2.7"

  environment {
    variables = {
      OUTPUT_BUCKET_NAME = "${aws_s3_bucket.dmarc_xml_files.bucket}"
    }
  }
}


# Add notification on bucket terraform-dmarc-email-ses-received to call lambda dmarc_extractor_xml
resource "aws_s3_bucket_notification" "dmarc_email_ses_received_notification" {
  bucket = "${aws_s3_bucket.dmarc_email_ses_received.id}"

  lambda_function {
    lambda_function_arn = "${aws_lambda_function.dmarc_extractor_xml.arn}"
    events = [
      "s3:ObjectCreated:*"]
  }
}


# Lambda terraform-dmarc-extractor configuration - role, policy & lambda
resource "aws_iam_role" "dmarc_transformation_lambda_role" {
  name = "terraform_iam_for_lambda_dmarc_transformation"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_policy" "dmarc_transformation_lambda_policy" {
  name = "terraform-dmarc-transformation-lambda-policy"
  description = "DMARC XML to Json Transformation Policy"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "ListBuckets",
            "Effect": "Allow",
            "Action": [
                "s3:List*",
                "s3:Head*"
            ],
            "Resource": "*"
        },
        {
            "Sid": "AllowGetListXMLFiles",
            "Effect": "Allow",
            "Action": "s3:Get*",
            "Resource": "arn:aws:s3:::${aws_s3_bucket.dmarc_xml_files.bucket}/*"
        },
        {
            "Sid": "AllowPutDmarcXML",
            "Effect": "Allow",
            "Action": [
                "s3:Put*"
            ],
            "Resource": "arn:aws:s3:::${aws_s3_bucket.dmarc_json_files.bucket}/*"
        }
    ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "dmarc_transformation_lambda_attach" {
  role = "${aws_iam_role.dmarc_transformation_lambda_role.name}"
  policy_arn = "${aws_iam_policy.dmarc_transformation_lambda_policy.arn}"
}


resource "aws_lambda_permission" "allow_dmarc_transformation_bucket" {
  statement_id = "AllowExecutionFromS3Bucket"
  action = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.dmarc_transformation_lambda.arn}"
  principal = "s3.amazonaws.com"
  source_arn = "${aws_s3_bucket.dmarc_xml_files.arn}"
}

resource "aws_lambda_function" "dmarc_transformation_lambda" {
  filename = "${path.module}/functions/dmarc-transformation.zip"
  function_name = "terraform-dmarc-transformation"
  role = "${aws_iam_role.dmarc_transformation_lambda_role.arn}"
  handler = "dmarc-transformation.lambda_handler"
  runtime = "python2.7"

  environment {
    variables = {
      OUTPUT_BUCKET_NAME = "${aws_s3_bucket.dmarc_json_files.bucket}"
    }
  }
}


#Event of the S3 object to run dmarc-transformation lambda
resource "aws_s3_bucket_notification" "dmarc_transformation_notification" {
  bucket = "${aws_s3_bucket.dmarc_xml_files.id}"

  lambda_function {
    lambda_function_arn = "${aws_lambda_function.dmarc_transformation_lambda.arn}"
    events = [
      "s3:ObjectCreated:*"]
  }
}