# Punto 1. AWS Secrets Manager

Región usada en todo el taller **us-east-2 (Ohio)**.

## 1. Conceptos

**Qué es.** AWS Secrets Manager es un servicio administrado para almacenar, cifrar, versionar y rotar secretos. Cada secreto puede ser texto o binario de hasta 64 KB. Lo típico es guardar JSON con credenciales de base de datos, llaves de API, tokens OAuth o llaves SSH. Los valores se cifran en reposo con AWS KMS.

**Cómo se controla quién lo lee.** Se combinan tres capas.

| Capa | Dónde vive | Para qué |
|---|---|---|
| Política de identidad (IAM) | En el usuario o rol | Qué acciones puede hacer esa identidad y sobre qué ARN |
| Política de recurso | En el propio secreto | Quién puede tocar el secreto, útil para acceso entre cuentas. Lleva `Principal` |
| Llave KMS | En KMS | Con `aws/secretsmanager` no se necesitan permisos extra. Con una llave propia el lector necesita `kms:Decrypt` |

En este punto solo se usó la política de identidad, porque el acceso es dentro de la misma cuenta.

**Crear, recuperar y rotar.**

| Operación | API | Quién la ejecuta | Efecto |
|---|---|---|---|
| Crear | `CreateSecret` | Administrador o IaC | Nace la primera versión con la etiqueta `AWSCURRENT` |
| Recuperar | `GetSecretValue` | La aplicación en tiempo de ejecución | Devuelve la versión `AWSCURRENT`, salvo que se pida otra |
| Actualizar | `PutSecretValue` | Administrador | Crea una versión nueva y mueve `AWSCURRENT` hacia ella |
| Rotar | `RotateSecret` | Función Lambda o rotación administrada | Genera una credencial nueva, **la aplica en el sistema destino**, la prueba y luego mueve `AWSCURRENT` |

La diferencia clave entre actualizar y rotar es que rotar también cambia la contraseña en la base de datos. La rotación con Lambda sigue cuatro pasos fijos (`createSecret`, `setSecret`, `testSecret`, `finishSecret`). Servicios como RDS y Redshift ofrecen rotación administrada sin escribir la Lambda.

## 2. Identidades

| Identidad | Uso | Permisos |
|---|---|---|
| `desarrollo_IngDatos` | Persona que prepara recursos | `AdministratorAccess` |
| `lector_p1` | El programa Python | Solo `GetSecretValue` y `DescribeSecret` sobre el ARN del secreto |

`lector_p1` no tiene acceso a la consola. Es una identidad de programa.

## 3. Pasos para reproducir

### 3.1 Crear el secreto (consola)
Secrets Manager, *Store a new secret*, tipo *Other type of secret*, pares `username` y `password` ficticios, llave `aws/secretsmanager`, nombre `taller/p1/app-demo`, tags `proyecto=taller-aws` y `punto=1`, sin rotación.

Evidencia `../evidencias-1-2-5/p1-01-secreto-creado.png`

### 3.2 Usuario lector y política
IAM, *Create user* `lector_p1` sin acceso a consola, política inline `LeerSecretoP1` con el contenido de [`politica-lector-p1.json`](politica-lector-p1.json) reemplazando `ACCOUNT_ID`, y una access key para uso fuera de AWS.

```bash
aws configure --profile lector-p1   # región us-east-2
aws sts get-caller-identity --profile lector-p1
```

Por qué el ARN termina en `-??????`. AWS agrega 6 caracteres aleatorios al nombre del secreto. Seis comodines de un carácter cubren exactamente ese sufijo. Usar `app-demo*` también autorizaría un futuro `app-demo-prod`.

Por qué `DescribeSecret`. La librería oficial de caché llama primero a `DescribeSecret` para saber qué versión tiene `AWSCURRENT` y solo pide el valor cuando cambió. Sin ese permiso falla con `AccessDeniedException`. `DescribeSecret` devuelve metadatos, nunca el valor.

Evidencia `../evidencias-1-2-5/p1-02-usuario-lector-p1.png`

### 3.3 Mínimo privilegio
```bash
aws secretsmanager get-secret-value --secret-id taller/p1/app-demo --query '{Nombre:Name,Version:VersionId}' --profile lector-p1
aws secretsmanager list-secrets --profile lector-p1
aws secretsmanager put-secret-value --secret-id taller/p1/app-demo --secret-string '{}' --profile lector-p1
aws secretsmanager delete-secret --secret-id taller/p1/app-demo --profile lector-p1
```
La lectura funciona. Listar, modificar y borrar devuelven `AccessDeniedException`.

Evidencia `../evidencias-1-2-5/p1-03-minimo-privilegio.png`

### 3.4 Programa Python
```bash
python3 -m venv .venv && source .venv/bin/activate
pip install boto3 aws-secretsmanager-caching
python punto1/leer_secreto.py
```
[`leer_secreto.py`](leer_secreto.py) no contiene contraseñas. Solo conoce el nombre del secreto, se autentica con el perfil `lector-p1` y llama a `GetSecretValue` en cada ejecución.

Evidencia `../evidencias-1-2-5/p1-04-programa-lee-secreto.png`

### 3.5 Actualización sin cambiar el código
```bash
python punto1/leer_secreto.py --loop --intervalo 5
```
Con el programa corriendo se editó el `password` en la consola. En la siguiente lectura la versión pasó de `60a617f9` a `ba81a6b5` y la contraseña enmascarada cambió.

Explicación. Editar el valor ejecuta `PutSecretValue`, que crea una versión nueva inmutable y mueve la etiqueta `AWSCURRENT`. La versión anterior queda como `AWSPREVIOUS` para hacer rollback. El programa no apunta a una versión sino a la etiqueta, y cada `GetSecretValue` la resuelve en el momento de la llamada. Por eso obtiene el valor nuevo sin modificar el código.

Evidencias `../evidencias-1-2-5/p1-05-actualizacion-en-vivo.png` y `../evidencias-1-2-5/p1-06-versiones.png`

### 3.6 Caché en memoria
[`leer_secreto_cache.py`](leer_secreto_cache.py) usa `SecretCache` con `secret_refresh_interval=60`. Al editar el secreto durante la ejecución, el cambio tarda hasta 60 segundos en verse, mientras que sin caché se veía en la siguiente lectura.

Evidencia `../evidencias-1-2-5/p1-07-cache-ttl.png`

## 4. Costos

Precios de AWS Secrets Manager consultados en la página oficial de precios.

| Concepto | Tarifa |
|---|---|
| Secreto almacenado | USD 0,40 por secreto al mes, prorrateado por hora (0,40 / 720 ≈ USD 0,00056 por hora) |
| Llamadas a la API | USD 0,05 por cada 10.000 llamadas |
| Versiones nuevas y rotaciones | Sin costo adicional por versión |

**¿Cómo se cobran los secretos y las llamadas?** Por número de secretos almacenados en el tiempo y por número de llamadas. No hay costos fijos ni contratos.

**Estimación de esta práctica.** El secreto vivió alrededor de 2 horas y el programa hizo unas 300 llamadas.

| Concepto | Cálculo | Costo |
|---|---|---|
| Almacenamiento | 1 secreto × 2 h × 0,00056 | USD 0,0011 |
| Llamadas | 300 × 0,05 / 10.000 | USD 0,0015 |
| **Total** | | **≈ USD 0,003** |

**¿Qué pasa si el programa consulta el mismo secreto repetidamente?** El costo de almacenamiento no cambia y el de llamadas crece de forma lineal. Una aplicación que lee el secreto una vez por segundo durante 30 días hace 2.592.000 llamadas, es decir USD 12,96 al mes en API frente a USD 0,40 del secreto. Además cada llamada agrega latencia de red y expone la aplicación a límites de tasa de la API.

**¿Cuándo conviene guardar el valor en memoria?** Cuando el secreto se lee con mucha frecuencia y cambia poco, por ejemplo credenciales de base de datos usadas en cada petición. Con un TTL de 1 hora, la misma aplicación pasa de 2,6 millones a unas 1.440 llamadas al mes (720 refrescos × 2 llamadas). El costo de la caché es la ventana de desactualización, así que el TTL debe ser menor que el intervalo de rotación y la aplicación debería forzar un refresco cuando la base de datos rechace la credencial.

## 5. Eliminación

```bash
aws secretsmanager delete-secret --secret-id taller/p1/app-demo --force-delete-without-recovery --profile admin --region us-east-2
aws secretsmanager describe-secret --secret-id taller/p1/app-demo --profile admin --region us-east-2
```
La segunda orden devuelve `ResourceNotFoundException`. Luego se eliminaron la access key, la política inline y el usuario `lector_p1`.

`--force-delete-without-recovery` borra de inmediato. Sin esa opción el secreto queda programado para eliminación entre 7 y 30 días. En producción se usaría esa ventana de recuperación.

Evidencias `../evidencias-1-2-5/p1-08-eliminacion-secreto.png`, `../evidencias-1-2-5/p1-09-eliminacion-usuario.png` y `../evidencias-1-2-5/p1-10-perfiles-locales.png` (en el Mac solo queda el perfil `admin`)

## Fuentes
- AWS Secrets Manager pricing, https://aws.amazon.com/secrets-manager/pricing/
- AWS Secrets Manager User Guide, políticas basadas en identidad, https://docs.aws.amazon.com/secretsmanager/latest/userguide/auth-and-access_iam-policies.html
