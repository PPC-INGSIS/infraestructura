# Infraestructura

Configuración para levantar **Snippet Searcher** completo: todos los servicios juntos, en una misma red de Docker, para que se puedan hablar entre ellos.

No tiene código ni build. Son archivos de configuración.

## Estado

Esqueleto. El `docker-compose.yml` todavía no levanta ningún servicio: cada uno se agrega cuando tenga su imagen disponible.

## Por qué un repo aparte

Cada servicio tiene su propio `docker-compose.yml`, que levanta solo lo que ese servicio necesita para desarrollarse (su base de datos). Este repo levanta **el sistema entero**.

Tiene que ser un solo archivo porque Docker Compose crea **una red por archivo**: los contenedores del mismo compose se encuentran por nombre de servicio (`http://printscript:8080`). Con un compose por servicio, quedarían en redes separadas y no se verían.

## Qué va a levantar

| Servicio | Qué es | De quién |
|---|---|---|
| Snippets | Puerta de entrada de todo lo que es snippet | Nosotros |
| Permisos | Quién puede ver o editar qué | Nosotros |
| PrintScript | Valida, formatea, lintea y ejecuta | Nosotros |
| Snippet Store | Guarda y lee el código de los snippets | La cátedra |
| Una base Postgres por servicio propio | Cada servicio es dueño de sus datos | — |

## Requisitos

- Docker

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

## Cómo agregar un servicio

1. Copiar la plantilla que está comentada en `docker-compose.yml`.
2. Usar el puerto que le corresponde en la tabla de arriba.
3. Si necesita variables propias, agregarlas a `.env.example` con un valor por defecto.
