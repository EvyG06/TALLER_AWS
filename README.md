# Actividad AWS · Ingeniería de Datos 2026-2 · Universidad EIA

## Integrantes

- Pablo Restrepo
- Evelyn Gómez Aristizábal

## Contenido

| Punto | Tema | Carpeta | Evidencias |
|---|---|---|---|
| 1 | AWS Secrets Manager | [`punto1/`](punto1/README.md) | [`evidencias-1-2-5/`](evidencias-1-2-5/) |
| 2 | Despliegue con Terraform, Boto3 y AWS CLI | [`punto2/`](punto2/README.md) | [`evidencias-1-2-5/`](evidencias-1-2-5/) |
| 3 | Amazon DocumentDB | [`punto3/`](punto3/) | [`evidencias-3-4-6/`](evidencias-3-4-6/) |
| 4 | Amazon Neptune | [`punto4/`](punto4/) | [`evidencias-3-4-6/`](evidencias-3-4-6/) |
| 5 | Amazon Redshift Serverless | [`punto5/`](punto5/README.md) | [`evidencias-1-2-5/`](evidencias-1-2-5/) |
| 6 | AWS Glue Data Catalog y Athena | [`punto6/`](punto6/) | [`evidencias-3-4-6/`](evidencias-3-4-6/) |

Los puntos 1, 2 y 5 se desarrollaron en una sola región, **us-east-2 (Ohio)**. Cada uno tiene su README con conceptos, pasos para reproducir, respuestas de costos y eliminación. Las capturas tienen prefijo `p1-`, `p2-` o `p5-`.

Los scripts de apoyo de los puntos 3, 4 y 6 están en [`scripts/`](scripts/).

## Requisitos

- AWS CLI v2, Terraform ≥ 1.6, Python ≥ 3.9
- `pip install boto3 aws-secretsmanager-caching`
- Perfiles de AWS CLI configurados con `aws configure --profile <nombre>`, región `us-east-2`

## Identidades usadas (puntos 1, 2 y 5)

| Identidad | Uso | Permisos |
|---|---|---|
| `desarrollo_IngDatos` | Persona que prepara y elimina recursos | `AdministratorAccess`. Nunca se usó la cuenta raíz |
| `lector_p1` | Programa del punto 1 | Leer un único secreto |
| `user_cli` | Terraform, Boto3 y CLI del punto 2, programa del punto 5 | Políticas administradas `UserCliTaller` y `UserCliRedshiftP5` |

## Manejo de secretos

- Ningún programa tiene contraseñas en el código. Todas se recuperan de Secrets Manager en tiempo de ejecución.
- RDS (punto 2) y Redshift (punto 5) usan la **administración integrada** de su contraseña en Secrets Manager. El servicio la genera, nadie la escribe.
- Las access keys de IAM viven solo en `~/.aws/credentials`, fuera del repositorio. No se guardan en Secrets Manager porque las herramientas necesitan autenticarse antes de poder leer un secreto.

## Hallazgos durante el taller (puntos 1, 2 y 5)

1. Una variable `AWS_REGION` exportada en la shell tiene prioridad sobre la región del perfil y desvió peticiones a otra región.
2. Las políticas inline de un usuario tienen un límite de 2.048 caracteres. Se usaron políticas administradas.
3. La librería oficial de caché de Secrets Manager necesita `DescribeSecret` además de `GetSecretValue`.
4. Fuera de us-east-1, crear un bucket exige `LocationConstraint`.
5. La consola recuerda la última región usada. Un namespace de Redshift se creó por error en us-east-1 y se recreó por CLI con región explícita.


## Punto 3. Amazon DocumentDB

**Identidades:** región `us-east-1` · usuario IAM `user_cli` · clúster `docdb-taller` / instancia `docdb-taller-1` · usuario `docdbadmin` con contraseña administrada en Secrets Manager (`rds!cluster-...`) · grupos de seguridad `ec2-bastion-sg` (SSH desde la IP del usuario) y `docdb-sg` (27017 solo desde `ec2-bastion-sg`) · grupo de subredes `taller-docdb-subnets` · EC2 `docdb-bastion` (t3.micro, Amazon Linux 2023) · llave `docdb-key` · base `taller_aws`, colección `productos` (10 documentos).

**Hallazgos:**
- DocumentDB no tiene acceso público: para usar Compass y Python desde el computador se necesita una EC2 en la misma VPC y un túnel SSH (`localhost:27017` → clúster:27017), con TLS y el certificado `global-bundle.pem`.
- Compass mostró `Unsupported mechanism [-301]`. La red, el TLS y los grupos de seguridad estaban bien (el servidor sí respondía); el fallo era de autenticación: Compass intentaba `SCRAM-SHA-256` y el clúster aceptaba `SCRAM-SHA-1`. Se resolvió con `authMechanism=SCRAM-SHA-1` en Compass y en pymongo.
- Abrir los grupos de seguridad a `0.0.0.0/0` no solucionó nada y es innecesario.
- Parámetros de conexión requeridos: `tls=true`, `retryWrites=false`, `directConnection=true` y `tlsAllowInvalidHostnames=true` (este último solo porque se entra por `localhost`).
- La contraseña se creó con `--manage-master-user-password` y el programa la lee de Secrets Manager en tiempo de ejecución; no está en el código.

## Punto 4. Amazon Neptune

**Identidades:** clúster `neptune-taller` / instancia `neptune-taller-1` (`db.t4g.medium`, motor ≥ 1.4.6.0) · endpoint público con autenticación IAM · grupo de seguridad `neptune-sg` (8182 solo desde la IP del usuario) · grupo de subredes `taller-neptune-subnets` · cliente `boto3` `neptunedata` con openCypher · grafo de 10 vértices (7 `Estudiante`, 3 `Materia`) y 15 relaciones (6 `AMIGO_DE`, 9 `CURSA`).

**Hallazgos:**
- No hace falta EC2: con el endpoint público, IAM obligatorio y el puerto 8182 abierto solo a la IP del usuario se consulta directo desde el computador, sin instancia adicional. Alternativas: túnel SSH por EC2, VPN o Direct Connect, notebook dentro de la VPC.
- Neptune no tiene usuario ni contraseña, así que no hay secreto de base de datos que guardar; las claves de `user_cli` nunca se guardan en Secrets Manager.
- Se eligió provisionada `db.t4g.medium` sobre Serverless.
- Las 3 consultas recorren relaciones: amigos directos, amigos de amigos (2 saltos) y compañeros por materia compartida. 
- Si hay *timeout*, casi siempre cambió la IP pública y hay que actualizar la regla del puerto 8182.


## Punto 6. AWS Glue Data Catalog

**Identidades:** bucket `taller-glue-<número>` (datos en `datos/ventas/`, resultados de Athena en `athena-results/`) · `ventas.csv` (24 registros) y `ventas_extra.csv` (+6) · base `taller_ventas` · crawler `crawler-ventas` · rol `AWSGlueServiceRole-taller` (política `AWSGlueServiceRole` + `acceso-bucket-taller`, solo lectura de ese bucket) · tablas `ventas` (crawler) y `ventas_manual` (SQL en Athena).

**Hallazgos:**
- El catálogo guarda solo metadatos (esquema, ubicación, formato); los datos siguen en S3.
- Errores del esquema inferido: por ejemplo `fecha` como `string`, columnas `col0…col6` o encabezado leído como dato). 
- Se fijó `UpdateBehavior=LOG` en el crawler para que sus re-ejecuciones no deshagan las correcciones manuales.
- Al agregar un archivo con el mismo esquema, Athena vio los registros nuevos de inmediato (24 → 30), porque lee los archivos directamente; el crawler solo cambia el catálogo si cambia el esquema.
- Crawler vs tabla manual: el crawler infiere el esquema rápido pero puede equivocarse con los tipos y cobra por ejecución; la tabla manual da control total y no genera costo de crawler, pero hay que mantener el esquema a mano.
- No se creó ningún secreto: S3, Glue y Athena se autentican solo con permisos IAM (`user_cli` y el rol del crawler).
- `.gitignore` excluye archivos de estado de Terraform, llaves, archivos de credenciales y estados locales de los scripts.

