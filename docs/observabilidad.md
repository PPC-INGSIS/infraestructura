# Observabilidad: New Relic

Cada servicio manda sus datos a la cuenta de New Relic del equipo con el nombre `<servicio>-<entorno>` (por ejemplo `snippets-dev`), para que dev y prod no se mezclen.

- La key es de tipo *Ingest - License*: solo sirve para **mandar** datos, no para leerlos. Hay una por entorno (`snippet-searcher-dev` y `snippet-searcher-prod`), cargada como secret `NEW_RELIC_LICENSE_KEY` en cada Environment. Si se filtra una, se borra y se crea otra sin tocar el otro entorno. La key original de la cuenta no se usa porque no se puede borrar.
- Llega a los servicios como variable de entorno y no como secret de Swarm: el agente de Java arranca antes que Spring y no lee `/run/secrets/`.
- Las variables están en todos los servicios de Spring, pero solo hacen algo en los que traen el agente en su imagen (por ahora, `asset-service`).

## Cómo llegan los datos: el agente de Java

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

## Las VMs: el agente de infraestructura

CPU, memoria y disco de cada VM llegan con el agente de infraestructura de New Relic, que corre como contenedor (`monitoreo/compose.yml`). La VM aparece como `vm-snippet-dev` o `vm-snippet-prod`.

- **Con Docker y sin instalar nada en la VM**, como sugirió el profe. Aparece en prod sola, con el primer deploy.
- **No está en el stack**: el agente necesita `privileged` y `pid: host` para ver el host, y `docker stack deploy` no los soporta. Lo levanta `deploy.yml` con `docker compose`, después del stack. `docker compose` crea un contenedor común: si nada cambió, no lo toca; si la VM se reinicia, lo vuelve a levantar Docker.
- **Tiene permisos de root sobre la VM** (`privileged` y el socket de Docker). Es la imagen oficial de New Relic, fijada por digest.
- Usa la misma `NEW_RELIC_LICENSE_KEY` del Environment.
- La pantalla de infraestructura de New Relic solo la ve el usuario *full platform*. Los usuarios *basic* pueden consultar las métricas con NRQL: `FROM SystemSample SELECT average(cpuPercent), average(memoryUsedPercent), average(diskUsedPercent) WHERE displayName = 'vm-snippet-dev' TIMESERIES`.

## Puntos de falla y SLO

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
| 10 | La VM | Apagada, sin memoria, disco lleno (hasta el 27/11 crecía con cada deploy: ahora el deploy borra las imágenes que no se usan) | Alertas de New Relic: disco > 80 %, memoria > 90 % y VM que no reporta | Hecho (ver [Alertas](#alertas)) |
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

## Synthetic: crear, leer y borrar

Un monitor de New Relic que cada 6 horas **crea un snippet, lo lee y lo borra** contra prod. Prueba un flujo de negocio y no un ping: si falla, algo de ese camino está roto aunque todos los contenedores estén "arriba", que es justo lo que un healthcheck no ve.

El script está versionado en [`monitoreo/synthetic-flujo-snippet.js`](../monitoreo/synthetic-flujo-snippet.js). Se edita en la web de New Relic (igual que las alertas, y por el mismo motivo: Terraform pedía una API key de usuario y un lugar donde guardar su estado), pero la versión que vale es la del repo.

| Paso | Qué prueba de verdad |
|---|---|
| Token de Auth0 (Client Credentials) | Que Auth0 responde y que la app del monitor sigue autorizada en la API |
| `POST /api/snippets` | nginx, el certificado, Snippets, PrintScript (valida el código), el asset service (guarda el contenido), Permisos (registra al dueño) y Postgres |
| `GET /api/snippets/{id}` | Que el contenido vuelva **igual** al que se guardó. Es lo que falla si el asset service pierde el contenido o lo devuelve con otra codificación |
| `DELETE /api/snippets/{id}` | Borrar la fila, el contenido y los accesos. Y es la limpieza: sin esto se acumularía un snippet por corrida |

**Credenciales** (Synthetics → Secure credentials). Ninguna va en el repo:

| Nombre | Qué es |
|---|---|
| `SNIPPET_API_URL` | `https://<dominio>/api` del entorno |
| `SNIPPET_AUTH0_DOMAIN` | El dominio de Auth0, sin `https://` |
| `SNIPPET_AUTH0_AUDIENCE` | La audiencia de la API |
| `SNIPPET_CLIENT_ID` / `SNIPPET_CLIENT_SECRET` | La app M2M **propia del synthetic** |

**Cómo recrearlo:** Synthetics → Create monitor → *Endpoint availability* (*Scripted API*), runtime de Node más nuevo, pegar el script, período **6 horas**, una sola ubicación (con varias, cada una crea y borra su snippet y se multiplican las corridas), con las credenciales de prod y en la política de alertas de prod.

**Corre solo mientras prod está prendida.** Prod se prende para probar y para la defensa, y pasa apagada la mayor parte del mes: si el monitor siguiera corriendo, su alerta quedaría abierta casi siempre y el canal de Discord dejaría de significar algo. Por eso se **reanuda al prender prod y se pausa al apagarla** (Synthetics → Monitors → `...` del monitor → *Monitor settings* → *Monitor enabled*), como parte de los pasos de [Encender y apagar las VMs](vms.md). No se automatizó desde el workflow VMs porque pedía una API key de usuario de New Relic como secret, el mismo motivo por el que se descartó Terraform. Para ver una corrida en el momento, por ejemplo en la defensa, el monitor tiene *Run check*, que no espera al período.

**Dev sirve para probarlo, no para dejarlo corriendo.** Antes de pasarlo a prod se crea el monitor con las credenciales de dev, se verifica que pase y se **pausa** (o se borra). No queda activo en dev por dos motivos: la VM de dev pasa apagada buena parte del tiempo y cada corrida de esas horas fallaría sin que haya nada roto, y cada corrida gasta cupo (ver abajo) que necesita el de prod.

Por qué así:

- **Cada 6 horas y no cada minuto, por dos cupos gratuitos que se cuentan por mes.** New Relic da 500 corridas de synthetics con script, y Auth0 da 1000 tokens M2M **para todo el tenant** (dev y prod comparten tenant). Cada corrida pide un token nuevo, porque New Relic arranca cada corrida de cero y no hay dónde guardarlo entre una y otra. Cada minuto serían unas 43.200 corridas y 43.200 tokens por mes. El de Auth0 es el que importa: cuando se acaba, Snippets tampoco puede sacar su token para la Management API y deja de andar la búsqueda de usuarios al compartir. New Relic no ofrece períodos entre 1 hora y 6 horas, y la cuenta se hace como si el monitor nunca se pausara: es lo que pasa si alguien se olvida. Cada hora serían 720 por mes, más que las 500 (New Relic lo marca al crearlo); cada 6 horas son 120, imposible pasarse. Que corra poco no es un problema: prod se prende para sesiones en las que alguien está probando a mano, y para ver una corrida en el momento está *Run check*.
- **App M2M propia y no la de Snippets.** El synthetic corre fuera de Snippets y es otro consumidor: si se le filtra el secret, se rota sin tocar los servicios. Necesita **los dos scopes** (`read:snippets` para leer y `write:snippets` para crear y borrar), a diferencia de la app M2M de Snippets, que con `read:snippets` le alcanza.
- **El `sub` del token es el client id (`<client-id>@clients`) y no un usuario, y así está bien.** Era la pregunta abierta del issue. Desde permissions-service#28, Permisos autoriza con el `sub`: para registrar o borrar accesos hay que ser el dueño del snippet. El synthetic **es dueño de los snippets que crea**, así que los tres pasos pasan sin tocar nada: al crear se registra como dueño de un snippet que no tiene otro, al leer alcanza la columna de dueño de Snippets, y al borrar es el dueño. No hace falta un scope especial ni una excepción.
- **Es distinto del caso de snippet-service#50.** Ahí Snippets actúa **en nombre de otro** (los trabajos en segundo plano sobre snippets de usuarios), y para eso sí hay que decidir algo: permissions-service#31.
- **El borrado va en un `finally`.** Si falla la lectura, el snippet igual se borra. Un snippet huérfano por corrida se acumula para siempre: nadie los ve en su listado y nada los limpia.
- **Los snippets del synthetic son de su propio dueño**, así que no aparecen en el listado de nadie: el `owner_id` es el client id y ningún usuario real lo tiene.
- **El script usa `$http` con promesas** porque el flujo son cuatro pedidos en orden y con callbacks queda una pirámide.
- **El JSON se arma y se lee a mano** (`JSON.stringify` al mandar, `JSON.parse` al leer) en vez de usar la opción `json` de `$http`. New Relic dejó de soportar el runtime de Node 16 en noviembre de 2026, y en los runtimes nuevos `$http` está hecho sobre otra librería donde `json` y `body` no se pueden usar juntos: el script original fallaba en el primer pedido con *The `body`, `json` and `form` options are mutually exclusive*. Mandar texto y parsear la respuesta anda igual en cualquier runtime.

## Alertas

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
| VM dev sin reportar (apagada o sin red) | `SELECT count(*) FROM SystemSample WHERE displayName = 'vm-snippet-dev'` | No llegan datos durante 5 minutos | Si nadie la apagó a propósito, prenderla con el workflow [VMs](vms.md) y mirar en Azure si hubo un problema |
| Servicio dev sin responder | `SELECT count(*) FROM Transaction WHERE appName IN ('snippets-dev', 'permissions-dev', 'printscript-dev') FACET appName` | Un servicio no manda transacciones durante 5 minutos | En la VM, `docker service ps snippet-searcher_<servicio>` y `docker service logs snippet-searcher_<servicio>` |
| VM dev con el disco arriba del 80 % | `SELECT max(diskUsedPercent) FROM SystemSample WHERE displayName = 'vm-snippet-dev'` | Pasa el 80 % durante 5 minutos | Mirar los dos `docker system df` del paso "Borrar imágenes que ya no se usan" del último deploy. Si son imágenes, correr el deploy a mano; si son volúmenes, ver qué creció en Postgres o Azurite |
| VM dev con la memoria arriba del 90 % | `SELECT max(memoryUsedPercent) FROM SystemSample WHERE displayName = 'vm-snippet-dev'` | Pasa el 90 % durante 5 minutos | En el dashboard, desde cuándo sube. En la VM, `docker stats --no-stream` y `docker service ps snippet-searcher_<servicio>` para ver si alguno se reinicia por llegar a su [límite](despliegue.md#límites-de-memoria) |

Las dos primeras: ventana de 1 minuto, *Event flow*, delay de 2 minutos, sin umbral estático y con un umbral de **pérdida de señal** de 5 minutos que abre una alerta crítica, sin cerrar las demás abiertas. Las de disco y memoria son al revés: ventana de 1 minuto, **umbral estático** crítico sostenido 5 minutos y sin pérdida de señal. La descripción de cada condición dice qué hacer y quién es el dueño, y tiene un Runbook URL a este documento.

Por qué así:

- **Pérdida de señal y no un umbral.** Con la VM apagada no llega ningún dato, y un umbral como "menos de 1" compara datos que no existen: nunca dispara. La pérdida de señal mide la ausencia.
- **Las transacciones de los healthchecks son la señal de vida.** Swarm le pega a `/actuator/health/readiness` cada 10 s, así que un servicio vivo manda unas 6 transacciones por minuto aunque nadie lo use. Por eso cada servicio tiene que tener `HEALTHCHECK`: PrintScript entró a esta alerta cuando lo sumó (printscript-service#45).
- **5 minutos.** Menos, y un corte de red de un minuto ya avisa. Si Swarm reinicia un contenedor caído, vuelve en segundos y no hay alerta: se arregló solo, no hay nada que hacer.
- **`FACET appName`**: una sola condición para los tres servicios, con una señal por servicio. La tarjeta dice cuál se cayó.
- **Disco y memoria sin pérdida de señal.** Con la VM apagada no llegan datos, y un umbral estático sin datos no dispara: el apagado ya lo avisa "VM dev sin reportar", así que estas dos no suman avisos cuando se apaga la VM.
- **Disco al 80 %.** Es lo que proponía la fila 10 de [Puntos de falla](#puntos-de-falla-y-slo). El disco es de unos 30 GB: antes de que el deploy borrara las imágenes viejas subía un punto o dos por deploy (del 53 al 60 % en una tarde del 27/11) y la limpieza lo bajó al 27 %. El 80 % deja varios GB de margen para reaccionar.
- **Memoria al 90 %.** Los límites de los servicios suman unos 5,3 GiB de 7,7 (alrededor del 69 %) y en reposo la VM está en un 33 %. Pasar el 90 % es que algo usa más de lo asignado, o algo de afuera del stack. Más bajo, avisaría en cada deploy, cuando el contenedor nuevo y el viejo conviven un rato (`order: start-first`).
- **`max` y no `average`.** Si hay más de un disco, importa el más lleno. Los 5 minutos evitan avisar por un pico corto, como un deploy bajando imágenes antes de borrar las viejas.

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
| Disco y memoria | No se dispararon a propósito: llenar el disco o la memoria de la VM rompería el resto. Para probar el aviso, el workflow tiene *Test notification* | — |

## Dashboard

En New Relic: **Dashboards → `Snippet Searcher - dev`**. Igual que las alertas, se arma en la web; las consultas que valen son las de acá.

| Gráfico | Qué responde | Consulta |
|---|---|---|
| Latencia p99 por servicio (s) | ¿Cuánto tarda el 1 % más lento de los pedidos? | `SELECT percentile(duration, 99) FROM Transaction WHERE appName IN (…) AND name != 'WebTransaction/SpringController/OperationHandler/handle' FACET appName TIMESERIES` |
| Tráfico por servicio (pedidos/min) | ¿Cuánto se usa cada servicio? | `SELECT rate(count(*), 1 minute) FROM Transaction WHERE … FACET appName TIMESERIES` |
| Errores del servidor (% de 5xx) | ¿Qué parte de los pedidos falla por culpa nuestra? | `SELECT percentage(count(*), WHERE http.statusCode >= 500) FROM Transaction WHERE … FACET appName TIMESERIES` |
| VM dev: CPU, memoria y disco (%) | ¿Cuánto margen le queda a la VM? | `SELECT average(cpuPercent), average(memoryUsedPercent), max(diskUsedPercent) FROM SystemSample WHERE displayName = 'vm-snippet-dev' TIMESERIES` |
| VM dev: ¿reporta? | ¿Está viva la VM? | `SELECT count(*) FROM SystemSample WHERE displayName = 'vm-snippet-dev' SINCE 2 minutes ago` |

`appName IN (…)` es `('snippets-dev', 'permissions-dev', 'printscript-dev')`. Los tres primeros gráficos llevan el mismo `WHERE`.

Por qué así:

- **Los healthchecks se sacan por el nombre de la transacción y no por la URL.** El agente nombra la transacción por el controlador que la atiende, no por la ruta: `/actuator/health/readiness` aparece como `OperationHandler/handle`, así que un `name NOT LIKE '%actuator%'` no saca nada. Y hay que sacarlos: Swarm le pega a cada servicio cada 10 s, unas 6 transacciones por minuto, que en dev son el 80 % del total. Con ellos adentro, el tráfico marca 6 pedidos por minuto con la app vacía y un 5xx real se ve cinco veces más chico.
- **Errores son solo los 5xx.** Un 401 (token vencido) o un 400 (pedido mal armado) es el servicio rechazando bien algo del cliente. Es el mismo criterio que el SLO: contar solo lo que depende de nosotros.
- **Huecos en el gráfico de errores no son 0 %.** Son minutos sin pedidos: el porcentaje de cero pedidos no existe, y New Relic no lo dibuja.
- **El p99 casi no cambia al sacar los healthchecks**: en un percentil alto mandan los pedidos lentos. Donde sí cambia todo es en tráfico y errores, donde cada pedido cuenta igual.
- **El estado de la VM cuenta muestras recientes en vez de mirar la última.** `latest(timestamp)` llegó a mostrar "hace 14 minutos" con la VM reportando cada 5 s; un conteo que da 0 cuando no llega nada no se puede leer mal. Este gráfico ignora el selector de tiempo del dashboard: con "última semana" contaría miles aunque la VM esté apagada.
- **Las horas se ven en el huso de cada usuario de New Relic** (*User preferences → Time zone*). Por defecto es UTC, tres horas adelante.

Lo que se vio al armarlo (27/11), para seguir:

- **El primer pedido después de un rato sin uso tarda unos 3,5 s** (`GET /snippets`), con o sin deploy antes. Falta ver en la traza de esa transacción dónde se va el tiempo.
- **El disco sube en cada deploy y no baja**: el workflow de deploy no borra las imágenes viejas. Falta una limpieza y una alerta de disco.

Falta del issue #51: el synthetic (cuando exista el monitor de prod), el largo del stream de Redis y el lag del consumidor (ningún agente instalado lo manda), y el mismo dashboard para prod.
