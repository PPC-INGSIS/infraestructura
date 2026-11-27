# Entrada: nginx y HTTPS

En cada VM, nginx es el único servicio que se ve desde afuera.

| Entorno | Dirección |
|---|---|
| dev | `https://ppc-snippets-dev.duckdns.org` |
| prod | `https://ppc-snippets-prod.duckdns.org` |

El dominio de cada uno es la variable `DOMINIO` del Environment del repo, y la config de nginx es una plantilla que lo completa al arrancar.

- **443 (HTTPS)**: acá termina TLS. `/api/...` va a Snippets sin el prefijo (`/api/snippets` llega como `/snippets`), salvo `/api/actuator`, que responde 404 (Actuator no se ve desde afuera). Todo lo demás va a la UI. Hacia adentro sigue HTTP plano, por la red del stack. A Snippets le pasa cómo era el pedido afuera (`X-Forwarded-Proto` y `X-Forwarded-Prefix: /api`), para que arme sus URLs con `https` y `/api`.
- **80 (HTTP)**: solo atiende el desafío de Let's Encrypt; todo lo demás se redirige a HTTPS.

El certificado lo consigue y lo renueva el servicio **certbot**, solo:

- En una VM nueva crea primero un certificado provisorio (autofirmado, de un día) para que nginx pueda arrancar, y después pide el real a Let's Encrypt.
- Cada 12 horas intenta renovar; certbot solo renueva si faltan menos de 30 días para el vencimiento.
- nginx revisa el certificado cada minuto y se recarga solo cuando cambia.

El certificado vive en el volumen `letsencrypt` de la VM. No borrarlo: Let's Encrypt limita cuántos certificados se pueden pedir por semana para un mismo dominio.
