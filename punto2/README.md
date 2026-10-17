# Punto 2. Despliegue con Terraform, Boto3 y AWS CLI

Región **us-east-2 (Ohio)**. Los tres métodos crean los mismos recursos, uno después del otro, y cada versión se eliminó antes de iniciar la siguiente.

| Recurso | Configuración | Por qué |
|---|---|---|
| Bucket S3 | `taller-eve-p2-<método>-<cuenta>`, vacío | Los nombres de bucket son globales, el número de cuenta evita colisiones |
| EC2 | `t3.micro`, Amazon Linux 2023, **sin IP pública** | AWS cobra cada IPv4 pública por hora y en este punto no se entra a la máquina |
| RDS | PostgreSQL `db.t4g.micro`, 20 GB gp3, privada, sin backups ni snapshot final | Menor costo, nada queda facturando después del borrado |
| Red | VPC por defecto, 2 security groups, 1 DB subnet group | Una VPC propia con subnets privadas exigiría NAT Gateway, que cuesta más que el resto junto |

El security group de RDS solo acepta el puerto 5432 desde el security group de la EC2, no desde direcciones IP.

## 1. Terraform

Herramienta de infraestructura como código. Se declara el estado final en archivos `.tf` y Terraform calcula qué crear, cambiar o borrar.

| Comando | Qué hace |
|---|---|
| `terraform init` | Descarga el provider de AWS |
| `terraform validate` | Revisa sintaxis y referencias |
| `terraform plan -out plan.tfplan` | Compara el código con lo que existe y muestra los cambios sin aplicarlos |
| `terraform apply plan.tfplan` | Ejecuta exactamente ese plan |
| `terraform destroy` | Borra todo lo que el código creó |

## 2. Usuario `user_cli`

Usuario IAM sin acceso a consola, con una access key y la política administrada `UserCliTaller` ([`politica-user-cli.json`](politica-user-cli.json), reemplazar `ACCOUNT_ID`).

Se usó una política **administrada** y no inline porque las políticas inline de un usuario tienen un límite de 2.048 caracteres y esta lo supera (`LimitExceeded`). Las administradas admiten 6.144, tienen versiones y se pueden reutilizar.

| Bloque de la política | Justificación |
|---|---|
| `ec2:Describe*`, `rds:Describe*` sobre `*` | Terraform y Boto3 leen VPC, subnets, AMIs y estado antes de crear. Casi ninguna acción Describe admite restricción por recurso |
| `ec2:RunInstances` sobre `instance/*` con condición `ec2:InstanceType = t3.micro` | Impide lanzar instancias más grandes |
| `ec2:RunInstances` sobre image, subnet, ENI, SG, volumen y key pair, sin condición | La condición de tipo de instancia solo existe en el recurso `instance`. Si se aplica a todos, el lanzamiento entero se deniega |
| Gestión de SGs, tags y `TerminateInstances` con `aws:RequestedRegion = us-east-2` | Evita crear recursos por error en otra región |
| Gestión de RDS y DB subnet groups con la misma condición de región | Crear, modificar y borrar la instancia |
| `secretsmanager:CreateSecret`, `TagResource`, `DescribeSecret` sobre `secret:rds!*` | Con contraseña administrada, RDS crea el secreto en nombre de quien llama, y siempre con prefijo `rds!` |
| `iam:CreateServiceLinkedRole` solo para `rds.amazonaws.com` | Necesario la primera vez que la cuenta usa RDS |
| S3 limitado a `arn:aws:s3:::taller-eve-*` | Terraform lee muchas configuraciones del bucket al refrescar, por eso `s3:Get*` |

Verificación de que no es administrador `aws iam list-users --profile user_cli` devuelve `AccessDenied`.

### Cómo se autentica `user_cli`

CLI, Boto3 y Terraform usan la misma cadena de credenciales del SDK de AWS. Buscan en orden el flag o argumento explícito, las variables de entorno `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_PROFILE`, y el archivo `~/.aws/credentials` con su región en `~/.aws/config`. Aquí cada herramienta declara `profile = user_cli`. Con esas llaves cada petición se firma con Signature Version 4, y la secret key nunca viaja por la red.

Las access keys **no** se guardan en Secrets Manager porque las herramientas necesitan estar autenticadas antes de poder leer cualquier secreto. Sería circular.

Hallazgo durante el taller. Una variable `AWS_REGION` exportada en la shell tiene prioridad sobre la región del perfil y hacía que las peticiones fueran a otra región. Se resolvió con `unset AWS_REGION AWS_DEFAULT_REGION`.

## 3. Versión Terraform

```bash
cd punto2/terraform
terraform init && terraform validate
terraform plan -out plan.tfplan     # Plan: 6 to add
terraform apply plan.tfplan
terraform destroy                   # 6 destroyed
```
Archivo [`terraform/main.tf`](terraform/main.tf). RDS usa `manage_master_user_password = true` y no tiene argumento `password`.

**Qué guarda el state.** `terraform.tfstate` contiene en JSON todos los atributos de cada recurso, incluidos los sensibles, en texto plano. Si se hubiera usado `password = "..."`, aparecería literal aunque se marque `sensitive`. Con la contraseña administrada, el state solo contiene el ARN del secreto. Se comprobó con `grep -i password terraform.tfstate.backup`, que solo muestra `manage_master_user_password: true` y campos `null`. El state y su `.backup` están en `.gitignore`.

Evidencias `p2-02` a `p2-07`.

## 4. Versión Boto3

```bash
cd punto2
python despliegue_boto3.py crear
python despliegue_boto3.py eliminar
```
Archivo [`despliegue_boto3.py`](despliegue_boto3.py). Guarda los IDs creados en `estado_boto3.json` para poder borrarlos. Diferencias encontradas frente a Terraform

- Fuera de `us-east-1`, `create_bucket` exige `CreateBucketConfiguration`.
- El orden de borrado se escribe a mano.
- Al borrar el SG de RDS justo después de la instancia puede aparecer `DependencyViolation` mientras RDS libera su interfaz de red. El script reintenta.

Evidencias `p2-08` a `p2-10`.

## 5. Versión AWS CLI

```bash
cd punto2
./despliegue_cli.sh
./eliminar_cli.sh
```
Archivos [`despliegue_cli.sh`](despliegue_cli.sh) y [`eliminar_cli.sh`](eliminar_cli.sh). Se ejecutan con zsh, donde los arrays empiezan en 1 y las variables no se parten por espacios, por eso `${SUBNETS[1]}` y el array `TAGS`.

Evidencias `p2-11` a `p2-13`. Verificación final de que no quedó nada en `p2-14`.

## 6. Comparación de métodos

| Criterio | Terraform | Boto3 | AWS CLI |
|---|---|---|---|
| Estilo | Declarativo | Imperativo en Python | Imperativo, comando a comando |
| Estado | `tfstate` automático | Archivo propio | Archivo propio |
| Dependencias | Las calcula solo, borró en paralelo y en el orden correcto | Manuales | Manuales |
| Vista previa | `plan` | No | No |
| Idempotencia | Sí | No, una segunda ejecución falla o duplica | No |
| Borrado | `destroy` | Script en orden inverso | Script en orden inverso |
| Mejor uso | Infraestructura versionada y mantenida | Automatización con lógica o integrada en aplicaciones | Tareas puntuales y depuración |

## 7. Costos

Precios on-demand de us-east-2 aproximados. Verificar en https://calculator.aws antes de usarlos como definitivos.

| Recurso | Precio | 1 hora | 1 semana (168 h) |
|---|---|---|---|
| EC2 t3.micro | ~USD 0,0104 / h | 0,0104 | 1,75 |
| EBS raíz 8 GB gp3 | ~USD 0,08 / GB-mes | 0,0009 | 0,15 |
| RDS db.t4g.micro PostgreSQL | ~USD 0,016 / h | 0,016 | 2,69 |
| Almacenamiento RDS 20 GB gp3 | ~USD 0,115 / GB-mes | 0,0032 | 0,54 |
| Secreto `rds!` | USD 0,40 / mes prorrateado | 0,0006 | 0,09 |
| Bucket S3 vacío | 0 | 0 | 0 |
| **Total** | | **≈ USD 0,031** | **≈ USD 5,22** |

Cada versión estuvo activa unos 15 minutos, así que las tres juntas costaron alrededor de USD 0,03.

**¿Qué sigue cobrando sin tráfico?** La EC2 mientras esté encendida, su volumen EBS aunque se detenga, la instancia RDS, su almacenamiento aunque se detenga (y RDS detenido se reinicia solo a los 7 días), el secreto, cualquier snapshot y cualquier IPv4 pública asignada (~USD 0,005 por hora). Por eso se elimina en vez de detener.

**¿Qué costo añade el secreto de RDS?** USD 0,40 al mes prorrateado por hora más USD 0,05 por cada 10.000 llamadas. La rotación administrada genera versiones nuevas sin costo por versión. RDS borra el secreto al eliminar la instancia.

## 8. Eliminación final

Al terminar el taller se eliminan la access key de `user_cli`, se desasocia y borra la política `UserCliTaller` y se borra el usuario.

```bash
aws iam detach-user-policy --user-name user_cli --policy-arn arn:aws:iam::ACCOUNT_ID:policy/UserCliTaller --profile admin
aws iam delete-policy --policy-arn arn:aws:iam::ACCOUNT_ID:policy/UserCliTaller --profile admin
```
