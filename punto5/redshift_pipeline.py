import csv
import os
import time

import boto3

PERFIL = os.getenv("AWS_PROFILE", "user_cli")
REGION = "us-east-2"
WORKGROUP = "taller-p5-wg"
NAMESPACE = "taller-p5-ns"
DATABASE = "dev"
CARPETA = os.path.dirname(os.path.abspath(__file__))

s = boto3.Session(profile_name=PERFIL, region_name=REGION)
cuenta = s.client("sts").get_caller_identity()["Account"]
s3 = s.client("s3")
rsd = s.client("redshift-data")
rss = s.client("redshift-serverless")

BUCKET = f"taller-eve-p5-{cuenta}"
SECRET_ARN = rss.get_namespace(namespaceName=NAMESPACE)["namespace"]["adminPasswordSecretArn"]


def ejecutar(sql, nombre):
    """Envia SQL por la Data API, espera a que termine y devuelve el id."""
    sid = rsd.execute_statement(WorkgroupName=WORKGROUP, Database=DATABASE,
                                SecretArn=SECRET_ARN, Sql=sql, StatementName=nombre)["Id"]
    while True:
        d = rsd.describe_statement(Id=sid)
        if d["Status"] in ("FINISHED", "FAILED", "ABORTED"):
            break
        time.sleep(1)
    if d["Status"] != "FINISHED":
        raise SystemExit(f"[{nombre}] {d['Status']}: {d.get('Error')}")
    print(f"[{nombre}] FINISHED en {d['Duration'] / 1e9:.2f} s, filas {d.get('ResultRows', 0)}")
    return sid, d.get("HasResultSet", False)


def resultados(sid):
    r = rsd.get_statement_result(Id=sid)
    cols = [c["name"] for c in r["ColumnMetadata"]]
    filas = [[list(v.values())[0] if v else None for v in fila] for fila in r["Records"]]
    return cols, filas


def subir_archivos():
    try:
        s3.head_bucket(Bucket=BUCKET)
    except s3.exceptions.ClientError:
        s3.create_bucket(Bucket=BUCKET, CreateBucketConfiguration={"LocationConstraint": REGION})
        print("Bucket creado", BUCKET)
    for archivo in ("clientes.csv", "pedidos.csv"):
        s3.upload_file(os.path.join(CARPETA, "datos", archivo), BUCKET, f"datos/{archivo}")
        print(f"Subido s3://{BUCKET}/datos/{archivo}")


DDL = [
    ("drop_pedidos", "DROP TABLE IF EXISTS pedidos;"),
    ("drop_clientes", "DROP TABLE IF EXISTS clientes;"),
    ("crear_clientes", """
        CREATE TABLE clientes (
            cliente_id     INTEGER PRIMARY KEY,
            nombre         VARCHAR(50),
            ciudad         VARCHAR(30),
            segmento       VARCHAR(20),
            fecha_registro DATE
        ) DISTSTYLE ALL;"""),
    ("crear_pedidos", """
        CREATE TABLE pedidos (
            pedido_id      INTEGER PRIMARY KEY,
            cliente_id     INTEGER REFERENCES clientes(cliente_id),
            fecha          DATE,
            categoria      VARCHAR(20),
            cantidad       INTEGER,
            valor_unitario DECIMAL(12,2)
        ) DISTKEY(cliente_id) SORTKEY(fecha);"""),
]

CONSULTAS = {
    "q1_filtro": """
        SELECT pedido_id, fecha, categoria, cantidad, valor_unitario
        FROM pedidos
        WHERE categoria = 'Electronica' AND valor_unitario > 1000000
        ORDER BY valor_unitario DESC;""",
    "q2_union": """
        SELECT p.pedido_id, p.fecha, c.nombre, c.ciudad, p.categoria,
               p.cantidad * p.valor_unitario AS total
        FROM pedidos p
        JOIN clientes c ON c.cliente_id = p.cliente_id
        WHERE c.segmento = 'Empresa'
        ORDER BY total DESC
        LIMIT 10;""",
    "q3_agregacion": """
        SELECT c.ciudad,
               COUNT(*)                                   AS num_pedidos,
               SUM(p.cantidad * p.valor_unitario)         AS ventas_totales,
               ROUND(AVG(p.cantidad * p.valor_unitario))  AS ticket_promedio
        FROM pedidos p
        JOIN clientes c ON c.cliente_id = p.cliente_id
        GROUP BY c.ciudad
        ORDER BY ventas_totales DESC;""",
}


def main():
    print("Secreto usado (solo ARN):", SECRET_ARN)
    subir_archivos()
    for nombre, sql in DDL:
        ejecutar(sql, nombre)
    for tabla in ("clientes", "pedidos"):
        ejecutar(f"""COPY {tabla} FROM 's3://{BUCKET}/datos/{tabla}.csv'
                     IAM_ROLE default FORMAT AS CSV IGNOREHEADER 1 DATEFORMAT 'YYYY-MM-DD';""",
                 f"copy_{tabla}")
    sid, _ = ejecutar("SELECT 'clientes', COUNT(*) FROM clientes UNION ALL SELECT 'pedidos', COUNT(*) FROM pedidos;",
                      "conteo")
    print(resultados(sid))

    os.makedirs(os.path.join(CARPETA, "resultados"), exist_ok=True)
    for nombre, sql in CONSULTAS.items():
        sid, tiene = ejecutar(sql, nombre)
        cols, filas = resultados(sid)
        with open(os.path.join(CARPETA, "resultados", f"{nombre}.csv"), "w", newline="") as f:
            w = csv.writer(f); w.writerow(cols); w.writerows(filas)
        print(" | ".join(cols))
        for fila in filas:
            print(" | ".join(str(x) for x in fila))
        print()


if __name__ == "__main__":
    main()
