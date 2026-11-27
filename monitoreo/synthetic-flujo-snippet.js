/*
 * Synthetic de New Relic: crea un snippet, lo lee y lo borra (infraestructura #50).
 *
 * Prueba un flujo de negocio y no un ping: pasa por nginx, Auth0, Snippets, PrintScript (valida el
 * codigo), el asset service (guarda el contenido), Postgres y Permisos. Si falla, algo de ese
 * camino esta roto aunque todos los contenedores esten "arriba", que es justo lo que un healthcheck
 * no ve.
 *
 * Va en un monitor de tipo "Scripted API". El script se edita en la web de New Relic, pero la
 * version que vale es esta: ver la seccion Synthetic de docs/observabilidad.md.
 *
 * Credenciales (New Relic → Synthetics → Secure credentials), ninguna en el repo:
 *   SNIPPET_API_URL          https://ppc-snippets-dev.duckdns.org/api
 *   SNIPPET_AUTH0_DOMAIN     el dominio de Auth0, sin https://
 *   SNIPPET_AUTH0_AUDIENCE   la audiencia de la API
 *   SNIPPET_CLIENT_ID        app M2M propia del synthetic
 *   SNIPPET_CLIENT_SECRET    su secret
 */

const assert = require('assert')

const API = $secure.SNIPPET_API_URL
const TIMEOUT_MS = 10000

// $http con promesas: el flujo son cuatro pedidos en orden y con callbacks queda una piramide.
// Para el runtime viejo de New Relic hay que pasarlo a callbacks anidados (ver docs/observabilidad.md).
//
// El JSON se arma y se lee a mano en vez de usar la opcion `json`: en los runtimes nuevos $http
// esta hecho sobre otra libreria, donde `json` y `body` no se pueden usar juntos. Mandar un
// string y parsear la respuesta anda igual en todos.
const pedir = ({datos, headers = {}, ...opciones}) =>
  new Promise((resolve, reject) => {
    const pedido = {timeout: TIMEOUT_MS, ...opciones, headers: {Accept: 'application/json', ...headers}}
    if (datos !== undefined) {
      pedido.body = JSON.stringify(datos)
      pedido.headers['Content-Type'] = 'application/json'
    }
    $http(pedido, (error, respuesta, cuerpo) => {
      if (error) {
        reject(new Error(`${opciones.method} ${opciones.url} fallo: ${error.message}`))
        return
      }
      resolve({status: respuesta.statusCode, cuerpo: comoJson(cuerpo)})
    })
  })

/** El cuerpo llega como texto; si no es JSON (un 204 vacio, una pagina de error de nginx) queda como vino. */
const comoJson = (cuerpo) => {
  if (typeof cuerpo !== 'string' || cuerpo === '') return cuerpo
  try {
    return JSON.parse(cuerpo)
  } catch (e) {
    return cuerpo
  }
}

/** Token de Auth0 por Client Credentials: el synthetic no es un usuario, es una app. */
const token = async () => {
  const {status, cuerpo} = await pedir({
    method: 'POST',
    url: `https://${$secure.SNIPPET_AUTH0_DOMAIN}/oauth/token`,
    datos: {
      grant_type: 'client_credentials',
      client_id: $secure.SNIPPET_CLIENT_ID,
      client_secret: $secure.SNIPPET_CLIENT_SECRET,
      audience: $secure.SNIPPET_AUTH0_AUDIENCE,
    },
  })

  assert.equal(status, 200, 'Auth0 no dio un token')
  assert.ok(cuerpo.access_token, 'la respuesta de Auth0 no trae access_token')
  return cuerpo.access_token
}

const crear = async (bearer, contenido) => {
  const {status, cuerpo} = await pedir({
    method: 'POST',
    url: `${API}/snippets`,
    headers: {Authorization: bearer},
    // Sin extension: la deriva el servidor del lenguaje (snippet-service #63)
    datos: {
      name: `synthetic-${Date.now()}`,
      description: 'Monitor de New Relic: crear, leer y borrar',
      language: 'printscript',
      version: '1.1',
      content: contenido,
    },
  })

  assert.equal(status, 201, `crear devolvio ${status}: ${JSON.stringify(cuerpo)}`)
  assert.ok(cuerpo.id, 'crear no devolvio el id')
  return cuerpo.id
}

const leer = async (bearer, id, contenido) => {
  const {status, cuerpo} = await pedir({
    method: 'GET',
    url: `${API}/snippets/${id}`,
    headers: {Authorization: bearer},
  })

  assert.equal(status, 200, `leer devolvio ${status}`)
  // Lo que importa no es que responda, sino que devuelva lo mismo que se guardo: esto es lo que
  // falla si el asset service pierde el contenido o lo devuelve con otra codificacion
  assert.equal(cuerpo.content, contenido, 'el contenido leido no es el que se guardo')
}

const borrar = async (bearer, id) => {
  const {status} = await pedir({
    method: 'DELETE',
    url: `${API}/snippets/${id}`,
    headers: {Authorization: bearer},
  })

  assert.equal(status, 204, `borrar devolvio ${status}`)
}

const flujo = async () => {
  const contenido = 'let saludo: string = "synthetic";\nprintln(saludo);'
  const bearer = `Bearer ${await token()}`

  let id = null
  try {
    id = await crear(bearer, contenido)
    await leer(bearer, id, contenido)
  } finally {
    // En el finally para que un fallo al leer no deje el snippet acumulandose: nadie ve los
    // snippets del synthetic en su listado, asi que un huerfano por corrida no lo limpia nadie
    if (id) await borrar(bearer, id)
  }
}

flujo()
