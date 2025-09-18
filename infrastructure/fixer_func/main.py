import json
import boto3
import urllib.request
import os
from datetime import datetime

# Initialize AWS clients
s3 = boto3.client("s3")
ssm = boto3.client("ssm")
glue_client = boto3.client("glue")

def get_parameter(name):
    """Get parameter from SSM Parameter Store"""
    response = ssm.get_parameter(Name=name, WithDecryption=True)
    return response['Parameter']['Value']

def handler(event, context):
    try:
        # 🔹 Resolve all parameters from SSM
        api_key = get_parameter(os.getenv("API_KEY"))
        api_url = get_parameter(os.getenv("API_URL"))
        raw_bucket = get_parameter(os.getenv("RAW_BUCKET"))
        processed_bucket = get_parameter(os.getenv("PROCESSED_BUCKET"))
        glue_job_name = get_parameter(os.getenv("GLUE_JOB_NAME"))

        # 🔹 Fetch data from Fixer API
        url = f"{api_url}?access_key={api_key}"
        with urllib.request.urlopen(url) as response:
            data = json.loads(response.read().decode())

        if not data.get("success", False):
            raise Exception(f"Fixer API error: {data.get('error')}")

        # 🔹 Generate timestamp and store in S3
        timestamp = datetime.utcnow().strftime('%Y-%m-%d_%H-%M-%S')
        file_key = f"raw/fixer_data_{timestamp}.json"

        s3.put_object(
            Bucket=raw_bucket,
            Key=file_key,
            Body=json.dumps(data, indent=2),
            ContentType='application/json'
        )
        print(f"✅ Stored raw data: s3://{raw_bucket}/{file_key}")

        # 🔹 Trigger Glue ETL Job
        glue_response = glue_client.start_job_run(
            JobName=glue_job_name,
            Arguments={
                '--RAW_BUCKET': raw_bucket,
                '--PROCESSED_BUCKET': processed_bucket,
                '--source-s3-path': f"s3://{raw_bucket}/{file_key}",
                '--execution-timestamp': timestamp
            }
        )
        job_run_id = glue_response['JobRunId']
        print(f"🚀 Started Glue job: {glue_job_name}, RunId={job_run_id}")

        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": "Data ingestion + Glue ETL started successfully",
                "s3_location": f"s3://{raw_bucket}/{file_key}",
                "glue_job_run_id": job_run_id,
                "timestamp": timestamp,
                "records_processed": len(data.get('rates', {}))
            })
        }

    except Exception as e:
        error_msg = f"Pipeline failed: {str(e)}"
        print(error_msg)
        return {"statusCode": 500, "body": json.dumps({"error": error_msg})}
