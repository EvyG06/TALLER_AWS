import json, os
import boto3

REGION = os.getenv("AWS_REGION", "us-east-1")
ENDPOINT = os.environ["NEPTUNE_ENDPOINT"]

# El cliente neptunedata firma las peticiones con IAM (SigV4) automáticamente
client = boto3.client("neptunedata", region_name=REGION, endpoint_url=f"https://{ENDPOINT}:8182")

def q(query, params=None):
    kw = {"openCypherQuery": query}
    if params:
        kw["parameters"] = json.dumps(params)
    return client.execute_open_cypher_query(**kw)["results"]

estudiantes = ["Ana", "Bruno", "Carla", "Diego", "Elena", "Felipe", "Gabriela"]
materias = ["BasesDatos", "Redes", "Estructuras"]
amigos = [("Ana","Bruno"),("Ana","Carla"),("Bruno","Diego"),
          ("Carla","Elena"),("Diego","Felipe"),("Elena","Gabriela")]
cursa = [("Ana","BasesDatos"),("Ana","Redes"),("Bruno","BasesDatos"),
         ("Carla","Estructuras"),("Diego","Redes"),("Diego","BasesDatos"),
         ("Elena","Estructuras"),("Felipe","Redes"),("Gabriela","Estructuras")]

for n in estudiantes:
    q("MERGE (:Estudiante {nombre: $n})", {"n": n})
for m in materias:
    q("MERGE (:Materia {nombre: $m})", {"m": m})
for a, b in amigos:
    q("MATCH (x:Estudiante {nombre:$a}), (y:Estudiante {nombre:$b}) MERGE (x)-[:AMIGO_DE]->(y)",
      {"a": a, "b": b})
for e, m in cursa:
    q("MATCH (x:Estudiante {nombre:$e}), (y:Materia {nombre:$m}) MERGE (x)-[:CURSA]->(y)",
      {"e": e, "m": m})

print("Vértices:", q("MATCH (n) RETURN count(n) AS total"))
print("Relaciones:", q("MATCH ()-[r]->() RETURN count(r) AS total"))

print("\n1) Amigos directos de Ana")
print(q("MATCH (a:Estudiante {nombre:'Ana'})-[:AMIGO_DE]-(f:Estudiante) RETURN f.nombre AS amigo"))

print("\n2) Amigos de amigos de Ana (2 saltos)")
print(q("""
MATCH (a:Estudiante {nombre:'Ana'})-[:AMIGO_DE]-(:Estudiante)-[:AMIGO_DE]-(fof:Estudiante)
WHERE fof.nombre <> 'Ana' AND NOT (a)-[:AMIGO_DE]-(fof)
RETURN DISTINCT fof.nombre AS sugerencia
"""))

print("\n3) Compañeros de Ana por materia")
print(q("""
MATCH (a:Estudiante {nombre:'Ana'})-[:CURSA]->(m:Materia)<-[:CURSA]-(c:Estudiante)
WHERE c.nombre <> a.nombre
RETURN m.nombre AS materia, collect(c.nombre) AS companeros
"""))
