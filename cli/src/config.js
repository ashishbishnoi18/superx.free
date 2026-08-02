import {randomUUID} from "node:crypto"
import {homedir} from "node:os"
import {dirname, join} from "node:path"
import {chmod, mkdir, readFile, rename, unlink, writeFile} from "node:fs/promises"

import {CliError} from "./errors.js"

export const DEFAULT_HOST = "https://superx.free"

export function defaultConfigPath(home = homedir()) {
  return join(home, ".superx-free", "config.json")
}

export function normaliseHost(value = DEFAULT_HOST) {
  let url

  try {
    url = new URL(value)
  } catch {
    throw new CliError("Host must be a complete http:// or https:// URL.", {code: "invalid_host"})
  }

  if (!(["http:", "https:"].includes(url.protocol)) || url.username || url.password) {
    throw new CliError("Host must be a complete http:// or https:// URL without credentials.", {
      code: "invalid_host"
    })
  }

  if (url.pathname !== "/" || url.search || url.hash) {
    throw new CliError("Host must not include a path, query, or fragment.", {code: "invalid_host"})
  }

  if (url.protocol === "http:" && !isLoopback(url.hostname)) {
    throw new CliError("Plain HTTP is allowed only for localhost. Use HTTPS for remote hosts.", {
      code: "insecure_host"
    })
  }

  return url.origin
}

function isLoopback(hostname) {
  return hostname === "localhost" || hostname === "[::1]" || /^127(?:\.\d{1,3}){3}$/.test(hostname)
}

export async function readConfig(path = defaultConfigPath()) {
  let encoded

  try {
    encoded = await readFile(path, "utf8")
  } catch (error) {
    if (error.code === "ENOENT") {
      throw new CliError("Not logged in. Run `superx-free login` first.", {code: "no_config"})
    }

    throw new CliError(`Could not read ${path}.`, {cause: error, code: "config_read"})
  }

  try {
    const config = JSON.parse(encoded)

    if (
      typeof config.host !== "string" ||
      typeof config.token !== "string" ||
      config.token.trim() === ""
    ) {
      throw new Error()
    }

    return {host: normaliseHost(config.host), token: config.token}
  } catch (error) {
    if (error instanceof CliError) throw error

    throw new CliError(`Config at ${path} is invalid. Run \`superx-free login\` again.`, {
      code: "invalid_config"
    })
  }
}

export async function writeConfig(config, path = defaultConfigPath()) {
  const directory = dirname(path)
  const temporary = `${path}.${process.pid}.${randomUUID()}.tmp`
  const encoded = `${JSON.stringify(config, null, 2)}\n`

  await mkdir(directory, {recursive: true, mode: 0o700})
  await chmod(directory, 0o700)

  try {
    await writeFile(temporary, encoded, {encoding: "utf8", flag: "wx", mode: 0o600})
    await chmod(temporary, 0o600)
    await rename(temporary, path)
    await chmod(path, 0o600)
  } catch (error) {
    try {
      await unlink(temporary)
    } catch (cleanupError) {
      if (cleanupError.code !== "ENOENT") throw cleanupError
    }

    throw new CliError(`Could not save login at ${path}.`, {cause: error, code: "config_write"})
  }
}

export async function removeConfig(path = defaultConfigPath()) {
  try {
    await unlink(path)
    return true
  } catch (error) {
    if (error.code === "ENOENT") return false

    throw new CliError(`Could not remove ${path}.`, {cause: error, code: "config_remove"})
  }
}
