import argparse, os, time, boto3

REGION = os.getenv("AWS_REGION", "us-east-1")
BUCKET = os.environ["BUCKET_GLUE"]
DB = "taller_ventas"
SALIDA = f"s3://{BUCKET}/athena-results/"
athena = boto3.client("athena", region_name=REGION)

def correr(sql):
    print("\n>>", " ".join(sql.split()))
    qid = athena.start_query_execution(
        QueryString=sql, QueryExecutionContext={"Database": DB},
        ResultConfiguration={"OutputLocation": SALIDA})["QueryExecutionId"]
    while True:
        ex = athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]
        estado = ex["Status"]["State"]
        if estado in ("SUCCEEDED", "FAILED", "CANCELLED"):
            break
        time.sleep(1)
    if estado != "SUCCEEDED":
        print("ERROR:", ex["Status"].get("StateChangeReason")); return
    try:
        for fila in athena.get_query_results(QueryExecutionId=qid)["ResultSet"]["Rows"]:
            print(" | ".join(c.get("VarCharValue", "") for c in fila["Data"]))
    except Exception:
        print("(sentencia sin resultados: OK)")
    st = ex["Statistics"]
    print(f"-- bytes escaneados: {st['DataScannedInBytes']} | tiempo: {st['TotalExecutionTimeInMillis']} ms")

CONSULTAS = [
    "SELECT COUNT(*) AS total FROM ventas",
    "SELECT id, cliente, producto, cantidad, precio FROM ventas WHERE ciudad = 'Medellin' AND precio > 300 ORDER BY precio DESC",
    "SELECT ciudad, COUNT(*) AS num_ventas, SUM(cantidad) AS unidades, ROUND(SUM(cantidad * precio), 2) AS total_ventas FROM ventas GROUP BY ciudad ORDER BY total_ventas DESC",
]
ap = argparse.ArgumentParser(); ap.add_argument("--sql")
a = ap.parse_args()
for s in ([a.sql] if a.sql else CONSULTAS):
    correr(s)
