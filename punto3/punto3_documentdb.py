import json, os
import boto3
from pymongo import MongoClient

REGION = os.getenv("AWS_REGION", "us-east-1")
SECRET_ARN = os.environ["DOCDB_SECRET_ARN"]
CA_FILE = os.path.expanduser("~/certs/global-bundle.pem")

# 1) Recuperar usuario/contraseña desde Secrets Manager (nada escrito en el código)
sm = boto3.client("secretsmanager", region_name=REGION)
cred = json.loads(sm.get_secret_value(SecretId=SECRET_ARN)["SecretString"])

# 2) Conectar por el túnel SSH (localhost:27017)
client = MongoClient(
    host="localhost", port=27017,
    username=cred["username"], password=cred["password"],
    authSource="admin", authMechanism="SCRAM-SHA-1",
    tls=True, tlsCAFile=CA_FILE, tlsAllowInvalidHostnames=True,
    directConnection=True, retryWrites=False,
)
print("Conectado. Bases:", client.list_database_names())

# 3) Base, colección y 10 documentos
col = client["taller_aws"]["productos"]
col.delete_many({})
datos = [
    ("Portátil", "Electrónica", 2500, 12), ("Mouse", "Electrónica", 60, 80),
    ("Teclado", "Electrónica", 120, 45),   ("Monitor", "Electrónica", 900, 20),
    ("Silla", "Muebles", 450, 15),         ("Escritorio", "Muebles", 700, 8),
    ("Lámpara", "Muebles", 90, 30),        ("Cuaderno", "Papelería", 8, 200),
    ("Lápiz", "Papelería", 2, 500),        ("Marcador", "Papelería", 5, 300),
]
col.insert_many([{"nombre": n, "categoria": c, "precio": p, "stock": s} for n, c, p, s in datos])
print("Insertados:", col.count_documents({}))

# 4) Búsqueda con filtro
print("\nFiltro: Electrónica con precio > 100")
for d in col.find({"categoria": "Electrónica", "precio": {"$gt": 100}}, {"_id": 0}):
    print(d)

# 5) Ordenación
print("\nOrdenación: todos por precio descendente (top 5)")
for d in col.find({}, {"_id": 0}).sort("precio", -1).limit(5):
    print(d)

# 6) Agregación
print("\nAgregación: por categoría, cantidad, precio promedio y stock total")
pipeline = [
    {"$group": {"_id": "$categoria", "productos": {"$sum": 1},
                "precio_promedio": {"$avg": "$precio"}, "stock_total": {"$sum": "$stock"}}},
    {"$sort": {"precio_promedio": -1}},
]
for d in col.aggregate(pipeline):
    print(d)
