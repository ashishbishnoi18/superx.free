import {ApiError, CliError} from "./errors.js"
import {
  DEFAULT_HOST,
  defaultConfigPath,
  normaliseHost,
  readConfig,
  removeConfig,
  writeConfig
} from "./config.js"
import {apiRequest} from "./client.js"
import {confirmDelete, readToken} from "./prompts.js"
import {
  printAnalytics,
  printDraft,
  printQueue,
  printScheduled,
  printShelf,
  printWhoami
} from "./output.js"

const VERSION = "0.1.0"

export async function run(argv, dependencies = {}) {
  const input = dependencies.input || process.stdin
  const output = dependencies.output || process.stdout
  const errorOutput = dependencies.errorOutput || process.stderr
  const env = dependencies.env || process.env
  const configPath = dependencies.configPath || defaultConfigPath(dependencies.home)
  const {args, json} = extractJsonOption(argv)
  const requestOptions = {
    fetchImpl: dependencies.fetchImpl,
    sleep: dependencies.sleep,
    maxRateLimitRetries: dependencies.maxRateLimitRetries,
    onRateLimit: delay => {
      errorOutput.write(`Rate limited. Retrying in ${Math.ceil(delay / 1_000)} seconds.\n`)
    }
  }

  try {
    const [command, ...commandArgs] = args

    if (!command || command === "help" || command === "--help" || command === "-h") {
      output.write(helpText())
      return 0
    }

    if (command === "--version" || command === "-v") {
      output.write(`${VERSION}\n`)
      return 0
    }

    switch (command) {
      case "login":
        await login(commandArgs, {
          env,
          input,
          output,
          promptOutput: errorOutput,
          configPath,
          json,
          requestOptions
        })
        break
      case "logout":
        await logout(commandArgs, {output, configPath, json})
        break
      case "whoami":
        await whoami(commandArgs, {output, configPath, json, requestOptions})
        break
      case "queue":
        await queue(commandArgs, {output, configPath, json, requestOptions})
        break
      case "shelf":
        await shelf(commandArgs, {output, configPath, json, requestOptions})
        break
      case "analytics":
        await analytics(commandArgs, {output, configPath, json, requestOptions})
        break
      case "draft":
        await draft(commandArgs, {output, configPath, json, requestOptions})
        break
      case "schedule":
        await schedule(commandArgs, {output, configPath, json, requestOptions})
        break
      case "delete":
        await deletePost(commandArgs, {
          input,
          output,
          promptOutput: errorOutput,
          configPath,
          json,
          requestOptions
        })
        break
      default:
        throw new CliError(`Unknown command: ${command}. Run \`superx-free help\` for usage.`, {
          code: "unknown_command"
        })
    }

    return 0
  } catch (error) {
    printError(error, errorOutput, json)
    return 1
  }
}

async function login(args, context) {
  const {options, positionals} = parseOptions(args, {host: "value"})
  noPositionals(positionals, "login")

  const host = normaliseHost(options.host || DEFAULT_HOST)
  const token = await readToken({
    env: context.env,
    input: context.input,
    output: context.promptOutput
  })
  const config = {host, token}
  let account = null
  let accountStatus = "selected"

  try {
    const body = await apiRequest(config, "/api/queue", context.requestOptions)
    account = body.account
  } catch (error) {
    if (authenticatedWithoutAccount(error)) {
      accountStatus = "not_selected"
    } else if (error instanceof ApiError && error.status === 429) {
      accountStatus = "rate_limited"
    } else {
      throw error
    }
  }

  await writeConfig(config, context.configPath)

  if (context.json) {
    printJson(context.output, {host, account, account_status: accountStatus})
  } else if (account) {
    context.output.write(`Logged in to ${host} as @${account.handle}.\n`)
  } else if (accountStatus === "rate_limited") {
    context.output.write(`Logged in to ${host}. The selected account could not be checked yet.\n`)
  } else {
    context.output.write(`Logged in to ${host}. Connect or select an X account before using it.\n`)
  }
}

async function logout(args, context) {
  const {options, positionals} = parseOptions(args, {})
  noOptions(options, "logout")
  noPositionals(positionals, "logout")
  const removed = await removeConfig(context.configPath)

  if (context.json) printJson(context.output, {logged_out: true, had_config: removed})
  else context.output.write(removed ? "Logged out.\n" : "Already logged out.\n")
}

async function whoami(args, context) {
  noArguments(args, "whoami")
  const config = await readConfig(context.configPath)
  let body

  try {
    body = await apiRequest(config, "/api/queue", context.requestOptions)
  } catch (error) {
    if (!authenticatedWithoutAccount(error)) throw error
    body = {account: null}
  }

  if (context.json) printJson(context.output, {host: config.host, account: body.account})
  else printWhoami(body, config.host, context.output)
}

async function queue(args, context) {
  const {options, positionals} = parseOptions(args, {status: "value"})
  noPositionals(positionals, "queue")
  const config = await readConfig(context.configPath)
  const query = options.status ? `?status=${encodeURIComponent(options.status)}` : ""
  const body = await apiRequest(config, `/api/queue${query}`, context.requestOptions)

  if (context.json) printJson(context.output, body)
  else printQueue(body, context.output)
}

async function shelf(args, context) {
  noArguments(args, "shelf")
  const config = await readConfig(context.configPath)
  const body = await apiRequest(config, "/api/shelf", context.requestOptions)

  if (context.json) printJson(context.output, body)
  else printShelf(body, context.output)
}

async function analytics(args, context) {
  const {options, positionals} = parseOptions(args, {days: "value"})
  noPositionals(positionals, "analytics")
  const config = await readConfig(context.configPath)
  const query = options.days ? `?days=${encodeURIComponent(options.days)}` : ""
  const body = await apiRequest(config, `/api/analytics${query}`, context.requestOptions)

  if (context.json) printJson(context.output, body)
  else printAnalytics(body, context.output)
}

async function draft(args, context) {
  const {options, positionals} = parseOptions(args, {segment: "multiple", tag: "multiple"})
  const texts = []

  if (positionals.length > 0) texts.push(positionals.join(" "))
  texts.push(...(options.segment || []))

  if (texts.length === 0) {
    throw new CliError("Provide draft text or at least one --segment.", {code: "missing_text"})
  }

  const config = await readConfig(context.configPath)
  const body = await apiRequest(config, "/api/posts", {
    ...context.requestOptions,
    method: "POST",
    body: {
      segments: texts.map(text => ({text, media_ids: []})),
      tags: options.tag || []
    }
  })

  if (context.json) printJson(context.output, body)
  else printDraft(body, context.output)
}

async function schedule(args, context) {
  const {options, positionals} = parseOptions(args, {at: "value"})
  exactlyOnePositional(positionals, "schedule", "post id")
  const config = await readConfig(context.configPath)
  const body = await apiRequest(
    config,
    `/api/posts/${encodeURIComponent(positionals[0])}/schedule`,
    {
      ...context.requestOptions,
      method: "POST",
      body: options.at ? {at: options.at} : undefined
    }
  )

  if (context.json) printJson(context.output, body)
  else printScheduled(body, context.output)
}

async function deletePost(args, context) {
  const {options, positionals} = parseOptions(args, {yes: "boolean"})
  exactlyOnePositional(positionals, "delete", "post id")
  const id = positionals[0]
  const confirmed = options.yes || await confirmDelete(id, context.input, context.promptOutput)

  if (!confirmed) {
    if (context.json) printJson(context.output, {deleted: false, id})
    else context.output.write("Not deleted.\n")
    return
  }

  const config = await readConfig(context.configPath)
  await apiRequest(config, `/api/posts/${encodeURIComponent(id)}`, {
    ...context.requestOptions,
    method: "DELETE"
  })

  if (context.json) printJson(context.output, {deleted: true, id})
  else context.output.write(`Deleted ${id} from SuperX. Nothing was deleted from X.\n`)
}

function authenticatedWithoutAccount(error) {
  return error instanceof ApiError &&
    error.status === 409 &&
    error.body?.error === "Connect an X account before using this endpoint."
}

function parseOptions(args, schema) {
  const options = {}
  const positionals = []

  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index]

    if (argument === "--") {
      positionals.push(...args.slice(index + 1))
      break
    }

    if (!argument.startsWith("--") || argument === "-") {
      positionals.push(argument)
      continue
    }

    const name = argument.slice(2)
    const kind = schema[name]
    if (!kind) throw new CliError(`Unknown option: ${argument}.`, {code: "unknown_option"})

    if (kind === "boolean") {
      options[name] = true
      continue
    }

    const value = args[index + 1]
    if (value === undefined) {
      throw new CliError(`${argument} needs a value.`, {code: "missing_option_value"})
    }

    index += 1
    if (kind === "multiple") options[name] = [...(options[name] || []), value]
    else options[name] = value
  }

  return {options, positionals}
}

function extractJsonOption(argv) {
  const args = []
  let json = false
  let positionalOnly = false

  for (const argument of argv) {
    if (argument === "--") {
      positionalOnly = true
      args.push(argument)
    } else if (!positionalOnly && argument === "--json") {
      json = true
    } else {
      args.push(argument)
    }
  }

  return {args, json}
}

function noArguments(args, command) {
  if (args.length > 0) throw new CliError(`${command} does not take arguments.`, {code: "arguments"})
}

function noOptions(options, command) {
  if (Object.keys(options).length > 0) {
    throw new CliError(`${command} does not take options.`, {code: "options"})
  }
}

function noPositionals(positionals, command) {
  if (positionals.length > 0) {
    throw new CliError(`${command} does not take positional arguments.`, {code: "arguments"})
  }
}

function exactlyOnePositional(positionals, command, name) {
  if (positionals.length !== 1) {
    throw new CliError(`${command} needs exactly one ${name}.`, {code: "arguments"})
  }
}

function printJson(output, value) {
  output.write(`${JSON.stringify(value, null, 2)}\n`)
}

function printError(error, output, json) {
  const known = error instanceof CliError
    ? error
    : new CliError("The command failed unexpectedly.", {code: "unexpected"})

  if (!json) {
    output.write(`Error: ${known.message}\n`)
    return
  }

  const body = known instanceof ApiError && known.body && typeof known.body === "object"
    ? known.body
    : {error: known.message}
  const payload = known instanceof ApiError ? {status: known.status, ...body} : body
  output.write(`${JSON.stringify(payload)}\n`)
}

function helpText() {
  return `superx-free ${VERSION}

Usage:
  superx-free <command> [options]

Commands:
  login [--host URL]                  Store and verify an API token
  logout                             Remove the stored login
  whoami                             Show the selected X account
  queue [--status STATUS]            List posts in one queue state
  shelf                              List drafts waiting in Ready to Post
  analytics [--days 7|30|90]         Show account analytics
  draft TEXT [--segment TEXT]        Create a draft or thread
        [--tag TAG]
  schedule POST_ID [--at ISO8601]    Schedule a draft
  delete POST_ID [--yes]             Delete a post from SuperX

Use --json with any command for machine-readable output.
Login reads the token from a hidden prompt, standard input, or SUPERX_FREE_TOKEN.
There is no direct publish command.
`
}
