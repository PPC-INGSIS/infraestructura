# Infraestructura

Configuración para levantar **Snippet Searcher** completo y operar dónde corre: el `docker-compose.yml` con todos los servicios juntos, en una misma red de Docker, y los workflows que manejan las VMs de Azure y despliegan en ellas.

No tiene código ni build. Son archivos de configuración.

## Estado

- `docker-compose.yml`: levanta **Permisos**, **PrintScript** y **Snippets** (con sus bases), **Redis**, y el **asset-service** de la cátedra con su Azurite. Los demás servicios se agregan cuando tengan su imagen disponible.
- `stack.yml` y `versiones.env`: lo que corre en las VMs (Docker Swarm). Es lo mismo que el compose, más la **UI**, **nginx** (la entrada, con HTTPS) y **certbot** (el certificado). Se despliega con el workflow **Deploy** (ver [Despliegue a las VMs](docs/despliegue.md)).
- Workflow **VMs**: funcionando. Enciende y apaga las VMs de dev y prod (ver [Encender y apagar las VMs](docs/vms.md)).

## Por qué un repo aparte

Cada servicio tiene su propio `docker-compose.yml`, que levanta solo lo que ese servicio necesita para desarrollarse (su base de datos). Este repo levanta **el sistema entero**.

Tiene que ser un solo archivo porque Docker Compose crea **una red por archivo**: los contenedores del mismo compose se encuentran por nombre de servicio (`http://printscript:8080`). Con un compose por servicio, quedarían en redes separadas y no se verían.

## Qué va a levantar

| Servicio | Qué es | De quién |
|---|---|---|
| UI | La interfaz web: es lo que usa el usuario y le habla a Snippets | Nosotros (fork del repo de la cátedra) |
| Snippets | Puerta de entrada de todo lo que es snippet | Nosotros |
| Permisos | Quién puede ver o editar qué | Nosotros |
| PrintScript | Valida, formatea, lintea y ejecuta | Nosotros |
| Snippet Store | Guarda y lee el código de los snippets | La cátedra |
| Una base Postgres por servicio propio | Cada servicio es dueño de sus datos | — |
| Redis | Cola de trabajos asincrónicos de Snippets | Nosotros |
| nginx | La puerta de entrada en las VMs: HTTPS, `/` va a la UI y `/api/` a Snippets | Nosotros |

La UI y nginx corren solo en las VMs, no en el `docker-compose.yml`. Para trabajar en la UI en tu máquina se usa el servidor de desarrollo, como explica el README de `printscript-ui` (`npm run dev`).

## Requisitos

- Docker
- Haber iniciado sesión en ghcr.io, porque las imágenes de los servicios son privadas: `docker login ghcr.io` con un token que tenga el permiso `read:packages`.
- Un `.env` con el tag de cada imagen (ver [Configuración](#configuración)).

### Mac con chip Apple (M1, M2...)

Las imágenes de los servicios se publican para `amd64`. En esas Macs la base de Postgres corre nativa, pero las imágenes propias hay que correrlas emuladas:

```bash
docker compose up -d permissions-db
DOCKER_DEFAULT_PLATFORM=linux/amd64 docker compose up -d --no-deps permissions
```

## Uso

```bash
docker compose up -d      # levanta todo
docker compose ps         # qué está corriendo
docker compose logs -f    # ver los logs
docker compose down       # apaga (los datos quedan)
docker compose down -v    # apaga y BORRA los datos
```

## Puertos

Reservados para que los servicios no choquen entre sí en una misma máquina. Todos se publican en `127.0.0.1`: solo se puede entrar desde la propia máquina, no desde la red.

| Servicio | Puerto en tu máquina |
|---|---|
| Snippets | 8080 |
| Permisos | 8081 |
| PrintScript | 8082 |
| Snippet Store | 8083 |
| Postgres de Snippets | 5433 |
| Postgres de Permisos | 5434 |
| Postgres de PrintScript | 5435 |
| Redis | 6379 |

Estos puertos son solo para entrar **desde tu máquina**. Entre contenedores no se usan: cada servicio le habla a otro por su nombre y su puerto interno, por ejemplo `http://printscript:8080`.

## Configuración

Los valores de cada máquina van en un archivo `.env`, que no se sube al repo:

```bash
cp .env.example .env
```

- `.env` está en el `.gitignore`: es de cada máquina y nunca se sube.
- `.env.example` sí se sube: documenta qué variables existen.
- Los `*_TAG` (por ejemplo `PERMISSIONS_TAG`) son el SHA del commit de la imagen publicada. Se copia de la página del paquete en GitHub. Esto es solo para el compose local: los tags que corren en las VMs están en `versiones.env`.
- `AUTH0_DOMAIN` y `AUTH0_AUDIENCE` le dicen a Snippets, PrintScript y Permisos qué tokens aceptar: de qué tenant de Auth0 y para qué API. Son públicos y todo el equipo usa el mismo tenant, así que el `.env.example` ya trae los valores reales.
- `NEW_RELIC_LICENSE_KEY` y `NEW_RELIC_AGENT_ENABLED` son opcionales: en local el agente de New Relic queda apagado. Para probarlo, cada uno crea su propia key de tipo *Ingest - License* en New Relic y la pone en su `.env`. Los servicios aparecen como `<servicio>-local`.

## Cómo agregar un servicio

1. Copiar la plantilla que está comentada en `docker-compose.yml`.
2. Usar el puerto que le corresponde en la tabla de arriba.
3. Si necesita variables propias, agregarlas a `.env.example` con un valor por defecto.

Para que además corra en las VMs:

4. Agregarlo a `stack.yml` (sin `ports`) y su `<SERVICIO>_TAG` a `versiones.env`, con el SHA de una imagen ya publicada. El bot solo actualiza variables que ya existen.
5. En el repo del servicio, sumar el job `update-infra` a su `publish.yml` con su `tag-var`. Ojo de no copiar el `tag-var` de otro servicio.
6. En la organización, darle acceso al repo del servicio al secret `INFRA_APP_PRIVATE_KEY` y a la variable `INFRA_APP_CLIENT_ID`.

## Documentación

Lo que no hace falta para levantar el entorno en local está en `docs/`, un archivo por tema:

| Archivo | Qué tiene |
|---|---|
| [Despliegue](docs/despliegue.md) | Cómo llega el código a las VMs, las ramas, el workflow Deploy, los límites de memoria y el rollback |
| [Observabilidad](docs/observabilidad.md) | New Relic: agentes, puntos de falla y SLO, synthetic, alertas y dashboard |
| [Auth0](docs/auth0.md) | El tenant, la API, el rol automático y las credenciales de la Management API |
| [nginx y HTTPS](docs/nginx-y-https.md) | La entrada de cada VM y el certificado |
| [VMs](docs/vms.md) | Prender y apagar las VMs y cómo se conecta el workflow con Azure |
