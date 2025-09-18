variable "ssm_fixer_api" {
  description = "SSM Parameter for Fixer API Key"
  type        = string
  default     = "8c3135572a5e8539fe02b2d0fc66dbb3"
}
variable "ssm_fixer_api_url" {
  description = "SSM Parameter for Fixer API URL"
  type        = string
  default     = "http://data.fixer.io/api/latest"
}
variable "lambda_function_name" {
  description = "Lambda function name"
  type        = string
  default     = "data-ingestion-function"
}
variable "s3_raw_bucket_name" {
  description = "S3 Bucket name"
  type        = string
  default     = "data-ingestion-bucket9125"
}
variable "s3_processed_bucket_name" {
  description = "S3 Bucket name"
  type        = string
  default     = "data-processed-bucket9125"
}
variable "glue_job_name" {
  description = "Glue Job name"
  type        = string
  default     = "data-processing-job"
}
variable "glue_database_name" {
  description = "Glue Database name"
  type        = string
  default     = "data_pipeline_db"
}
variable "glue_crawler_name" {
  description = "Glue Crawler name"
  type        = string
  default     = "data-pipeline-crawler"
}
variable "glue_catalog_table_name" {
  description = "Glue Catalog Table name"
  type        = string
  default     = "data_pipeline_table"
}
variable "region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}