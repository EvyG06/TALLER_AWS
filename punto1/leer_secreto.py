import argparse
import json
import os
import time

import boto3
from botocore.exceptions import ClientError

SECRET_ID = os.getenv("SECRET_ID", "taller/p1/app-demo")
PERFIL = os.getenv("AWS_PROFILE", "lector-p1")
REGION = os.getenv("AWS_REGION", "us-east-2")


def obtener_secreto(cliente, secret_id):
    try:
        resp = cliente.get_secret_value(SecretId=secret_id)
    except ClientError as e:
        raise SystemExit(f"Error al leer el secreto ({e.response['Error']['Code']}): {e}")
    return json.loads(resp["SecretString"]), resp["VersionId"]


def enmascarar(valor):
    return valor[:2] + "*" * (len(valor) - 4) + valor[-2:]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--loop", action="store_true")
    parser.add_argument("--intervalo", type=int, default=10)
    args = parser.parse_args()

    cliente = boto3.Session(profile_name=PERFIL, region_name=REGION).client("secretsmanager")

    while True:
        datos, version = obtener_secreto(cliente, SECRET_ID)
        print(f"[{time.strftime('%H:%M:%S')}] version={version[:8]} "
              f"usuario={datos['username']} password={enmascarar(datos['password'])}")
        if not args.loop:
            break
        time.sleep(args.intervalo)


if __name__ == "__main__":
    main()