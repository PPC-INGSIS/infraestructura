# Auth0

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

## Rol automático

La Action corre en cada login, pero solo actúa en el **primero** (`logins_count` igual a 1). Así, si a alguien se le saca el rol, no lo vuelve a recibir en el próximo login.

- Los usuarios que ya existían antes de la Action no la pasan: el rol se les asigna a mano (User Management → Users → el usuario → Roles).
- Si la asignación falla, el login sigue y el error queda en Monitoring → Logs, en el evento del login. Ese usuario necesita el rol a mano.
- Auth0 calcula los permisos del token antes de correr la Action. Por eso, en el primer login, la Action también agrega `read:snippets` y `write:snippets` al token de la API: si no, ese primer token saldría sin permisos.

## Credenciales de la Management API para Snippets

Están en los Environments `dev` y `prod`: la variable `AUTH0_MANAGEMENT_CLIENT_ID` y el secret `AUTH0_MANAGEMENT_CLIENT_SECRET`. El dominio es el mismo `AUTH0_DOMAIN`. `deploy.yml` se las pasa al stack, y Snippets las usa en `GET /users` (snippet-service#29). Llegan como variables de entorno y no como secrets de Swarm, así se pueden rotar desde GitHub sin tocar la VM.

En local son opcionales: sin ellas Snippets arranca, pero `GET /users` falla. Para probarlo, copiá los valores de `Snippets (M2M)` a tu `.env`.
