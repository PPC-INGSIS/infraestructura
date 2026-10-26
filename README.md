# Infraestructura

Configuración para levantar **Snippet Searcher** completo y operar dónde corre: el `docker-compose.yml` con todos los servicios juntos, en una misma red de Docker, y los workflows que manejan las VMs de Azure y despliegan en ellas.

No tiene código ni build. Son archivos de configuración.

## Estado

- `docker-compose.yml`: levanta **Permisos**, **PrintScript** y **Snippets** (con sus bases), y el **asset-service** de la cátedra con su Azurite. Los demás servicios se agregan cuando tengan su imagen disponible.
- `stack.yml` y `versiones.env`: lo que corre en las VMs (Docker Swarm). Se despliega con el workflow **Deploy** (ver [Despliegue a las VMs](#despliegue-a-las-vms)).
- Workflow **VMs**: funcionando. Enciende y apaga las VMs de dev y prod (ver [Encender y apagar las VMs](#encender-y-apagar-las-vms)).

## Por qué un repo aparte

Cada servicio tiene su propio `docker-compose.yml`, que levanta solo lo que ese servicio necesita para desarrollarse (su base de datos). Este repo levanta **el sistema entero**.

Tiene que ser un solo archivo porque Docker Compose crea **una red por archivo**: los contenedores del mismo compose se encuentran por nombre de servicio (`http://printscript:8080`). Con un compose por servicio, quedarían en redes separadas y no se verían.

## Qué va a levantar

| Servicio | Qué es | De quién |
|---|---|---|
| UI | La interfaz web: es lo que usa el usuario y le habla a Snippets | La cátedra |
| Snippets | Puerta de entrada de todo lo que es snippet | Nosotros |
| Permisos | Quién puede ver o editar qué | Nosotros |
| PrintScript | Valida, formatea, lintea y ejecuta | Nosotros |
| Snippet Store | Guarda y lee el código de los snippets | La cátedra |
| Una base Postgres por servicio propio | Cada servicio es dueño de sus datos | — |

Todavía no se sabe cómo entrega la cátedra la UI (imagen lista o código para construir), así que no tiene puerto asignado. Se define cuando la tengamos.


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

Estos puertos son solo para entrar **desde tu máquina**. Entre contenedores no se usan: cada servicio le habla a otro por su nombre y su puerto interno, por ejemplo `http://printscript:8080`.

## Configuración

Los valores de cada máquina van en un archivo `.env`, que no se sube al repo:

```bash
cp .env.example .env
```

- `.env` está en el `.gitignore`: es de cada máquina y nunca se sube.
- `.env.example` sí se sube: documenta qué variables existen.
- Los `*_TAG` (por ejemplo `PERMISSIONS_TAG`) son el SHA del commit de la imagen publicada. Se copia de la página del paquete en GitHub. Esto es solo para el compose local: los tags que corren en las VMs están en `versiones.env`.


## Cómo agregar un servicio

1. Copiar la plantilla que está comentada en `docker-compose.yml`.
2. Usar el puerto que le corresponde en la tabla de arriba.
3. Si necesita variables propias, agregarlas a `.env.example` con un valor por defecto.

## Despliegue a las VMs

Las VMs corren un Docker Swarm de un solo nodo con el `stack.yml`: los mismos servicios del compose, pero sin puertos publicados y con la sección `deploy:` de Swarm. El stack es el mismo archivo en dev y en prod; lo que cambia entre ambientes es la versión de cada imagen, que sale de la rama.

| Archivo | Para qué |
|---|---|
| `stack.yml` | Los servicios tal como corren en las VMs. Las imágenes que no construimos (`asset-service`, `azurite` y `postgres`) están fijadas por digest, así que solo cambian si alguien cambia este archivo en un PR |
| `versiones.env` | El SHA de la imagen de cada servicio. Se llama igual en `dev` y en `main` |
| `.github/workflows/deploy.yml` | Despliega el stack en la VM del entorno |

### Cómo llega el código a una VM

Este repo usa gitflow, igual que los servicios: `dev` es el entorno dev y `main` es prod.

- Todos los PRs de este repo van a **`dev`**. `main` solo recibe el PR de `dev` a `main`.
- Cuando un servicio mergea a su `dev`, se publica la imagen y un bot (`ppc-ingsis-infra-updater`) commitea el SHA nuevo en `versiones.env` de la rama `dev` de este repo. Ese commit despliega a dev solo.
- El **release a prod** es el PR de `dev` a `main`. Lleva el mismo `versiones.env`, así que prod corre exactamente la imagen que se probó en dev: la imagen se construye una sola vez, en `dev`.
- La rama decide el entorno: lo que cambia en `main` se despliega a prod y lo que cambia en `dev` se despliega a dev. El workflow no deja desplegar prod desde otra rama.
- `versiones.env` lo escribe el bot. No se edita a mano, salvo para arreglar algo.

### Cómo se despliega

El workflow **Deploy** corre cuando cambia `versiones.env` o `stack.yml` en `dev` o en `main`. También se puede lanzar a mano: pestaña **Actions** → **Deploy** → **Run workflow**, eligiendo la rama del entorno (`dev` para dev, `main` para prod).

1. El runner de GitHub se conecta por SSH al Docker de la VM del entorno. Las claves y el host están en los Environments `dev` y `prod` del repo.
2. Corre `docker stack deploy` con los tags de `versiones.env`. Swarm recrea solo los servicios cuya definición cambió.
3. Espera hasta 5 minutos a que todos los servicios estén en N/N, y al final imprime el estado de cada tarea con su edad.

Con la VM apagada el deploy falla en el paso **Verificar que la VM responde**. Se prende con el workflow **VMs** y se vuelve a correr (**Re-run jobs**) sobre el run más reciente: un re-run usa el commit de ese run, así que uno viejo desplegaría versiones viejas.

## Encender y apagar las VMs

Hay una VM por entorno, en Azure:

| Entorno | VM | Rama que se deploya ahí |
|---|---|---|
| dev | `vm-snippet-dev` | `dev` |
| prod | `vm-snippet-prod` | `main` |

Las VMs cuestan mientras están prendidas, así que **se prenden para trabajar y se apagan al terminar**. Además, se apagan solas todos los días a las 23:00 (hora de Argentina) por si alguien se olvida.

### Cómo

1. Pestaña **Actions** → workflow **VMs** → **Run workflow**.
2. Elegir la VM (`dev` o `prod`) y la acción (`encender` o `apagar`).
3. El último paso, **Estado**, muestra cómo quedó: `VM running` o `VM deallocated`.

Puede usarlo cualquiera con permiso de escritura en este repo.

### Cómo se conecta con Azure

El workflow entra a Azure con OIDC: no hay ninguna contraseña de Azure guardada en GitHub.

- En Azure hay una identidad (`gh-snippet-searcher-infra`) que solo acepta workflows que corren desde la rama `main` de este repo.
- Esa identidad tiene el rol **Colaborador de la máquina virtual** solo sobre el grupo de recursos `rg-snippet-searcher`.
- Los secrets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` y `AZURE_SUBSCRIPTION_ID` son identificadores, no contraseñas. Están como secrets para que no aparezcan en los logs, que en este repo son públicos.

### Si falla

| Error | Causa probable |
|---|---|
| `AADSTS700213: No matching federated identity` | La credencial federada no coincide con el repo o la rama. Se corrió desde una rama que no es `main`. |
| Se queda colgado en `Attempting Azure CLI login` y corta a los 5 minutos | La identidad no tiene el rol correcto sobre el grupo de recursos. Revisar en Azure: IAM → Comprobar acceso. |
| `AuthorizationFailed` | Mismo caso: falta el rol, o se acaba de asignar y todavía no se propagó (esperar unos minutos). |
