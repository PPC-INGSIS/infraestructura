#!/usr/bin/env bash
# Espera hasta 5 minutos a que todos los servicios de un stack estén en N/N y sin
# actualizaciones en curso. Falla si alguna actualización quedó en otro estado.
# Uso: bash scripts/esperar-stack.sh <stack>
# Le habla al Docker de DOCKER_CONTEXT (en el deploy, la VM).
set -euo pipefail

stack="${1:?uso: esperar-stack.sh <stack>}"

for _ in $(seq 1 60); do
  listo=1
  for servicio in $(docker stack services "$stack" --format '{{.Name}}'); do
    estado=$(docker service inspect "$servicio" --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{end}}')
    case "$estado" in
      ""|completed) ;;
      updating) listo=0 ;;
      *)
        echo "$servicio: la actualización quedó en '$estado'"
        docker service ps "$servicio" --no-trunc
        exit 1
        ;;
    esac
  done
  if docker stack services "$stack" --format '{{.Replicas}}' | awk -F'[/ ]' '$1 != $2 { exit 1 }'; then
    :
  else
    listo=0
  fi
  if [ "$listo" -eq 1 ]; then
    docker stack services "$stack"
    exit 0
  fi
  sleep 5
done

echo "Los servicios de $stack no llegaron al estado deseado a tiempo"
docker stack services "$stack"
exit 1
