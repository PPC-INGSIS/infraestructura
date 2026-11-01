#!/bin/sh
# Servicio certbot: la primera vez pide el certificado de DOMINIO a Let's Encrypt y después lo
# renueva. Usa el desafío HTTP-01: deja el archivo en /var/www/certbot (volumen certbot-www) y
# nginx lo sirve por el 80.
#
# Corre para siempre y nunca termina por un error: si terminara, Swarm lo relanzaría al instante
# y cada intento fallido cuenta para los límites de Let's Encrypt. Ante un error, espera y reintenta.
set -u
: "${DOMINIO:?falta_definir_DOMINIO}"

# certbot crea este archivo cuando obtiene el certificado: si existe, ya no hay que pedirlo
renovacion="/etc/letsencrypt/renewal/${DOMINIO}.conf"

while :; do
  if [ -f "$renovacion" ]; then
    # Renueva solo si faltan menos de 30 días para que venza; si no, no hace nada
    certbot renew --non-interactive || echo "certbot renew falló; se reintenta en 12 h"
    espera=43200   # 12 h
  elif certbot certonly --webroot -w /var/www/certbot -d "$DOMINIO" \
      --agree-tos --register-unsafely-without-email --non-interactive; then
    espera=43200   # 12 h
  else
    echo "No se pudo obtener el certificado; se reintenta en 1 h"
    espera=3600    # 1 h
  fi
  sleep "$espera"
done
