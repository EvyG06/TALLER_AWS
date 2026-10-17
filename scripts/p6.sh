#!/usr/bin/env bash
set -eo pipefail
source "$HOME/taller-aws/scripts/lib.sh"
ROL="AWSGlueServiceRole-taller"

bucket() {
  if [ -z "${BUCKET_GLUE:-}" ]; then save BUCKET_GLUE "taller-glue-$RANDOM$RANDOM"; fi
  aws s3 mb "s3://$BUCKET_GLUE" --region us-east-1
  aws s3 cp "$BASE/punto6/ventas.csv" "s3://$BUCKET_GLUE/datos/ventas/ventas.csv"
  aws s3 ls "s3://$BUCKET_GLUE/datos/ventas/"
}

rol() {
  aws iam create-role --role-name "$ROL" --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"glue.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null 2>&1 || echo "(el rol ya existía)"
  aws iam attach-role-policy --role-name "$ROL" --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole
  aws iam put-role-policy --role-name "$ROL" --policy-name acceso-bucket-taller --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::$BUCKET_GLUE\",\"arn:aws:s3:::$BUCKET_GLUE/*\"]}]}"
  echo "Rol creado: puede leer SOLO el bucket $BUCKET_GLUE. Esperando propagación..."; sleep 15
}

recrawl() {
  aws glue start-crawler --name crawler-ventas
  echo "Ejecutando crawler..."
  sleep 5
  while [ "$(aws glue get-crawler --name crawler-ventas --query 'Crawler.State' --output text)" != "READY" ]; do echo "  ..."; sleep 10; done
  aws glue get-crawler --name crawler-ventas --query 'Crawler.LastCrawl.{Estado:Status,Inicio:StartTime,Fin:EndTime}' --output json
  aws glue get-crawler-metrics --crawler-name-list crawler-ventas --query 'CrawlerMetricsList[0].{TablasCreadas:TablesCreated,TablasActualizadas:TablesUpdated}' --output json
}

crawler() {
  aws glue create-database --database-input Name=taller_ventas 2>/dev/null || echo "(la base ya existía)"
  aws glue create-crawler --name crawler-ventas --role "$ROL" --database-name taller_ventas \
     --targets "{\"S3Targets\":[{\"Path\":\"s3://$BUCKET_GLUE/datos/ventas/\"}]}" 2>/dev/null || echo "(el crawler ya existía)"
  recrawl
}

esquema() {
  aws glue get-table --database-name taller_ventas --name ventas --query 'Table.StorageDescriptor.Columns[].[Name,Type]' --output table
  aws glue get-table --database-name taller_ventas --name ventas --query 'Table.{Serde:StorageDescriptor.SerdeInfo.SerializationLibrary,Clasificacion:Parameters.classification,SaltarEncabezado:Parameters."skip.header.line.count",Ubicacion:StorageDescriptor.Location}' --output json
}

corregir() {
  "$PY" "$BASE/punto6/corregir_esquema.py"
  # que el crawler no pise nuestras correcciones al volver a correr
  aws glue update-crawler --name crawler-ventas --schema-change-policy UpdateBehavior=LOG,DeleteBehavior=LOG
  esquema
}

athena() { "$PY" "$BASE/punto6/punto6_athena.py"; }

agregar() {
  aws s3 cp "$BASE/punto6/ventas_extra.csv" "s3://$BUCKET_GLUE/datos/ventas/ventas_extra.csv"
  recrawl
  "$PY" "$BASE/punto6/punto6_athena.py" --sql "SELECT COUNT(*) AS total FROM ventas"
}

manual() {
  "$PY" "$BASE/punto6/punto6_athena.py" --sql "CREATE EXTERNAL TABLE IF NOT EXISTS ventas_manual (id bigint, fecha date, cliente string, ciudad string, producto string, cantidad int, precio double) ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' LOCATION 's3://$BUCKET_GLUE/datos/ventas/' TBLPROPERTIES ('skip.header.line.count'='1')"
  "$PY" "$BASE/punto6/punto6_athena.py" --sql "SELECT COUNT(*) AS total FROM ventas_manual"
}

estado() {
  echo "== Crawlers ==";  aws glue list-crawlers --query 'CrawlerNames' --output text
  echo "== Bases Glue =="; aws glue get-databases --query 'DatabaseList[].Name' --output text
  echo "== Rol IAM ==";   aws iam list-roles --query "Roles[?RoleName=='$ROL'].RoleName" --output text
  echo "== Buckets ==";   aws s3 ls
}

borrar() {
  aws glue delete-crawler --name crawler-ventas 2>/dev/null || true
  aws glue delete-database --name taller_ventas 2>/dev/null || true
  aws iam delete-role-policy --role-name "$ROL" --policy-name acceso-bucket-taller 2>/dev/null || true
  aws iam detach-role-policy --role-name "$ROL" --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole 2>/dev/null || true
  aws iam delete-role --role-name "$ROL" 2>/dev/null || true
  if [ -n "${BUCKET_GLUE:-}" ]; then
    aws s3 rm "s3://$BUCKET_GLUE" --recursive >/dev/null 2>&1 || true
    aws s3 rb "s3://$BUCKET_GLUE" 2>/dev/null || true
    save BUCKET_GLUE ""
  fi
  echo ">> Verificación final:"; estado
}

accion="${1:-}"; shift || true
case "$accion" in
  bucket|rol|crawler|recrawl|esquema|corregir|athena|agregar|manual|estado|borrar) "$accion" "$@" 2>&1 | tee "$EVID/p6_${accion}.txt" ;;
  *) echo "Uso: p6 {bucket|rol|crawler|esquema|corregir|athena|agregar|manual|borrar}"; exit 1 ;;
esac
