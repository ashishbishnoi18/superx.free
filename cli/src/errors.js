export class CliError extends Error {
  constructor(message, options = {}) {
    super(message, options)
    this.name = "CliError"
    this.code = options.code
  }
}

export class ApiError extends CliError {
  constructor(status, body) {
    super(apiErrorMessage(status, body), {code: "api_error"})
    this.name = "ApiError"
    this.status = status
    this.body = body
  }
}

function apiErrorMessage(status, body) {
  if (body && typeof body.error === "string") return body.error

  if (body?.errors && typeof body.errors === "object") {
    return Object.entries(body.errors)
      .flatMap(([field, messages]) => messages.map(message => `${field}: ${message}`))
      .join("; ")
  }

  return `SuperX returned HTTP ${status}.`
}
