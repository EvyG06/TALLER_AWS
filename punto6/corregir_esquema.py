import os, boto3
glue = boto3.client("glue", region_name=os.getenv("AWS_REGION", "us-east-1"))
DB, TABLA = "taller_ventas", "ventas"
FECHA = os.getenv("FECHA_TIPO", "date")     # si Athena se queja de la fecha: FECHA_TIPO=string
esperado = [("id","bigint"),("fecha",FECHA),("cliente","string"),("ciudad","string"),
            ("producto","string"),("cantidad","int"),("precio","double")]

t = glue.get_table(DatabaseName=DB, Name=TABLA)["Table"]
sd = t["StorageDescriptor"]
for i, c in enumerate(sd["Columns"][:len(esperado)]):
    nombre, tipo = esperado[i]
    if c["Name"] != nombre or c["Type"] != tipo:
        print(f"Corrijo columna {i}: {c['Name']}:{c['Type']}  ->  {nombre}:{tipo}")
        c["Name"], c["Type"] = nombre, tipo
params = dict(t.get("Parameters", {}))
params["skip.header.line.count"] = "1"
glue.update_table(DatabaseName=DB, TableInput={
    "Name": t["Name"], "StorageDescriptor": sd,
    "PartitionKeys": t.get("PartitionKeys", []),
    "TableType": t.get("TableType", "EXTERNAL_TABLE"), "Parameters": params})
print("Tabla actualizada en el catálogo.")
