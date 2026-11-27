# Despliegue a las VMs

Las VMs corren un Docker Swarm de un solo nodo con el `stack.yml`: los mismos servicios del compose más la UI, nginx y certbot, sin puertos publicados salvo nginx (80 y 443), y con la sección `deploy:` de Swarm. El stack es el mismo archivo en dev y en prod; lo que cambia entre ambientes es la versión de cada imagen, que sale de la rama, y el dominio.

| Archivo | Para qué |
|---|---|
| `stack.yml` | Los servicios tal como corren en las VMs. Las imágenes que no construimos (`asset-service`, `azurite`, `postgres`, `redis`, `nginx` y `certbot`) están fijadas por digest, así que solo cambian si alguien cambia este archivo en un PR |
| `versiones.env` | El SHA de la imagen de cada servicio. Se llama igual en `dev` y en `main` |
| `nginx/default.conf.template` | La config de nginx (ver [Entrada: nginx y HTTPS](nginx-y-https.md)) |
| `nginx/40-certificado.sh` | Hace que nginx espere el certificado al arrancar y se recargue cuando cambia |
| `certbot/certbot.sh` | Consigue el certificado y lo renueva |
| `.github/workflows/deploy.yml` | Despliega el stack en la VM del entorno |

## Cómo llega el código a una VM

Este repo usa gitflow, igual que los servicios: `dev` es el entorno dev y `main` es prod.

- Todos los PRs de este repo van a **`dev`**. `main` solo recibe el PR de `dev` a `main`.
- Cuando un servicio mergea a su `dev`, se publica la imagen y un bot (`ppc-ingsis-infra-updater`) commitea el SHA nuevo en `versiones.env` de la rama `dev` de este repo. Ese commit despliega a dev solo.
- El **release a prod** es el PR de `dev` a `main`. Lleva el mismo `versiones.env`, así que prod corre exactamente la imagen que se probó en dev: la imagen se construye una sola vez, en `dev`.
- La rama decide el entorno: lo que cambia en `main` se despliega a prod y lo que cambia en `dev` se despliega a dev. El workflow no deja desplegar prod desde otra rama.
- `versiones.env` lo escribe el bot. No se edita a mano, salvo para arreglar algo.

## Reglas de las ramas

`dev` y `main` tienen reglas (Settings → Rules → Rulesets):

- Todo entra por PR: no se puede hacer push directo. No hace falta aprobación.
- No se pueden borrar ni hacer force push.
- En `dev`, el bot es la excepción: hace push directo de `versiones.env`, sin PR.

GitHub propone `main` como base de los PRs. Antes de crear uno, cambiar la base a `dev`.

## Cómo se despliega

El workflow **Deploy** corre cuando cambia `versiones.env`, `stack.yml`, algo en `nginx/` o algo en `certbot/`, en `dev` o en `main`. También se puede lanzar a mano: pestaña **Actions** → **Deploy** → **Run workflow**, eligiendo la rama del entorno (`dev` para dev, `main` para prod).

1. El runner de GitHub se conecta por SSH al Docker de la VM del entorno. Las claves y el host están en los Environments `dev` y `prod` del repo, junto con lo que se pasa al stack: las variables `DOMINIO` (nginx), `AUTH0_DOMAIN` y `AUTH0_AUDIENCE` (Snippets, PrintScript y Permisos) y `AUTH0_MANAGEMENT_CLIENT_ID` (Snippets), y los secrets `NEW_RELIC_LICENSE_KEY` (ver [New Relic](observabilidad.md)) y `AUTH0_MANAGEMENT_CLIENT_SECRET` (ver [Auth0](auth0.md)). Si falta alguno, el deploy corta con `falta_definir_<VARIABLE>`.
2. Corre `docker stack deploy` con los tags de `versiones.env`. Swarm recrea solo los servicios cuya definición cambió.
3. Espera hasta 5 minutos a que todos los servicios estén en N/N, y al final imprime el estado de cada tarea con su edad.
4. Borra las imágenes que ya no usa ningún contenedor. Sin esto, cada deploy dejaba las imágenes anteriores en la VM y el disco subía sin bajar nunca (se vio en el dashboard: un punto por deploy). El log muestra `docker system df` antes y después.

Cómo leer ese estado: un servicio que el deploy no tocó conserva la edad de su tarea. Si una tarea anterior terminó en `Shutdown`, la reemplazó un deploy; si terminó en `Failed`, se cayó (es normal al prender la VM, mientras los servicios se esperan entre sí).

Con la VM apagada el deploy falla en el paso **Verificar que la VM responde**. Se prende con el workflow **VMs** y se vuelve a correr (**Re-run jobs**) sobre el run más reciente: un re-run usa el commit de ese run, así que uno viejo desplegaría versiones viejas.

## Límites de memoria

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

## Volver a una versión anterior (rollback)

Lo que corre en la VM es lo que dice `versiones.env`. Para volver atrás un servicio, se revierte en git el commit que le cambió el tag:

```bash
git checkout dev && git pull
git checkout -b revert/<servicio>
git revert <SHA del commit del bot>
git push -u origin revert/<servicio>
```

Y un PR a `dev`. Al mergearlo, el deploy vuelve a la imagen anterior (la misma, con el mismo digest) y solo reemplaza ese servicio. Como cada deploy borra las imágenes que no se usan, la anterior ya no está en la VM: Swarm la vuelve a bajar de ghcr.io, así que el rollback tarda lo que tarda esa descarga. El próximo merge del servicio vuelve a subir el tag con el bot.

No usar `docker service rollback` en la VM: la VM quedaría distinta de `versiones.env`, y el próximo deploy de cualquier servicio volvería a poner la imagen de git.
