from pathlib import Path
import pandas as pd
from sqlalchemy import create_engine, text

DATA = Path("data")
engine = create_engine("postgresql+psycopg2://postgres:postgres@localhost:5433/dados")

# arquivo -> (tabela, colunas de data)
TABELAS = {
    "olist_customers_dataset.csv": ("customers", []),
    "olist_sellers_dataset.csv": ("sellers", []),
    "olist_products_dataset.csv": ("products", []),
    "product_category_name_translation.csv": ("category_translation", []),
    "olist_orders_dataset.csv": ("orders", [
        "order_purchase_timestamp", "order_approved_at",
        "order_delivered_carrier_date", "order_delivered_customer_date",
        "order_estimated_delivery_date"]),
    "olist_order_items_dataset.csv": ("order_items", ["shipping_limit_date"]),
    "olist_order_payments_dataset.csv": ("order_payments", []),
    "olist_order_reviews_dataset.csv": ("order_reviews", [
        "review_creation_date", "review_answer_timestamp"]),
}

for arquivo, (tabela, datas) in TABELAS.items():
    df = pd.read_csv(DATA / arquivo, parse_dates=datas)
    df.to_sql(tabela, engine, if_exists="replace", index=False, chunksize=10000)
    print(f"{tabela}: {len(df)} linhas")

# Geolocalização: o arquivo tem ~1 milhão de linhas repetidas por CEP.
# Agregamos para uma linha por prefixo de CEP.
geo = pd.read_csv(DATA / "olist_geolocation_dataset.csv")
geo = (geo.groupby("geolocation_zip_code_prefix")
          .agg(lat=("geolocation_lat", "mean"),
               lng=("geolocation_lng", "mean"),
               cidade=("geolocation_city", "first"),
               estado=("geolocation_state", "first"))
          .reset_index())
geo.to_sql("geolocation", engine, if_exists="replace", index=False)
print(f"geolocation: {len(geo)} linhas")

# Índices para acelerar os joins
with engine.begin() as conn:
    for sql in [
        "CREATE INDEX IF NOT EXISTS ix_orders_id ON orders(order_id)",
        "CREATE INDEX IF NOT EXISTS ix_orders_cust ON orders(customer_id)",
        "CREATE INDEX IF NOT EXISTS ix_items_order ON order_items(order_id)",
        "CREATE INDEX IF NOT EXISTS ix_items_prod ON order_items(product_id)",
        "CREATE INDEX IF NOT EXISTS ix_pay_order ON order_payments(order_id)",
        "CREATE INDEX IF NOT EXISTS ix_rev_order ON order_reviews(order_id)",
        "CREATE INDEX IF NOT EXISTS ix_cust_id ON customers(customer_id)",
    ]:
        conn.execute(text(sql))
print("Concluído.")
