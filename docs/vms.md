# Encender y apagar las VMs

Hay una VM por entorno, en Azure:

| Entorno | VM | Rama que se deploya ahí |
|---|---|---|
| dev | `vm-snippet-dev` | `dev` |
| prod | `vm-snippet-prod` | `main` |

Las VMs cuestan mientras están prendidas, así que **se prenden para trabajar y se apagan al terminar**. Además, se apagan solas todos los días a las 23:00 (hora de Argentina) por si alguien se olvida.

## Cómo

1. Pestaña **Actions** → workflow **VMs** → **Run workflow**.
2. Elegir la VM (`dev` o `prod`) y la acción (`encender` o `apagar`).
3. El último paso, **Estado**, muestra cómo quedó: `VM running` o `VM deallocated`.
4. **Solo prod:** reanudar el [synthetic](observabilidad.md#synthetic-crear-leer-y-borrar) después de prenderla y pausarlo al apagarla. Si se apaga sola a las 23:00, pausarlo al día siguiente: hasta entonces su alerta queda abierta, y es justamente lo que avisa que falta pausarlo.

Puede usarlo cualquiera con permiso de escritura en este repo.

## Cómo se conecta con Azure

El workflow entra a Azure con OIDC: no hay ninguna contraseña de Azure guardada en GitHub.

- En Azure hay una identidad (`gh-snippet-searcher-infra`) que solo acepta workflows que corren desde la rama `main` de este repo.
- Esa identidad tiene el rol **Colaborador de la máquina virtual** solo sobre el grupo de recursos `rg-snippet-searcher`.
- Los secrets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` y `AZURE_SUBSCRIPTION_ID` son identificadores, no contraseñas. Están como secrets para que no aparezcan en los logs, que en este repo son públicos.

## Si falla

| Error | Causa probable |
|---|---|
| `AADSTS700213: No matching federated identity` | La credencial federada no coincide con el repo o la rama. Se corrió desde una rama que no es `main`. |
| Se queda colgado en `Attempting Azure CLI login` y corta a los 5 minutos | La identidad no tiene el rol correcto sobre el grupo de recursos. Revisar en Azure: IAM → Comprobar acceso. |
| `AuthorizationFailed` | Mismo caso: falta el rol, o se acaba de asignar y todavía no se propagó (esperar unos minutos). |
