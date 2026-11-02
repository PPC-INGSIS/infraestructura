#!/bin/sh
# Script de arranque de nginx. La imagen corre /docker-entrypoint.d/*.sh antes de levantar
# nginx, después de completar la plantilla (20-envsubst-on-templates.sh). Hace dos cosas:
#   1. Espera a que exista el certificado: sin él, nginx no puede arrancar el server del 443.
#      Lo crea el servicio certbot (en una VM nueva, primero uno provisorio).
#   2. Deja corriendo un vigilante que recarga nginx cuando el certificado cambia (renovación,
#      o el real reemplazando al provisorio): nginx solo lee el certificado al arrancar o recargar.
set -eu

cert="/etc/letsencrypt/live/${DOMINIO}/fullchain.pem"

# 1. Hasta 5 minutos (60 intentos, cada 5 s). Si no aparece, el contenedor falla y Swarm lo relanza.
intentos=0
until [ -f "$cert" ]; do
  intentos=$((intentos + 1))
  if [ "$intentos" -gt 60 ]; then
    echo "$0: no apareció $cert en 5 minutos" >&2
    exit 1
  fi
  echo "$0: esperando $cert"
  sleep 5
done

# 2. Cada minuto compara la huella del certificado con la anterior; si cambió, recarga.
#    Corre en segundo plano para que el arranque siga y se levante nginx.
(
  anterior=$(sha256sum "$cert")
  while :; do
    sleep 60
    # Mientras certbot reemplaza el provisorio, el archivo puede no existir unos segundos
    actual=$(sha256sum "$cert" 2>/dev/null) || continue
    if [ "$actual" != "$anterior" ]; then
      echo "$0: el certificado cambió, recargando nginx"
      nginx -s reload && anterior=$actual
    fi
  done
) </dev/null &
