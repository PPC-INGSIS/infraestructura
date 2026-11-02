#!/bin/sh
# Servicio certbot: consigue el certificado de DOMINIO con Let's Encrypt y después lo renueva.
# Usa el desafío HTTP-01: deja el archivo en /var/www/certbot (volumen certbot-www) y nginx lo
# sirve por el 80.
#
# En una VM nueva todavía no hay certificado, y nginx no puede arrancar el 443 sin uno. Por eso
# primero crea uno provisorio (autofirmado, 1 día) para que nginx arranque, espera a que nginx
# atienda el desafío, borra el provisorio y pide el real. nginx lo toma solo (40-certificado.sh).
#
# Corre para siempre y nunca termina por un error: si terminara, Swarm lo relanzaría al instante
# y cada intento fallido cuenta para los límites de Let's Encrypt. Ante un error, espera y reintenta.
set -u
: "${DOMINIO:?falta_definir_DOMINIO}"

# certbot crea este archivo cuando obtiene el certificado: si existe, ya no hay que pedirlo
renovacion="/etc/letsencrypt/renewal/${DOMINIO}.conf"
live="/etc/letsencrypt/live/${DOMINIO}"
desafio="/var/www/certbot/.well-known/acme-challenge"

# Certificado autofirmado de 1 día, solo para que nginx pueda arrancar
provisorio() {
  mkdir -p "$live"
  openssl req -x509 -noenc -newkey rsa:2048 -days 1 -subj "/CN=${DOMINIO}" \
    -keyout "$live/privkey.pem" -out "$live/fullchain.pem"
}

# Espera hasta 5 minutos a que nginx sirva un archivo de prueba del desafío, por la red del stack.
# Así no se le pide nada a Let's Encrypt (ni se gasta un intento) antes de que nginx esté atendiendo.
esperar_nginx() {
  mkdir -p "$desafio"
  echo listo > "$desafio/prueba"
  intentos=0
  until [ "$(wget -qO- http://nginx/.well-known/acme-challenge/prueba 2>/dev/null)" = listo ]; do
    intentos=$((intentos + 1))
    if [ "$intentos" -gt 60 ]; then
      rm -f "$desafio/prueba"
      return 1
    fi
    sleep 5
  done
  rm -f "$desafio/prueba"
}

pedir_certificado() {
  [ -f "$live/fullchain.pem" ] || provisorio
  esperar_nginx || { echo "nginx no atiende el desafío"; return 1; }
  # certbot no pisa un certificado que no creó él: el provisorio se borra antes de pedir el real.
  # nginx sigue sirviendo el provisorio, que ya tiene cargado en memoria.
  rm -rf "$live"
  if certbot certonly --webroot -w /var/www/certbot -d "$DOMINIO" \
      --agree-tos --register-unsafely-without-email --non-interactive; then
    return 0
  fi
  # Si falló, vuelve a dejar un provisorio para que nginx pueda arrancar si se reinicia
  provisorio
  return 1
}

while :; do
  if [ -f "$renovacion" ]; then
    # Renueva solo si faltan menos de 30 días para que venza; si no, no hace nada
    certbot renew --non-interactive || echo "certbot renew falló; se reintenta en 12 h"
    espera=43200   # 12 h
  elif pedir_certificado; then
    espera=43200   # 12 h
  else
    echo "No se pudo obtener el certificado; se reintenta en 1 h"
    espera=3600    # 1 h
  fi
  sleep "$espera"
done
