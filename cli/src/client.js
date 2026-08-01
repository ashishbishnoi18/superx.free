import {ApiError, CliError} from "./errors.js"

const DEFAULT_TIMEOUT_MS = 15_000
const DEFAULT_RATE_LIMIT_RETRIES = 2

export async function apiRequest(config, path, options = {}) {
  const fetchImpl = options.fetchImpl || globalThis.fetch
  const sleep = options.sleep || wait
  const maxRetries = options.maxRateLimitRetries ?? DEFAULT_RATE_LIMIT_RETRIES
  const url = new URL(path, `${config.host}/`)
  let retries = 0

  while (true) {
    const response = await fetchResponse(fetchImpl, url, config, options)

    if (response.status === 429 && retries < maxRetries) {
      const delay = retryDelay(response.headers)
      retries += 1
      options.onRateLimit?.(delay, retries)
      await sleep(delay)
      continue
    }

    const body = await responseBody(response)

    if (!response.ok) throw new ApiError(response.status, body)

    return body
  }
}

async function fetchResponse(fetchImpl, url, config, options) {
  const headers = {
    Accept: "application/json",
    Authorization: `Bearer ${config.token}`
  }

  if (options.body !== undefined) headers["Content-Type"] = "application/json"

  try {
    return await fetchImpl(url, {
      method: options.method || "GET",
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
      signal: AbortSignal.timeout(options.timeoutMs ?? DEFAULT_TIMEOUT_MS)
    })
  } catch (error) {
    throw new CliError(
      `Could not reach ${config.host}. Check the host and your network connection.`,
      {cause: error, code: "unreachable"}
    )
  }
}

async function responseBody(response) {
  if (response.status === 204) return null

  const encoded = await response.text()
  if (encoded === "") return null

  try {
    return JSON.parse(encoded)
  } catch {
    return {error: `SuperX returned HTTP ${response.status} with an invalid JSON response.`}
  }
}

export function retryDelay(headers, now = Date.now()) {
  return durationHeader(headers.get("retry-after"), now, true) ??
    durationHeader(headers.get("ratelimit-reset"), now, false) ??
    1_000
}

function durationHeader(value, now, allowDate) {
  if (!value) return null

  const seconds = Number(value)
  if (Number.isFinite(seconds) && seconds >= 0) return Math.max(Math.ceil(seconds * 1_000), 1_000)

  if (!allowDate) return null

  const date = Date.parse(value)
  if (Number.isNaN(date)) return null

  return Math.max(date - now, 1_000)
}

function wait(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds))
}
