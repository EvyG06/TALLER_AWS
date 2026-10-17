# Punto 5. Amazon Redshift

Región **us-east-2 (Ohio)**.

## 1. Conceptos

Amazon Redshift es un data warehouse columnar de procesamiento masivo en paralelo. Se usa para análisis OLAP, es decir consultas que agregan muchas filas sobre pocas columnas, reportes, BI y tableros.

| Componente (Serverless) | Qué es |
|---|---|
| Namespace | Datos y configuración. Bases de datos, usuarios, credencial de administración, roles IAM, cifrado |
| Workgroup | Cómputo. Capacidad en RPU, red (VPC, subnets, security group) y endpoint |
| RPU | Unidad de cómputo, cada una con 16 GB de memoria |
| Redshift Managed Storage | Almacenamiento cobrado por GB-mes, separado del cómputo |
| Data API | API HTTPS para enviar SQL sin driver ni conexión de red directa |

En la modalidad aprovisionada los componentes equivalentes son el cluster, sus nodos líder y de cómputo, y el tipo de nodo (RA3 o RG).

### Redshift frente a RDS

| | RDS | Redshift |
|---|---|---|
| Tipo de carga | OLTP, muchas transacciones pequeñas | OLAP, pocas consultas grandes |
| Almacenamiento | Por filas | Por columnas, comprimido |
| Consulta típica | Leer o actualizar un pedido por su id | Sumar ventas de millones de pedidos por región y mes |
| Caso | Backend transaccional de una tienda online | Análisis histórico de ventas para BI |

## 2. Elección de modalidad

Según la página oficial de precios, el aprovisionado arranca en USD 0,543 por hora y se cobra todo el tiempo que el cluster esté encendido. Serverless arranca en USD 1,50 por hora (4 RPU × USD 0,375 por RPU-hora) pero se cobra por segundo solo mientras ejecuta consultas, con un mínimo de 60 segundos, y no cobra en inactividad. Además, si la cuenta nunca usó Redshift Serverless, AWS otorga USD 300 de crédito por 90 días.

Para esta práctica el cómputo real es de segundos repartidos en una o dos horas, así que **Serverless con la capacidad base mínima de 4 RPU** es la opción más barata. Se agregó un límite de uso de 2 RPU-hora diarios con acción `deactivate` como protección.

## 3. Arquitectura

```
Python (user_cli) ──PUT──▶ S3 taller-eve-p5-<cuenta>/datos/*.csv
      │
      └── Data API (SecretArn) ──▶ Workgroup taller-p5-wg ── COPY con rol IAM ──▶ lee S3
                                          │
                                     Namespace taller-p5-ns
                                     admin administrado en Secrets Manager
```

El workgroup no es público. El programa nunca abre una conexión de red al data warehouse, usa la Data API, que es un endpoint HTTPS de AWS, y se autentica con el ARN del secreto. Por eso no fue necesario abrir puertos en el security group.

## 4. Pasos para reproducir

### 4.1 Rol IAM para que Redshift lea S3
[`confianza-rol-redshift.json`](confianza-rol-redshift.json) permite que `redshift.amazonaws.com` y `redshift-serverless.amazonaws.com` asuman el rol. [`politica-rol-redshift-s3.json`](politica-rol-redshift-s3.json) solo permite listar y leer el bucket del punto.

```bash
aws iam create-role --role-name rol-redshift-s3-p5 --assume-role-policy-document file://confianza-rol-redshift.json --profile admin
aws iam put-role-policy --role-name rol-redshift-s3-p5 --policy-name LeerBucketP5 --policy-document file://politica.json --profile admin
```

### 4.2 Namespace y workgroup
```bash
aws redshift-serverless create-namespace --namespace-name taller-p5-ns --db-name dev \
  --admin-username taller_admin --manage-admin-password \
  --iam-roles <ARN_ROL> --default-iam-role-arn <ARN_ROL> --region us-east-2 --profile admin
aws redshift-serverless create-workgroup --workgroup-name taller-p5-wg --namespace-name taller-p5-ns \
  --base-capacity 4 --no-publicly-accessible --subnet-ids <subnets> --security-group-ids <sg> \
  --region us-east-2 --profile admin
aws redshift-serverless create-usage-limit --resource-arn <ARN_WORKGROUP> --usage-type serverless-compute \
  --amount 2 --period daily --breach-action deactivate --region us-east-2 --profile admin
```
`--manage-admin-password` hace que Redshift genere la contraseña del administrador y la guarde en el secreto `redshift!taller-p5-ns-taller_admin`. Nadie la escribe ni la ve.

**Hallazgo.** El primer intento se hizo por consola y quedó en us-east-1, porque la consola recuerda la última región usada, y además sin la contraseña en Secrets Manager. Se borró y se recreó por CLI con la región explícita.

### 4.3 Permisos del programa
`user_cli` recibió la política administrada `UserCliRedshiftP5` ([`politica-user-cli-p5.json`](politica-user-cli-p5.json)).

| Permiso | Por qué |
|---|---|
| `s3:PutObject`, `GetObject`, `DeleteObject` en `taller-eve-p5-*/*` | Subir los CSV |
| `redshift-data:ExecuteStatement` sobre workgroups de Ohio | Enviar SQL |
| `redshift-data:DescribeStatement`, `GetStatementResult` | Saber si terminó y traer resultados. Se evalúan por id de sentencia |
| `secretsmanager:GetSecretValue` en `redshift!taller-p5-ns-*` | La Data API lee el secreto con los permisos de quien llama |
| `redshift-serverless:GetNamespace` | Descubrir el ARN del secreto en tiempo de ejecución |

Quien lee S3 durante el `COPY` es Redshift con su propio rol, no `user_cli`.

### 4.4 Ejecutar
```bash
pip install boto3
python punto5/redshift_pipeline.py
```
[`redshift_pipeline.py`](redshift_pipeline.py) sube los archivos, crea las tablas, carga con `COPY`, ejecuta las consultas y guarda los resultados en [`resultados/`](resultados/). La Data API es asíncrona. `execute_statement` devuelve un id de inmediato y el programa consulta `describe_statement` hasta que el estado sea `FINISHED`, `FAILED` o `ABORTED`. Luego `get_statement_result` trae las filas.

## 5. Conjunto de datos

| Archivo | Filas | Columnas |
|---|---|---|
| [`datos/clientes.csv`](datos/clientes.csv) | 15 | cliente_id, nombre, ciudad, segmento, fecha_registro |
| [`datos/pedidos.csv`](datos/pedidos.csv) | 60 | pedido_id, cliente_id, fecha, categoria, cantidad, valor_unitario |

Relación `pedidos.cliente_id → clientes.cliente_id`. Datos sintéticos generados con semilla fija para que sean reproducibles.

Diseño físico. `clientes` usa `DISTSTYLE ALL` porque es pequeña, así se copia a todos los nodos y el JOIN no mueve datos. `pedidos` usa `DISTKEY(cliente_id)` para que el JOIN sea local y `SORTKEY(fecha)` para acelerar filtros por fecha.

### Instrucciones de carga
```sql
COPY clientes FROM 's3://taller-eve-p5-<cuenta>/datos/clientes.csv'
IAM_ROLE default FORMAT AS CSV IGNOREHEADER 1 DATEFORMAT 'YYYY-MM-DD';

COPY pedidos FROM 's3://taller-eve-p5-<cuenta>/datos/pedidos.csv'
IAM_ROLE default FORMAT AS CSV IGNOREHEADER 1 DATEFORMAT 'YYYY-MM-DD';
```
Resultado de carga, 15 clientes y 60 pedidos.

## 6. Consultas y resultados

### Q1. Filtro
**Pregunta.** ¿Qué pedidos de electrónica tienen un valor unitario mayor a 1 millón?

```sql
SELECT pedido_id, fecha, categoria, cantidad, valor_unitario
FROM pedidos
WHERE categoria = 'Electronica' AND valor_unitario > 1000000
ORDER BY valor_unitario DESC;
```
**Resultado.** 14 pedidos ([`resultados/q1_filtro.csv`](resultados/q1_filtro.csv)). El mayor es el pedido 27, 3 unidades a 2.284.000.

**Interpretación.** 14 de los 20 pedidos de electrónica superan el millón por unidad. La categoría es de alto valor unitario y cualquier variación en su volumen mueve mucho las ventas totales.

### Q2. Unión
**Pregunta.** ¿Cuáles son los 10 pedidos de mayor valor hechos por clientes empresariales, y de qué ciudad son?

```sql
SELECT p.pedido_id, p.fecha, c.nombre, c.ciudad, p.categoria,
       p.cantidad * p.valor_unitario AS total
FROM pedidos p
JOIN clientes c ON c.cliente_id = p.cliente_id
WHERE c.segmento = 'Empresa'
ORDER BY total DESC
LIMIT 10;
```
**Resultado.** [`resultados/q2_union.csv`](resultados/q2_union.csv). El mayor es el pedido 27 de Felipe (Barranquilla) por 6.852.000.

**Interpretación.** Solo 5 de los 15 clientes son empresas, y Felipe aparece en 5 de los 10 pedidos empresariales más grandes. Hay concentración en un solo cliente, que es un riesgo comercial si se pierde.

### Q3. Agregación
**Pregunta.** ¿Cuánto vende cada ciudad, con cuántos pedidos y qué ticket promedio?

```sql
SELECT c.ciudad,
       COUNT(*) AS num_pedidos,
       SUM(p.cantidad * p.valor_unitario) AS ventas_totales,
       ROUND(AVG(p.cantidad * p.valor_unitario)) AS ticket_promedio
FROM pedidos p
JOIN clientes c ON c.cliente_id = p.cliente_id
GROUP BY c.ciudad
ORDER BY ventas_totales DESC;
```
**Resultado** ([`resultados/q3_agregacion.csv`](resultados/q3_agregacion.csv))

| Ciudad | Pedidos | Ventas | Ticket promedio |
|---|---|---|---|
| Pereira | 10 | 22.606.000 | 2.260.600 |
| Barranquilla | 13 | 17.018.000 | 1.309.077 |
| Bucaramanga | 10 | 12.979.000 | 1.297.900 |
| Bogotá | 7 | 11.382.000 | 1.626.000 |
| Medellín | 5 | 10.254.000 | 2.050.800 |
| Manizales | 9 | 9.693.000 | 1.077.000 |
| Cali | 6 | 8.012.000 | 1.335.333 |

**Interpretación.** Pereira lidera en ventas con solo 2 clientes, gracias al ticket promedio más alto. Barranquilla tiene más pedidos pero un ticket menor, vende por volumen. Medellín tiene pocos pedidos pero ticket alto. Bogotá es la ciudad con más clientes (3) y aun así queda cuarta, lo que sugiere clientes de menor compra.

### Query Editor v2
Se puede inspeccionar la base desde la consola, Redshift → Query editor v2 → conexión al workgroup `taller-p5-wg` con *AWS Secrets Manager* como método de autenticación. No requiere abrir red porque la consola usa la misma Data API. No se configuró conexión desde un cliente SQL local, que exigiría workgroup público y una regla de entrada al puerto 5439 desde la IP propia.

## 7. Costos

| Concepto | Cómo se cobra | Esta práctica |
|---|---|---|
| Cómputo Serverless | RPU-hora por segundo, mínimo 60 s por período activo, nada en inactividad | 4 RPU × USD 0,375 × 60/3600 ≈ USD 0,025 por ejecución del pipeline |
| Almacenamiento (RMS) | GB-mes, USD 0,024 en N. Virginia según la página oficial | Pocos KB, prácticamente 0 |
| Secreto `redshift!` | USD 0,40 al mes prorrateado + USD 0,05 por 10.000 llamadas | ≈ USD 0,001 por hora |
| S3 | Almacenamiento y peticiones estándar | Prácticamente 0 |
| Transferencia S3 a Redshift | Sin costo dentro de la misma región | 0 |

El precio por RPU-hora y por GB-mes publicado como ejemplo corresponde a N. Virginia. Verificar el valor de Ohio en la calculadora de AWS.

**¿Qué modalidad cuesta menos?** Serverless, porque esta práctica tiene segundos de cómputo real y el aprovisionado cobraría cada hora encendido aunque no se use.

**¿Qué sigue cobrando después de las consultas?** El almacenamiento administrado de las tablas, el secreto de administración, los archivos en S3, los snapshots manuales y los puntos de recuperación de más de 24 horas. El workgroup inactivo no cobra cómputo. Por eso al terminar se eliminan workgroup, namespace, bucket y rol.

## 8. Evidencias

| Archivo | Contenido |
|---|---|
| `p5-00-hallazgo-namespace-us-east-1.png` | Primer namespace creado por error en us-east-1 |
| `p5-05-pipeline.png` | Ejecución completa del programa |
| `p5-07a-eliminacion-redshift.png` | Borrado de workgroup y namespace |
| `p5-07b-eliminacion-s3-iam.png` | Borrado de bucket, rol y política |
| `p5-07c-verificacion-eliminacion.png` | Listados vacíos y rol inexistente |

Salidas de verificación registradas en texto

```
# Rol de Redshift
{ "Service": ["redshift-serverless.amazonaws.com", "redshift.amazonaws.com"] }
{ "PolicyNames": ["LeerBucketP5"] }

# Namespace y workgroup en us-east-2
Admin       taller_admin
Secreto     arn:aws:secretsmanager:us-east-2:<cuenta>:secret:redshift!taller-p5-ns-taller_admin-YUCuWV
RolDefault  arn:aws:iam::<cuenta>:role/rol-redshift-s3-p5
BaseRPU 4   Publico false
Límite      2 daily deactivate
```

## 9. Eliminación

```bash
aws redshift-serverless delete-workgroup --workgroup-name taller-p5-wg --region us-east-2 --profile admin
aws redshift-serverless delete-namespace --namespace-name taller-p5-ns --region us-east-2 --profile admin
aws s3 rm s3://taller-eve-p5-<cuenta> --recursive --profile user_cli
aws s3api delete-bucket --bucket taller-eve-p5-<cuenta> --profile user_cli
```
Al borrar el namespace, Redshift elimina también el secreto administrado.

## Fuentes
- Amazon Redshift pricing, https://aws.amazon.com/redshift/pricing/
- Amazon Redshift Management Guide, Data API y Redshift Serverless, https://docs.aws.amazon.com/redshift/latest/mgmt/
