terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  required_version = ">= 1.8.5"
}

provider "aws" {
  region = var.region
}

# Parameter store for Lambda environment variables
resource "aws_ssm_parameter" "fixer_api_key" {
  name  = "/fixer/api_key"
  type  = "SecureString"
  value = var.ssm_fixer_api
}

resource "aws_ssm_parameter" "fixer_api_url" {
  name  = "/fixer/api_url"
  type  = "String"
  value = var.ssm_fixer_api_url
}

resource "aws_ssm_parameter" "fixer_raw_bucket" {
  name  = "/fixer/raw_bucket"
  type  = "String"
  value = aws_s3_bucket.data_ingestion_bucket.bucket
}

resource "aws_ssm_parameter" "fixer_processed_bucket" {
  name  = "/fixer/processed_bucket"
  type  = "String"
  value = aws_s3_bucket.process_data_bucket.bucket
}

resource "aws_ssm_parameter" "glue_job_name" {
  name  = "/fixer/glue_job_name"
  type  = "String"
  value = var.glue_job_name
}

# SSM iam policy
data "aws_iam_policy_document" "ssm_access" {
  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath"
    ]
    resources = [
      aws_ssm_parameter.fixer_api_key.arn,
      aws_ssm_parameter.fixer_api_url.arn,
      aws_ssm_parameter.fixer_raw_bucket.arn,
      aws_ssm_parameter.fixer_processed_bucket.arn,
      aws_ssm_parameter.glue_job_name.arn
    ]
  }
}

resource "aws_iam_policy" "ssm_access_policy" {
  name   = "ssm-access-policy"
  policy = data.aws_iam_policy_document.ssm_access.json
}


# IAM role for Lambda execution
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "lambda_execution_role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

# Package the Lambda function code
data "archive_file" "function_zip" {
  type        = "zip"
  source_file = "${path.module}/fixer_func/main.py"
  output_path = "${path.module}/fixer_func/function.zip"
}

# Lambda function
resource "aws_lambda_function" "lambda_function" {
  filename         = data.archive_file.function_zip.output_path
  function_name    = var.lambda_function_name
  role             = aws_iam_role.lambda_role.arn
  handler          = "main.handler"
  source_code_hash = data.archive_file.function_zip.output_base64sha256
  timeout          = 120
  runtime          = "python3.12"

  environment {
    variables = {
      API_KEY       = aws_ssm_parameter.fixer_api_key.name
      API_URL       = aws_ssm_parameter.fixer_api_url.name
      RAW_BUCKET    = aws_ssm_parameter.fixer_raw_bucket.name
      GLUE_JOB_NAME = aws_ssm_parameter.glue_job_name.name
      # PROCESSED_BUCKET = aws_ssm_parameter.fixer_processed_bucket.value
    }
  }

  tags = {
    Environment = "development"
    Project     = "DataIngestion"
  }
}
resource "aws_iam_role_policy_attachment" "lambda_ssm_access" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.ssm_access_policy.arn
}
# CloudWatch log group for Lambda function
resource "aws_cloudwatch_log_group" "lambda_log_group" {
  name              = "/aws/lambda/${aws_lambda_function.lambda_function.function_name}"
  retention_in_days = 14

  tags = {
    Environment = "development"
    Project     = "DataIngestion"
  }
}
resource "aws_iam_role_policy" "lambda_logs_policy" {
  name = "lambda_logs_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Effect   = "Allow"
        Resource = "${aws_cloudwatch_log_group.lambda_log_group.arn}:*"
      }
    ]
  })
}
resource "aws_iam_role_policy" "lambda_glue_policy" {
  name = "lambda_glue_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:StartJobRun",
          "glue:GetJobRun",
          "glue:GetJobRuns"
        ]
        Resource = [
          aws_glue_job.fixer_etl.arn,
          "${aws_glue_job.fixer_etl.arn}/*"
        ]
      }
    ]
  })
}

#Initail Data lake S3 bucket for data ingestion
resource "aws_s3_bucket" "data_ingestion_bucket" {
  bucket = var.s3_raw_bucket_name

  tags = {
    Name        = "DataIngestionBucket"
    Environment = "development"
  }
}
resource "aws_s3_object" "fixer_etl_script" {
  bucket = aws_s3_bucket.data_ingestion_bucket.id
  key    = "scripts/etl-script.py"                 # Path in the bucket
  source = "${path.module}/glue_job/etl_script.py" # Local path to the script
}
resource "aws_s3_bucket_versioning" "data_ingestion_bucket_versioning" {
  bucket = aws_s3_bucket.data_ingestion_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}
resource "aws_s3_bucket_public_access_block" "data_ingestion_bucket_public_access_block" {
  bucket                  = aws_s3_bucket.data_ingestion_bucket.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# Lambda function permission to access S3 buckets
resource "aws_iam_role_policy" "lambda_s3_write_policy" {
  name = "lambda_s3_write_and_logs_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Permissions for S3 PutObject (to write data to the bucket)
      {
        Action = [
          "s3:PutObject"
        ]
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.data_ingestion_bucket.arn}/*" # Grant access to objects within the bucket
      }
    ]
  })

}
# Process Data Lake S3 bucket
resource "aws_s3_bucket" "process_data_bucket" {
  bucket = var.s3_processed_bucket_name

  tags = {
    Name        = "ProcessDataBucket"
    Environment = "development"
  }
}
resource "aws_s3_bucket_versioning" "process_data_bucket_versioning" {
  bucket = aws_s3_bucket.process_data_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}
resource "aws_s3_bucket_public_access_block" "process_data_bucket_public_access_block" {
  bucket                  = aws_s3_bucket.process_data_bucket.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}
# CloudWatch log group for S3 bucket events
resource "aws_cloudwatch_log_group" "s3_event_log_group" {
  name              = "/aws/s3/data-ingestion-events"
  retention_in_days = 14

  tags = {
    Environment = "development"
    Project     = "DataIngestion"
  }
}
#EventBridge rule to trigger Lambda function
resource "aws_cloudwatch_event_rule" "lambda_trigger_rule" {
  name                = "lambda-trigger-rule"
  description         = "Trigger Lambda function daily at 12:00 UTC"
  schedule_expression = "cron(*/6 * * * ? *)" # Every day at 12:00 UTC

}

resource "aws_cloudwatch_event_target" "lambda_trigger_target" {
  rule      = aws_cloudwatch_event_rule.lambda_trigger_rule.name
  target_id = "LambdaFunction"
  arn       = aws_lambda_function.lambda_function.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_function.arn
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lambda_trigger_rule.arn
}

resource "aws_iam_role_policy" "glue_job_s3_access_policy" {
  name = "glue-job-s3-access-policy"
  role = aws_iam_role.glue_job_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # Read raw bucket
      {
        Effect = "Allow",
        Action = [
          "s3:ListBucket",
          "s3:GetObject"
        ],
        Resource = [
          aws_s3_bucket.data_ingestion_bucket.arn,
          "${aws_s3_bucket.data_ingestion_bucket.arn}/*"
        ]
      },
      # Write to processed bucket
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ],
        Resource = [
          aws_s3_bucket.process_data_bucket.arn,
          "${aws_s3_bucket.process_data_bucket.arn}/*"
        ]
      }
    ]
  })
}

#Glue job for data processing
resource "aws_glue_job" "fixer_etl" {
  name     = var.glue_job_name
  role_arn = aws_iam_role.glue_job_role.arn

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${aws_s3_bucket.data_ingestion_bucket.bucket}/${aws_s3_object.fixer_etl_script.key}"
  }
  default_arguments = {
    "--RAW_BUCKET"                       = var.s3_raw_bucket_name
    "--PROCESSED_BUCKET"                 = var.s3_processed_bucket_name
    "--JOB_NAME"                         = var.glue_job_name
    "--enable-metrics"                   = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-continuous-log-filter"     = "true"
    "--job-bookmark-option"              = "job-bookmark-enable" # <--- Enable bookmarking
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${aws_s3_bucket.data_ingestion_bucket.bucket}/spark-logs/"
  }
  max_retries = 1
  timeout     = 10
  tags = {
    Environment = "development"
    Project     = "DataIngestion"
  }
  execution_property {
    max_concurrent_runs = 1
  }
}
resource "aws_cloudwatch_log_group" "glue_job_log_group" {
  name              = "/aws-glue/jobs/${aws_glue_job.fixer_etl.name}"
  retention_in_days = 14

  tags = {
    Environment = "development"
    Project     = "DataIngestion"
  }
}
# IAM role for Glue jobs (Must have permissions to read/write to S3 and access Glue)
resource "aws_iam_role" "glue_job_role" {
  name = "glue-job-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
      }
    ]
  })
}
resource "aws_iam_role_policy" "glue_job_logs_policy" {
  name = "glue-job-logs-policy"
  role = aws_iam_role.glue_job_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "${aws_cloudwatch_log_group.glue_job_log_group.arn}:*"
      }
    ]
  })
}

# Glue catalog database
resource "aws_glue_catalog_database" "glue_catalog_database" {
  name = var.glue_database_name
  create_table_default_permission {
    permissions = ["SELECT"]

    principal {
      data_lake_principal_identifier = "IAM_ALLOWED_PRINCIPALS"
    }
  }
}

# IAM role for Glue Crawler
resource "aws_iam_role" "glue_crawler_role" {
  name = "glue_crawler_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
      }
    ]
  })
}
data "aws_caller_identity" "current" {}

resource "aws_iam_role_policy" "glue_crawler_policy" {
  name = "glue_crawler_policy"
  role = aws_iam_role.glue_crawler_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # ✅ Buckets (raw + processed)
      {
        Effect = "Allow",
        Action = ["s3:GetObject", "s3:ListBucket"],
        Resource = [
          aws_s3_bucket.data_ingestion_bucket.arn,
          "${aws_s3_bucket.data_ingestion_bucket.arn}/*",
          aws_s3_bucket.process_data_bucket.arn,
          "${aws_s3_bucket.process_data_bucket.arn}/*"
        ]
      },
      # ✅ Glue Data Catalog, Database, and Tables
      {
        Effect = "Allow",
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:CreateTable", # <-- Add this
          "glue:UpdateTable",
          "glue:BatchCreatePartition",
          "glue:CreatePartition",
          "glue:BatchGetPartition",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:UpdatePartition"
        ],
        Resource = [
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.glue_catalog_database.name}",
          "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.glue_catalog_database.name}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "glue_crawler_logs_policy" {
  name = "glue-crawler-logs-policy"
  role = aws_iam_role.glue_crawler_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# Glue Crawler for data discovery
resource "aws_glue_crawler" "glue_crawler" {
  database_name = aws_glue_catalog_database.glue_catalog_database.name
  description   = "Crawler to discover data in S3 bucket"
  name          = var.glue_crawler_name
  role          = aws_iam_role.glue_crawler_role.arn

  s3_target {
    path = "s3://${aws_s3_bucket.process_data_bucket.bucket}/processed/latest/"
  }


  schema_change_policy {
    delete_behavior = "LOG"
  }

  configuration = <<EOF
{
  "Version":1.0,
  "Grouping": {
    "TableGroupingPolicy": "CombineCompatibleSchemas"
  }
}
EOF
}

# Glue catalog table
resource "aws_glue_catalog_table" "processed_json_table" {
  name          = var.glue_catalog_table_name
  database_name = aws_glue_catalog_database.glue_catalog_database.name
  table_type    = "EXTERNAL_TABLE"

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.process_data_bucket.bucket}/processed/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "json"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
    }

    columns {
      name = "currency"
      type = "string"
    }
    columns {
      name = "rate"
      type = "double"
    }
    columns {
      name = "date"
      type = "string"
    }
    columns {
      name = "base_currency"
      type = "string"
    }
  }

  parameters = {
    "classification" = "json"
  }
}