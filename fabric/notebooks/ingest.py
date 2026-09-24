# Fabric notebook source
# METADATA ********************
# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {
# META     "lakehouse": {
# META       "default_lakehouse": "__LAKEHOUSE_ID__",
# META       "default_lakehouse_name": "__LAKEHOUSE_NAME__",
# META       "default_lakehouse_workspace_id": "__WORKSPACE_ID__"
# META     }
# META   }
# META }
# CELL ********************

from pyspark.sql import functions as F
from pyspark.sql.types import (
    ArrayType,
    BooleanType,
    DecimalType,
    IntegerType,
    StringType,
    StructField,
    StructType,
    TimestampType,
)

spark.conf.set("spark.sql.parquet.vorder.enabled", "true")
spark.conf.set("spark.microsoft.delta.optimizeWrite.enabled", "true")

RAW = "Files/raw"

product_schema = StructType(
    [
        StructField("product_key", StringType(), False),
        StructField("name", StringType(), False),
        StructField("range_key", StringType(), True),
        StructField("description", StringType(), True),
    ]
)
customer_schema = StructType(
    [
        StructField("customer_key", StringType(), False),
        StructField("name", StringType(), False),
        StructField("maintenance_contract", StringType(), True),
        StructField("sla_response_minutes", IntegerType(), True),
        StructField("sla_resolution_minutes", IntegerType(), True),
        StructField("equipment_count", IntegerType(), True),
    ]
)
installed_base_schema = StructType(
    [
        StructField("customer_key", StringType(), False),
        StructField("product_key", StringType(), False),
        StructField("serial_number", StringType(), True),
        StructField("installed_at", TimestampType(), True),
        StructField("status", StringType(), True),
    ]
)
range_schema = StructType(
    [
        StructField("range_key", StringType(), False),
        StructField("name", StringType(), False),
        StructField("description", StringType(), True),
    ]
)
document_schema = StructType(
    [
        StructField("document_key", StringType(), False),
        StructField("product_key", StringType(), True),
        StructField("document_type", StringType(), False),
        StructField("title", StringType(), False),
        StructField("source_path", StringType(), False),
    ]
)
party_schema = StructType(
    [
        StructField("key", StringType(), False),
        StructField("customer_key", StringType(), True),
        StructField("name", StringType(), False),
        StructField("email", StringType(), True),
        StructField("phone", StringType(), True),
    ]
)
ticket_schema = StructType(
    [
        StructField("ticket_id", StringType(), False),
        StructField(
            "client",
            StructType([StructField("code", StringType(), False)]),
            False,
        ),
        StructField(
            "produit",
            StructType([StructField("reference", StringType(), True)]),
            True,
        ),
        StructField("contact_key", StringType(), True),
        StructField("agent_key", StringType(), True),
        StructField("objet", StringType(), False),
        StructField("description", StringType(), True),
        StructField("categorie", StringType(), True),
        StructField("priorite", StringType(), False),
        StructField("statut", StringType(), False),
        StructField("cree_le", StringType(), False),
        StructField("premiere_reponse_le", StringType(), True),
        StructField("clos_le", StringType(), True),
        StructField(
            "sla",
            StructType(
                [
                    StructField("respecte", BooleanType(), True),
                    StructField("cible_minutes", IntegerType(), True),
                    StructField("reel_minutes", IntegerType(), True),
                ]
            ),
            True,
        ),
        StructField(
            "couts",
            StructType(
                [
                    StructField("pieces_ht", DecimalType(12, 2), True),
                    StructField("main_oeuvre_ht", DecimalType(12, 2), True),
                    StructField("total_ht", DecimalType(12, 2), True),
                ]
            ),
            True,
        ),
        StructField("donnees_fictives", BooleanType(), False),
        StructField("csat", DecimalType(3, 2), True),
        StructField("csat_comment", StringType(), True),
        StructField("tags", ArrayType(StringType()), True),
        StructField(
            "conversation",
            ArrayType(
                StructType(
                    [
                        StructField("message_id", StringType(), False),
                        StructField("timestamp", StringType(), False),
                        StructField("auteur", StringType(), True),
                        StructField("corps", StringType(), True),
                    ]
                )
            ),
            True,
        ),
        StructField(
            "pieces",
            ArrayType(
                StructType(
                    [
                        StructField("reference", StringType(), False),
                        StructField("quantite", IntegerType(), False),
                        StructField("cout_unitaire_ht", DecimalType(12, 2), True),
                    ]
                )
            ),
            True,
        ),
        StructField(
            "escalades",
            ArrayType(
                StructType(
                    [
                        StructField("niveau", StringType(), True),
                        StructField("timestamp", StringType(), False),
                        StructField("motif", StringType(), True),
                    ]
                )
            ),
            True,
        ),
    ]
)


def write_table(frame, name):
    frame.write.mode("overwrite").option("overwriteSchema", "true").format(
        "delta"
    ).saveAsTable(name)


dim_product = (
    spark.read.schema(product_schema).option("header", True).csv(f"{RAW}/products.csv")
)
dim_range = (
    spark.read.schema(range_schema).option("header", True).csv(f"{RAW}/ranges.csv")
)
dim_document = (
    spark.read.schema(document_schema)
    .option("header", True)
    .csv(f"{RAW}/documents.csv")
)
dim_customer = (
    spark.read.schema(customer_schema)
    .option("header", True)
    .csv(f"{RAW}/customers.csv")
)
bridge_installed_base = (
    spark.read.schema(installed_base_schema)
    .option("header", True)
    .csv(f"{RAW}/installed-base.csv")
)
contacts = (
    spark.read.schema(party_schema).option("header", True).csv(f"{RAW}/contacts.csv")
)
agents = spark.read.schema(party_schema).option("header", True).csv(f"{RAW}/agents.csv")
raw_tickets = spark.read.schema(ticket_schema).json(f"{RAW}/tickets-savoye.jsonl")

for schema_name in ("bronze", "silver", "gold"):
    spark.sql(f"CREATE SCHEMA IF NOT EXISTS {schema_name}")
write_table(raw_tickets, "bronze.ticket_raw")
write_table(dim_product, "bronze.product_raw")
write_table(dim_customer, "bronze.customer_raw")
write_table(bridge_installed_base, "bronze.installed_base_raw")

fact_ticket = raw_tickets.select(
    "ticket_id",
    F.col("client.code").alias("customer_key"),
    F.col("produit.reference").alias("product_key"),
    "contact_key",
    "agent_key",
    F.col("objet").alias("subject"),
    "description",
    F.col("categorie").alias("category"),
    F.col("priorite").alias("priority"),
    F.col("statut").alias("status"),
    F.to_timestamp("cree_le").alias("created_at"),
    F.to_timestamp("premiere_reponse_le").alias("first_response_at"),
    F.to_timestamp("clos_le").alias("closed_at"),
    F.col("sla.respecte").alias("is_sla_met"),
    F.col("sla.cible_minutes").alias("sla_target_minutes"),
    F.col("sla.reel_minutes").alias("sla_actual_minutes"),
    F.col("couts.pieces_ht").alias("parts_cost_eur"),
    F.col("couts.main_oeuvre_ht").alias("labour_cost_eur"),
    F.col("couts.total_ht").alias("total_cost_eur"),
    F.col("donnees_fictives").alias("is_mock_data"),
    F.size("conversation").alias("message_count"),
    "csat",
    F.lit(None).cast("string").alias("csat_comment"),
).withColumns(
    {
        "created_date_key": F.date_format("created_at", "yyyyMMdd").cast("int"),
        "closed_date_key": F.date_format("closed_at", "yyyyMMdd").cast("int"),
        "created_year": F.year("created_at"),
        "created_month": F.month("created_at"),
    }
)

fact_ticket_message = raw_tickets.select(
    "ticket_id", F.posexplode_outer("conversation").alias("message_order", "message")
).select(
    "ticket_id",
    "message_order",
    F.col("message.message_id").alias("message_id"),
    F.to_timestamp("message.timestamp").alias("message_at"),
    F.col("message.auteur").alias("author_type"),
    F.lit(None).cast("string").alias("message_body"),
)
fact_part_consumption = raw_tickets.select(
    "ticket_id", F.explode_outer("pieces").alias("part")
).select(
    "ticket_id",
    F.col("part.reference").alias("part_key"),
    F.col("part.quantite").alias("quantity"),
    F.col("part.cout_unitaire_ht").alias("unit_cost_eur"),
)
fact_ticket_escalation = raw_tickets.select(
    "ticket_id", F.posexplode_outer("escalades").alias("escalation_order", "escalation")
).select(
    "ticket_id",
    "escalation_order",
    F.col("escalation.niveau").alias("level"),
    F.to_timestamp("escalation.timestamp").alias("escalated_at"),
    F.col("escalation.motif").alias("reason"),
)
bridge_ticket_tag = raw_tickets.select(
    "ticket_id", F.explode_outer("tags").alias("tag")
)
date_bounds = fact_ticket.select(
    F.min("created_at").cast("date").alias("min_date"),
    F.max(F.coalesce("closed_at", "created_at")).cast("date").alias("max_date"),
).first()
dim_date = spark.sql(
    "SELECT explode(sequence("
    f"date'{date_bounds.min_date}', date'{date_bounds.max_date}', interval 1 day"
    ")) AS calendar_date"
).select(
    F.date_format("calendar_date", "yyyyMMdd").cast("int").alias("date_key"),
    "calendar_date",
    F.year("calendar_date").alias("year"),
    F.month("calendar_date").alias("month"),
    F.dayofmonth("calendar_date").alias("day"),
)

write_table(dim_product, "gold.dim_product")
write_table(dim_range, "gold.dim_range")
write_table(dim_customer, "gold.dim_customer")
write_table(dim_document, "gold.dim_document")
write_table(dim_date, "gold.dim_date")
write_table(
    contacts.select(
        F.col("key").alias("contact_key"),
        "customer_key",
        "name",
        F.when(
            F.instr("email", "@") > 0,
            F.concat(F.lit("***@"), F.element_at(F.split("email", "@"), -1)),
        ).alias("email_masked"),
        F.when(
            F.length("phone") >= 4,
            F.concat(F.lit("*******"), F.substring("phone", -4, 4)),
        ).alias("phone_masked"),
    ),
    "silver.dim_customer_contact",
)
write_table(agents.select(F.col("key").alias("agent_key"), "name"), "gold.dim_agent")
write_table(bridge_installed_base, "gold.bridge_installed_base")
write_table(fact_ticket, "gold.fact_ticket")
write_table(fact_ticket_message, "silver.fact_ticket_message")
write_table(fact_part_consumption, "gold.fact_part_consumption")
write_table(fact_ticket_escalation, "gold.fact_ticket_escalation")
write_table(bridge_ticket_tag, "gold.bridge_ticket_tag")

checks = {
    "ticket_customer_fk": fact_ticket.join(
        dim_customer, "customer_key", "left_anti"
    ).count(),
    "ticket_product_fk": fact_ticket.where(F.col("product_key").isNotNull())
    .join(dim_product, "product_key", "left_anti")
    .count(),
    "installed_product": fact_ticket.where(F.col("product_key").isNotNull())
    .join(
        bridge_installed_base.select("customer_key", "product_key"),
        ["customer_key", "product_key"],
        "left_anti",
    )
    .count(),
    "cost_total": fact_ticket.where(
        F.abs(
            F.coalesce("parts_cost_eur", F.lit(0))
            + F.coalesce("labour_cost_eur", F.lit(0))
            - F.coalesce("total_cost_eur", F.lit(0))
        )
        > F.lit(0.01)
    ).count(),
    "sla_flag": fact_ticket.where(
        F.col("is_sla_met")
        != (F.col("sla_actual_minutes") <= F.col("sla_target_minutes"))
    ).count(),
    "chronology": fact_ticket.where(
        (F.col("first_response_at") < F.col("created_at"))
        | (F.col("closed_at") < F.col("created_at"))
    ).count(),
    "mock_message_minimum": fact_ticket.where(
        F.col("is_mock_data") & (F.col("message_count") < 4)
    ).count(),
}

actual_messages = fact_ticket_message.groupBy("ticket_id").count()
checks["message_count"] = (
    fact_ticket.join(actual_messages, "ticket_id")
    .where(F.col("message_count") != F.col("count"))
    .count()
)
actual_equipment = bridge_installed_base.groupBy("customer_key").count()
checks["equipment_count"] = (
    dim_customer.join(actual_equipment, "customer_key")
    .where(F.col("equipment_count") != F.col("count"))
    .count()
)
failures = {name: count for name, count in checks.items() if count}
if failures:
    raise ValueError(f"Fabric data-quality checks failed: {failures}")

baseline = {
    "tickets": fact_ticket.count(),
    "messages": fact_ticket_message.count(),
    "parts": fact_part_consumption.where(F.col("part_key").isNotNull()).count(),
    "escalations": fact_ticket_escalation.where(
        F.col("escalated_at").isNotNull()
    ).count(),
    "csat": fact_ticket.where(F.col("csat").isNotNull()).count(),
}
expected = {
    "tickets": 2851,
    "messages": 12675,
    "parts": 1675,
    "escalations": 357,
    "csat": 2035,
}
if baseline != expected:
    raise ValueError(f"Mock baseline mismatch: expected {expected}, got {baseline}")
measures = fact_ticket.agg(
    (F.avg(F.col("is_sla_met").cast("double")) * 100).alias("sla_percent"),
    F.avg("csat").alias("average_csat"),
    F.sum("total_cost_eur").alias("total_cost_eur"),
).first()
if (
    round(measures.sla_percent, 1) != 89.4
    or round(float(measures.average_csat), 2) != 4.13
    or round(float(measures.total_cost_eur), 2) != 3488507.00
):
    raise ValueError(f"Mock aggregate baseline mismatch: {measures.asDict()}")

# The server-side write tool creates one immutable JSON file per idempotency key.
# Rebuild the Gold ticket table from the mock baseline plus that durable inbox.
try:
    ticket_inbox = spark.read.json(f"{RAW}/support-ticket-inbox/*.json")
except Exception:
    ticket_inbox = None
if ticket_inbox is not None:
    created_tickets = ticket_inbox.select(
        "ticket_id",
        "customer_key",
        "product_key",
        "contact_key",
        F.lit(None).cast("string").alias("agent_key"),
        "subject",
        "description",
        "category",
        "priority",
        "status",
        F.to_timestamp("created_at").alias("created_at"),
        F.lit(None).cast("timestamp").alias("first_response_at"),
        F.lit(None).cast("timestamp").alias("closed_at"),
        F.lit(None).cast("boolean").alias("is_sla_met"),
        F.lit(None).cast("int").alias("sla_target_minutes"),
        F.lit(None).cast("int").alias("sla_actual_minutes"),
        F.lit(None).cast("decimal(12,2)").alias("parts_cost_eur"),
        F.lit(None).cast("decimal(12,2)").alias("labour_cost_eur"),
        F.lit(None).cast("decimal(12,2)").alias("total_cost_eur"),
        F.lit(False).alias("is_mock_data"),
        F.lit(0).alias("message_count"),
        F.lit(None).cast("decimal(3,2)").alias("csat"),
        F.lit(None).cast("string").alias("csat_comment"),
        F.date_format("created_at", "yyyyMMdd").cast("int").alias("created_date_key"),
        F.lit(None).cast("int").alias("closed_date_key"),
        F.year("created_at").alias("created_year"),
        F.month("created_at").alias("created_month"),
    )
    write_table(
        fact_ticket.unionByName(created_tickets).dropDuplicates(["ticket_id"]),
        "gold.fact_ticket",
    )
