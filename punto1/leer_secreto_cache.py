import json
import os
import time

import boto3
from aws_secretsmanager_caching import SecretCache, SecretCacheConfig

PERFIL = os.getenv("AWS_PROFILE", "lector-p1")
REGION = os.getenv("AWS_REGION", "us-east-2")
SECRET_ID = "taller/p1/app-demo"

cliente = boto3.Session(profile_name=PERFIL, region_name=REGION).client("secretsmanager")
cache = SecretCache(config=SecretCacheConfig(secret_refresh_interval=60), client=cliente)

for i in range(1, 25):
    datos = json.loads(cache.get_secret_string(SECRET_ID))
    print(f"[{time.strftime('%H:%M:%S')}] lectura #{i} password={datos['password'][:2]}...")
    time.sleep(5)