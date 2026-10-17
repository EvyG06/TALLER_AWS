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
- `.gitignore` excluye archivos de estado de Terraform, llaves, archivos de credenciales y estados locales de los scripts.
- Las capturas se revisaron para que no muestren access keys. En una se tapó la Access Key ID.

## Hallazgos durante el taller (puntos 1, 2 y 5)

1. Una variable `AWS_REGION` exportada en la shell tiene prioridad sobre la región del perfil y desvió peticiones a otra región.
2. Las políticas inline de un usuario tienen un límite de 2.048 caracteres. Se usaron políticas administradas.
3. La librería oficial de caché de Secrets Manager necesita `DescribeSecret` además de `GetSecretValue`.
4. Fuera de us-east-1, crear un bucket exige `LocationConstraint`.
5. La consola recuerda la última región usada. Un namespace de Redshift se creó por error en us-east-1 y se recreó por CLI con región explícita.
