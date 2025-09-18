import sys
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext
from pyspark.sql.functions import explode
from pyspark.sql.types import (
    StructType, StructField, StringType, DoubleType, BooleanType, LongType, MapType
)

args = getResolvedOptions(sys.argv, ["JOB_NAME", "RAW_BUCKET", "PROCESSED_BUCKET"])

# safer SparkContext init
sc = SparkContext.getOrCreate()
glueContext = GlueContext(sc)
spark = glueContext.spark_session

job = Job(glueContext)
job.init(args["JOB_NAME"], args)

schema = StructType([
    StructField("success", BooleanType(), True),
    StructField("timestamp", LongType(), True),
    StructField("base", StringType(), True),
    StructField("date", StringType(), True),
    StructField("rates", MapType(StringType(), DoubleType()), True)
])

raw_path = f"s3://{args['RAW_BUCKET']}/raw/"

# IMPORTANT: use multiLine=true if JSON files are pretty-printed
raw_df = (
    spark.read
         .option("multiLine", "true")
         .schema(schema)
         .json(raw_path)
)

print("=== raw schema ===")
raw_df.printSchema()

count = raw_df.count()
print(f"raw_df.count() = {count}")

if count == 0:
    # print sample list of objects (optional) to logs -- helpful for debugging
    print(f"No rows read from {raw_path}. Check S3 object keys and IAM permissions.")
else:
    raw_df.show(5, truncate=False)

    # flatten rates
    df_exploded = raw_df.selectExpr(
        "base as base_currency",
        "date",
        "explode(rates) as (currency, rate)"
    )

    print("=== exploded schema ===")
    df_exploded.printSchema()
    print(f"exploded count = {df_exploded.count()}")

    # write - use overwrite if you want single latest snapshot
    processed_path = f"s3://{args['PROCESSED_BUCKET']}/processed/latest/"

    # if you want a single file: repartition(1) + overwrite
    # df_exploded.repartition(1).write.mode("overwrite").json(processed_path)
    print(f"Wrote processed data to {processed_path}")

job.commit()
