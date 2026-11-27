# Infraestructura

Configuración para levantar **Snippet Searcher** completo y operar dónde corre: el `docker-compose.yml` con todos los servicios juntos, en una misma red de Docker, y los workflows que manejan las VMs de Azure y despliegan en ellas.

No tiene código ni build. Son archivos de configuración.

## Estado

- `docker-compose.yml`: levanta **Permisos**, **PrintScript** y **Snippets** (con sus bases), **Redis**, y el **asset-service** de la cátedra con su Azurite. Los demás servicios se agregan cuando tengan su imagen disponible.
- `stack.yml` y `versiones.env`: lo que corre en las VMs (Docker Swarm). Es lo mismo que el compose, más la **UI**, **nginx** (la entrada, con HTTPS) y **certbot** (el certificado). Se despliega con el workflow **Deploy** (ver [Despliegue a las VMs](#despliegue-a-las-vms)).
- Workflow **VMs**: funcionando. Enciende y apaga las VMs de dev y prod (ver [Encender y apagar las VMs](#encender-y-apagar-las-vms)).

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

## Despliegue a las VMs

Las VMs corren un Docker Swarm de un solo nodo con el `stack.yml`: los mismos servicios del compose más la UI, nginx y certbot, sin puertos publicados salvo nginx (80 y 443), y con la sección `deploy:` de Swarm. El stack es el mismo archivo en dev y en prod; lo que cambia entre ambientes es la versión de cada imagen, que sale de la rama, y el dominio.

| Archivo | Para qué |
|---|---|
| `stack.yml` | Los servicios tal como corren en las VMs. Las imágenes que no construimos (`asset-service`, `azurite`, `postgres`, `redis`, `nginx` y `certbot`) están fijadas por digest, así que solo cambian si alguien cambia este archivo en un PR |
| `versiones.env` | El SHA de la imagen de cada servicio. Se llama igual en `dev` y en `main` |
| `nginx/default.conf.template` | La config de nginx (ver [Entrada: nginx y HTTPS](#entrada-nginx-y-https)) |
| `nginx/40-certificado.sh` | Hace que nginx espere el certificado al arrancar y se recargue cuando cambia |
| `certbot/certbot.sh` | Consigue el certificado y lo renueva |
| `.github/workflows/deploy.yml` | Despliega el stack en la VM del entorno |

### Cómo llega el código a una VM

Este repo usa gitflow, igual que los servicios: `dev` es el entorno dev y `main` es prod.

- Todos los PRs de este repo van a **`dev`**. `main` solo recibe el PR de `dev` a `main`.
- Cuando un servicio mergea a su `dev`, se publica la imagen y un bot (`ppc-ingsis-infra-updater`) commitea el SHA nuevo en `versiones.env` de la rama `dev` de este repo. Ese commit despliega a dev solo.
- El **release a prod** es el PR de `dev` a `main`. Lleva el mismo `versiones.env`, así que prod corre exactamente la imagen que se probó en dev: la imagen se construye una sola vez, en `dev`.
- La rama decide el entorno: lo que cambia en `main` se despliega a prod y lo que cambia en `dev` se despliega a dev. El workflow no deja desplegar prod desde otra rama.
- `versiones.env` lo escribe el bot. No se edita a mano, salvo para arreglar algo.

### Reglas de las ramas

`dev` y `main` tienen reglas (Settings → Rules → Rulesets):

- Todo entra por PR: no se puede hacer push directo. No hace falta aprobación.
- No se pueden borrar ni hacer force push.
- En `dev`, el bot es la excepción: hace push directo de `versiones.env`, sin PR.

GitHub propone `main` como base de los PRs. Antes de crear uno, cambiar la base a `dev`.

### Cómo se despliega

El workflow **Deploy** corre cuando cambia `versiones.env`, `stack.yml`, algo en `nginx/` o algo en `certbot/`, en `dev` o en `main`. También se puede lanzar a mano: pestaña **Actions** → **Deploy** → **Run workflow**, eligiendo la rama del entorno (`dev` para dev, `main` para prod).

1. El runner de GitHub se conecta por SSH al Docker de la VM del entorno. Las claves y el host están en los Environments `dev` y `prod` del repo, junto con lo que se pasa al stack: las variables `DOMINIO` (nginx), `AUTH0_DOMAIN` y `AUTH0_AUDIENCE` (Snippets, PrintScript y Permisos) y `AUTH0_MANAGEMENT_CLIENT_ID` (Snippets), y los secrets `NEW_RELIC_LICENSE_KEY` (ver [New Relic](#new-relic)) y `AUTH0_MANAGEMENT_CLIENT_SECRET` (ver [Auth0](#auth0)). Si falta alguno, el deploy corta con `falta_definir_<VARIABLE>`.
2. Corre `docker stack deploy` con los tags de `versiones.env`. Swarm recrea solo los servicios cuya definición cambió.
3. Espera hasta 5 minutos a que todos los servicios estén en N/N, y al final imprime el estado de cada tarea con su edad.

Cómo leer ese estado: un servicio que el deploy no tocó conserva la edad de su tarea. Si una tarea anterior terminó en `Shutdown`, la reemplazó un deploy; si terminó en `Failed`, se cayó (es normal al prender la VM, mientras los servicios se esperan entre sí).

Con la VM apagada el deploy falla en el paso **Verificar que la VM responde**. Se prende con el workflow **VMs** y se vuelve a correr (**Re-run jobs**) sobre el run más reciente: un re-run usa el commit de ese run, así que uno viejo desplegaría versiones viejas.

### Límites de memoria

Cada servicio de `stack.yml` tiene un límite de memoria (`deploy.resources.limits.memory`). Sin límite, un servicio que crece sin control se come la memoria de todos, y la VM no tiene swap: cuando se llena, Linux mata procesos.

Medido en la VM de dev el 26/11 (`free -h` y `docker stats --no-stream`), recién deployada y sin carga. Esos números son un piso: una JVM agranda su heap a medida que la usan.

| Servicio | Uso medido | Límite |
|---|---|---|
| snippets | 589 MiB | 1 GiB |
| permissions | 548 MiB | 1 GiB |
| printscript | 466 MiB | 1 GiB |
| asset-service | 704 MiB | 1 GiB |
| azurite | 191 MiB | 384 MiB |
| snippets-db | 102 MiB | 256 MiB |
| permissions-db | 44 MiB | 256 MiB |
| redis | 23 MiB | 128 MiB |
| certbot | 35 MiB | 128 MiB |
| nginx | 4 MiB | 64 MiB |
| ui | 9 MiB | 64 MiB |
| **Total** | **~2,7 GiB** | **~5,3 GiB** |

La VM tiene 7,7 GiB. Los límites suman ~5,3 GiB porque los servicios con `order: start-first` arrancan el contenedor nuevo antes de apagar el viejo: durante un deploy puede haber una copia extra de un servicio de 1 GiB. Lo que sobra queda para el sistema, Docker y el agente de infraestructura de New Relic (`monitoreo/compose.yml`, fuera del stack).

**Las JVMs y el límite.** La JVM calcula su heap máximo según la memoria que ve: por defecto, el 25 %. Sin límite ve toda la VM (~1,9 GiB de heap cada una); con 1 GiB de límite y el default, el heap bajaría a 256 MiB. Por eso las cuatro llevan `-XX:MaxRAMPercentage=75` (768 MiB de heap, y el resto para la memoria fuera del heap y el agente de New Relic):

- snippets, permissions y asset-service: `JAVA_TOOL_OPTIONS` en `stack.yml`. Su agente de New Relic va en el comando de arranque de la imagen, así que la variable se suma y no lo pisa.
- printscript: ya lo define su `Dockerfile` en `JAVA_TOOL_OPTIONS`, junto con el `-javaagent`. No se pone en el stack, porque lo reemplazaría y se perdería el agente.

Si un servicio llega a su límite, Docker lo mata y Swarm lo reinicia: se ve en `docker service ps <servicio>` (una tarea en `Failed`). Antes de subir un límite, medir de nuevo con carga.

### Volver a una versión anterior (rollback)

Lo que corre en la VM es lo que dice `versiones.env`. Para volver atrás un servicio, se revierte en git el commit que le cambió el tag:

```bash
git checkout dev && git pull
git checkout -b revert/<servicio>
git revert <SHA del commit del bot>
git push -u origin revert/<servicio>
```

Y un PR a `dev`. Al mergearlo, el deploy vuelve a la imagen anterior (la misma, con el mismo digest) y solo reemplaza ese servicio. El próximo merge del servicio vuelve a subir el tag con el bot.

No usar `docker service rollback` en la VM: la VM quedaría distinta de `versiones.env`, y el próximo deploy de cualquier servicio volvería a poner la imagen de git.

### New Relic

Cada servicio manda sus datos a la cuenta de New Relic del equipo con el nombre `<servicio>-<entorno>` (por ejemplo `snippets-dev`), para que dev y prod no se mezclen.

- La key es de tipo *Ingest - License*: solo sirve para **mandar** datos, no para leerlos. Hay una por entorno (`snippet-searcher-dev` y `snippet-searcher-prod`), cargada como secret `NEW_RELIC_LICENSE_KEY` en cada Environment. Si se filtra una, se borra y se crea otra sin tocar el otro entorno. La key original de la cuenta no se usa porque no se puede borrar.
- Llega a los servicios como variable de entorno y no como secret de Swarm: el agente de Java arranca antes que Spring y no lee `/run/secrets/`.
- Las variables están en todos los servicios de Spring, pero solo hacen algo en los que traen el agente en su imagen (por ahora, `asset-service`).

#### Cómo llegan los datos: el agente de Java

Usamos el agente de Java de New Relic (`-javaagent`), el mismo que trae el asset service de la cátedra, y no OpenTelemetry:

- No hay que cambiar código: el agente se engancha en la JVM al arrancar e instrumenta Tomcat, Spring MVC, los clientes HTTP, JDBC y Redis.
- Propaga el trace id solo: un pedido que entra a Snippets y llama a PrintScript queda en una sola traza.
- Manda los logs de la app a New Relic sin un recolector aparte (`application_logging.forwarding` en `newrelic.yml`).
- OpenTelemetry no nos ata a un proveedor, pero suma un collector y más configuración. Como la cuenta ya es de New Relic, no compensa.

Lo probamos el 10/11 con el agente 9.5.0 en Snippets y PrintScript (Spring Boot 4.1.1, Java 21), en local: los pedidos aparecen con el nombre del controller y la traza de crear un snippet tiene a los dos servicios con el mismo trace id.

Para sumarlo a un servicio, igual que el asset service:

1. Bajar el jar del agente en el build (una configuración de Gradle aparte, fuera del classpath) y copiarlo a la imagen junto con un `newrelic.yml`.
2. Arrancar con `-javaagent:/app/newrelic.jar`. En PrintScript, sumarlo a su `JAVA_TOOL_OPTIONS` sin pisar `-XX:MaxRAMPercentage=75`.
3. Lo secreto y lo que cambia por entorno va por variables `NEW_RELIC_*`, que ya están en `stack.yml`.

Para probar en local con el compose, usar `127.0.0.1` y no `localhost`: si hay un servicio corriendo desde el IDE en el mismo puerto, `localhost` puede ir a ese por IPv6.

#### Las VMs: el agente de infraestructura

CPU, memoria y disco de cada VM llegan con el agente de infraestructura de New Relic, que corre como contenedor (`monitoreo/compose.yml`). La VM aparece como `vm-snippet-dev` o `vm-snippet-prod`.

- **Con Docker y sin instalar nada en la VM**, como sugirió el profe. Aparece en prod sola, con el primer deploy.
- **No está en el stack**: el agente necesita `privileged` y `pid: host` para ver el host, y `docker stack deploy` no los soporta. Lo levanta `deploy.yml` con `docker compose`, después del stack. `docker compose` crea un contenedor común: si nada cambió, no lo toca; si la VM se reinicia, lo vuelve a levantar Docker.
- **Tiene permisos de root sobre la VM** (`privileged` y el socket de Docker). Es la imagen oficial de New Relic, fijada por digest.
- Usa la misma `NEW_RELIC_LICENSE_KEY` del Environment.
- La pantalla de infraestructura de New Relic solo la ve el usuario *full platform*. Los usuarios *basic* pueden consultar las métricas con NRQL: `FROM SystemSample SELECT average(cpuPercent), average(memoryUsedPercent), average(diskUsedPercent) WHERE displayName = 'vm-snippet-dev' TIMESERIES`.

#### Puntos de falla y SLO

De acá salen el SLI, el synthetic y las alertas: primero se mira qué le importa al usuario y después qué se mide (diap. 34 de la clase de observabilidad). Recorrido de `POST /api/snippets`; "cómo me entero" es lo que había el 23/11: agente en PrintScript y en el asset service, agente de infraestructura en la VM y ninguna alerta.

| # | Paso | Qué puede fallar | Cómo me entero | Propuesta |
|---|---|---|---|---|
| 1 | Navegador / UI | Error de JavaScript, la UI no carga | No me entero (lo ve el usuario) | Agente de navegador (infraestructura#49) |
| 2 | DNS y certificado | DuckDNS apunta a otra IP; certbot no renueva | No me entero hasta que no carga | [Synthetic](#synthetic-crear-leer-y-borrar) y alerta de vencimiento del certificado |
| 3 | nginx | Config rota; no arranca si un upstream no existe (`host not found`, 10/11 y 22/11) | Deploy en rojo y SSH (`docker service ps`) | Synthetic; que nginx resuelva los nombres en cada pedido |
| 4 | Auth0 | Token vencido u otro emisor (401 masivo); usuario sin rol (403); Auth0 caído | No me entero | 401/403 por minuto en Snippets, con alerta si se disparan |
| 5 | Snippets | 500, lentitud, no arranca (sin base o sin Redis) | SSH (`docker service logs`) | Agente en Snippets (snippet-service#40): 5xx y p99. Acá se mide el SLI |
| 6 | Base de Snippets | Caída, disco lleno, conexiones agotadas | SSH | Errores de base en la traza de Snippets; disco de la VM (fila 10) |
| 7 | PrintScript | Caído o lento (crear depende de `POST /validate`); rechaza el token | New Relic, si alguien entra a mirar (`printscript-dev`) | Alerta de errores y p99 |
| 8 | Permisos (con snippet-service#27) | Caído; el dueño no queda registrado | Todavía no está en el camino | Agente en Permisos; span en la traza de crear |
| 9 | Asset service y Azurite (con snippet-service#22) | Caído; el contenido no se guarda | New Relic, si alguien entra a mirar (`asset-service-dev`) | Span en la traza de crear; alerta de errores |
| 10 | La VM | Apagada, sin memoria, disco lleno | New Relic, si alguien entra a mirar (`vm-snippet-dev`) | Alertas de disco > 80 %, memoria > 90 % y host que no reporta |
| 11 | Deploy | Publish falla (429 de Maven Central, 23/11); descarga de imagen colgada (10/11); el entorno queda con la versión vieja | Mirando GitHub Actions | Notificaciones de GitHub. No entra en el SLO |

Redis no está en el camino de crear un snippet: lo usan el linteo y el formateo en segundo plano, y va en la tabla de ese flujo.

**SLI:** porcentaje de `POST /snippets` que terminan bien en menos de 1 s, medido en Snippets (`Transaction` de New Relic).

- Bien: 201, o 400 por código inválido.
- Mal: 5xx, o más de 1 s.
- Fuera de la cuenta: 401 y 403 (los cubre la alerta de la fila 4).

**SLO:** 99 % en 30 días, medido en prod. El error budget es el 1 % de los pedidos: de cada 1000 creaciones, 10 pueden fallar.

Este SLI no prueba que el snippet se pueda leer después: eso lo cubre el synthetic (crear, leer y borrar).

Decisiones y por qué:

- **1 s y 99 % son el punto de partida.** Se revisan con una semana de datos de Snippets. Es una sola VM y los deploys reinician servicios: mejor una meta que se cumpla y subirla después que bajarla.
- **El 400 por código inválido es éxito.** El SLI mide si el sistema funciona, no si el código del usuario es válido. Si no, un usuario que se equivoca mucho gastaría el error budget sin que nada esté roto.
- **Se mide en prod.** La VM de dev se apaga a propósito para ahorrar créditos, y eso no es una falla.
- **Las alertas llegan a un canal de Discord solo para alertas.** En un canal aparte no se pierden entre la charla del equipo. Ver [Alertas](#alertas).

#### Synthetic: crear, leer y borrar

Un monitor de New Relic que cada minuto **crea un snippet, lo lee y lo borra** contra dev. Prueba un flujo de negocio y no un ping: si falla, algo de ese camino está roto aunque todos los contenedores estén "arriba", que es justo lo que un healthcheck no ve.

El script está versionado en [`monitoreo/synthetic-flujo-snippet.js`](monitoreo/synthetic-flujo-snippet.js). Se edita en la web de New Relic (igual que las alertas, y por el mismo motivo: Terraform pedía una API key de usuario y un lugar donde guardar su estado), pero la versión que vale es la del repo.

| Paso | Qué prueba de verdad |
|---|---|
| Token de Auth0 (Client Credentials) | Que Auth0 responde y que la app del monitor sigue autorizada en la API |
| `POST /api/snippets` | nginx, el certificado, Snippets, PrintScript (valida el código), el asset service (guarda el contenido), Permisos (registra al dueño) y Postgres |
| `GET /api/snippets/{id}` | Que el contenido vuelva **igual** al que se guardó. Es lo que falla si el asset service pierde el contenido o lo devuelve con otra codificación |
| `DELETE /api/snippets/{id}` | Borrar la fila, el contenido y los accesos. Y es la limpieza: sin esto se acumularía un snippet por minuto |

**Credenciales** (Synthetics → Secure credentials). Ninguna va en el repo:

| Nombre | Qué es |
|---|---|
| `SNIPPET_API_URL` | `https://<dominio>/api` del entorno |
| `SNIPPET_AUTH0_DOMAIN` | El dominio de Auth0, sin `https://` |
| `SNIPPET_AUTH0_AUDIENCE` | La audiencia de la API |
| `SNIPPET_CLIENT_ID` / `SNIPPET_CLIENT_SECRET` | La app M2M **propia del synthetic** |

**Cómo recrearlo:** Synthetics → Create monitor → *Scripted API*, pegar el script, período **1 minuto**, una sola ubicación (con varias, cada una crea y borra su snippet y se multiplican las llamadas), y agregarlo a la política `snippet-searcher-dev` para que avise por el mismo canal de Discord que el resto.

Por qué así:

- **App M2M propia y no la de Snippets.** El synthetic corre fuera de Snippets y es otro consumidor: si se le filtra el secret, se rota sin tocar los servicios. Necesita **los dos scopes** (`read:snippets` para leer y `write:snippets` para crear y borrar), a diferencia de la app M2M de Snippets, que con `read:snippets` le alcanza.
- **El `sub` del token es el client id (`<client-id>@clients`) y no un usuario, y así está bien.** Era la pregunta abierta del issue. Desde permissions-service#28, Permisos autoriza con el `sub`: para registrar o borrar accesos hay que ser el dueño del snippet. El synthetic **es dueño de los snippets que crea**, así que los tres pasos pasan sin tocar nada: al crear se registra como dueño de un snippet que no tiene otro, al leer alcanza la columna de dueño de Snippets, y al borrar es el dueño. No hace falta un scope especial ni una excepción.
- **Es distinto del caso de snippet-service#50.** Ahí Snippets actúa **en nombre de otro** (los trabajos en segundo plano sobre snippets de usuarios), y para eso sí hay que decidir algo: permissions-service#31.
- **El borrado va en un `finally`.** Si falla la lectura, el snippet igual se borra. Con un monitor por minuto, un snippet huérfano por corrida llena la base en un día.
- **Los snippets del synthetic son de su propio dueño**, así que no aparecen en el listado de nadie: el `owner_id` es el client id y ningún usuario real lo tiene.
- **El script usa `$http` con promesas** porque el flujo son cuatro pedidos en orden y con callbacks queda una pirámide. Eso pide el runtime de Node 16+ de New Relic; con el runtime viejo hay que pasarlo a callbacks anidados.

#### Alertas

Las alertas se configuran en la web de New Relic (Alerts), no con código: Terraform pedía una API key de usuario como secret y un lugar donde guardar su estado, una herramienta más para mantener. Lo que importa queda acá: qué mide cada alerta, por qué y cómo recrearla si alguien la borra.

Cómo se arma, de adentro hacia afuera:

| Pieza | Qué es | La nuestra |
|---|---|---|
| Condición | Una consulta NRQL y cuándo abre una alerta | Las de la tabla de abajo |
| Política | Agrupa condiciones | `snippet-searcher-dev`, con "One issue per condition": si caen la VM y un servicio, llegan dos avisos y no uno mezclado |
| Workflow | A quién se le avisa: filtra por política y manda a un destino | `Discord - snippet-searcher-dev`: política `snippet-searcher-dev`, avisa al abrir y al cerrar |
| Destino | Adónde llega | Webhook del canal `#vm-and-services-dev` del servidor de Discord "Alertas VM". La URL del webhook es secreta: quien la tenga puede escribir en el canal |

La condición dice **qué** está mal y el workflow **a quién** avisar: para prod se crean las mismas condiciones en una política `snippet-searcher-prod` y su propio workflow, sin tocar las consultas.

**Condiciones**

| Condición | NRQL | Abre una alerta si | Qué hacer |
|---|---|---|---|
| VM dev sin reportar (apagada o sin red) | `SELECT count(*) FROM SystemSample WHERE displayName = 'vm-snippet-dev'` | No llegan datos durante 5 minutos | Si nadie la apagó a propósito, prenderla con el workflow [VMs](#encender-y-apagar-las-vms) y mirar en Azure si hubo un problema |
| Servicio dev sin responder | `SELECT count(*) FROM Transaction WHERE appName IN ('snippets-dev', 'permissions-dev', 'printscript-dev') FACET appName` | Un servicio no manda transacciones durante 5 minutos | En la VM, `docker service ps snippet-searcher_<servicio>` y `docker service logs snippet-searcher_<servicio>` |

En las dos: ventana de 1 minuto, *Event flow*, delay de 2 minutos, sin umbral estático y con un umbral de **pérdida de señal** de 5 minutos que abre una alerta crítica, sin cerrar las demás abiertas. La descripción de cada condición dice qué hacer y quién es el dueño, y tiene un Runbook URL a este README.

Por qué así:

- **Pérdida de señal y no un umbral.** Con la VM apagada no llega ningún dato, y un umbral como "menos de 1" compara datos que no existen: nunca dispara. La pérdida de señal mide la ausencia.
- **Las transacciones de los healthchecks son la señal de vida.** Swarm le pega a `/actuator/health/readiness` cada 10 s, así que un servicio vivo manda unas 6 transacciones por minuto aunque nadie lo use. Por eso cada servicio tiene que tener `HEALTHCHECK`: PrintScript entró a esta alerta cuando lo sumó (printscript-service#45).
- **5 minutos.** Menos, y un corte de red de un minuto ya avisa. Si Swarm reinicia un contenedor caído, vuelve en segundos y no hay alerta: se arregló solo, no hay nada que hacer.
- **`FACET appName`**: una sola condición para los tres servicios, con una señal por servicio. La tarjeta dice cuál se cayó.

**El mensaje de Discord**

Discord rechaza un JSON que no tenga sus campos (`content` o `embeds`), así que el webhook lleva esta plantilla (workflow → canal Discord → *Edit notification message*). `{{ json … }}` mete cada valor ya escapado, y los `{{#if}}` evitan mandar `null`, que Discord rechaza:

```json
{
  "username": "New Relic",
  "embeds": [
    {
      "title": {{ json annotations.title.[0] }},
      "url": {{ json issuePageUrl }},
      {{#if accumulations.conditionDescription}}"description": {{ json accumulations.conditionDescription.[0] }},{{/if}}
      "fields": [
        { "name": "Estado", "value": {{ json state }}, "inline": true },
        { "name": "Prioridad", "value": {{ json priority }}, "inline": true },
        { "name": "Condición", "value": {{ json accumulations.conditionName.[0] }} }
        {{#if annotations.wildcard}}, { "name": "Servicio", "value": {{ json annotations.wildcard.[0] }} }{{/if}}
        {{#if accumulations.runbookUrl}}, { "name": "Runbook", "value": {{ json accumulations.runbookUrl.[0] }} }{{/if}}
      ]
    }
  ]
}
```

- La descripción sale de `accumulations.conditionDescription` y no de `annotations.description`: en las alertas de pérdida de señal, esa trae un texto automático de New Relic.
- `annotations.wildcard` es el valor del `FACET`: el servicio que se cayó.
- En la descripción, los comandos van entre backticks: Discord toma el `_` como itálica.

**Cómo probarlas** (probadas en dev el 26 y 27/11)

| Alerta | Cómo dispararla | Llega |
|---|---|---|
| VM sin reportar | Apagar la VM con el workflow VMs | Unos 6 minutos después; al prenderla, la de cierre |
| Servicio sin responder | En la VM, `docker service scale snippet-searcher_printscript=0` | Unos 6 minutos después; con `=1`, la de cierre |

## Auth0

Todo el equipo usa un solo tenant de Auth0 (`dev-m32ysp7h6y2qyjn0`, región US) para local, dev y prod. Los integrantes del equipo son miembros del tenant: entran al dashboard con su propia cuenta.

| Qué | Configuración |
|---|---|
| API `Snippet Searcher API` | Identifier `https://snippet-searcher-api` (es `AUTH0_AUDIENCE`), RS256, RBAC activado, permisos `read:snippets` y `write:snippets` |
| Rol `snippet-user` | Tiene los dos permisos de la API |
| App `Snippet Searcher UI` | SPA. Callback, Logout y Web Origins de local, dev y prod |
| Action `Rol snippet-user al primer login` | Trigger Post Login. Le asigna `snippet-user` a cada usuario nuevo (ver abajo) |
| App `Asignar rol automático (Action)` | Machine to Machine, autorizada en la Management API solo con `create:role_members`. La usa la Action; sus credenciales están en los secrets de la Action, no en GitHub |
| App `Snippets (M2M)` | Machine to Machine, autorizada en la Management API solo con `read:users`. Es para listar usuarios al compartir un snippet (PPC-INGSIS/snippet-service#29) |
| Duración del token de la API | 1 h (3600 s), acordada con el equipo. Para bajarla a 15 min, primero la UI tiene que renovar el token con refresh tokens |

Cada app M2M tiene solo el permiso que usa: si se filtra el secreto de Snippets, se pueden leer usuarios, pero no asignar roles.

### Rol automático

La Action corre en cada login, pero solo actúa en el **primero** (`logins_count` igual a 1). Así, si a alguien se le saca el rol, no lo vuelve a recibir en el próximo login.

- Los usuarios que ya existían antes de la Action no la pasan: el rol se les asigna a mano (User Management → Users → el usuario → Roles).
- Si la asignación falla, el login sigue y el error queda en Monitoring → Logs, en el evento del login. Ese usuario necesita el rol a mano.
- Auth0 calcula los permisos del token antes de correr la Action. Por eso, en el primer login, la Action también agrega `read:snippets` y `write:snippets` al token de la API: si no, ese primer token saldría sin permisos.

### Credenciales de la Management API para Snippets

Están en los Environments `dev` y `prod`: la variable `AUTH0_MANAGEMENT_CLIENT_ID` y el secret `AUTH0_MANAGEMENT_CLIENT_SECRET`. El dominio es el mismo `AUTH0_DOMAIN`. `deploy.yml` se las pasa al stack, y Snippets las usa en `GET /users` (snippet-service#29). Llegan como variables de entorno y no como secrets de Swarm, así se pueden rotar desde GitHub sin tocar la VM.

En local son opcionales: sin ellas Snippets arranca, pero `GET /users` falla. Para probarlo, copiá los valores de `Snippets (M2M)` a tu `.env`.

## Entrada: nginx y HTTPS

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
