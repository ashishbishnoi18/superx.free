import {CliError} from "./errors.js"

export async function readToken({env, input, output}) {
  const fromEnvironment = env.SUPERX_FREE_TOKEN?.trim()
  if (fromEnvironment) return fromEnvironment

  if (!input.isTTY) {
    const chunks = []
    for await (const chunk of input) chunks.push(chunk)

    const token = Buffer.concat(chunks.map(chunk => Buffer.from(chunk))).toString("utf8").trim()
    if (token) return token

    throw new CliError("No API token was provided on standard input.", {code: "missing_token"})
  }

  return hiddenQuestion("API token: ", input, output)
}

function hiddenQuestion(prompt, input, output) {
  return new Promise((resolve, reject) => {
    const wasRaw = input.isRaw
    let token = ""

    const finish = (error) => {
      input.off("data", onData)
      input.setRawMode(wasRaw)
      input.pause()
      output.write("\n")

      if (error) return reject(error)
      if (token.trim() === "") {
        return reject(new CliError("API token cannot be empty.", {code: "missing_token"}))
      }

      resolve(token.trim())
    }

    const onData = chunk => {
      for (const character of chunk) {
        if (character === "\u0003") return finish(new CliError("Login cancelled.", {code: "cancelled"}))
        if (character === "\r" || character === "\n") return finish()
        if (character === "\u007f" || character === "\b") {
          token = token.slice(0, -1)
        } else if (character >= " ") {
          token += character
        }
      }
    }

    output.write(prompt)
    input.setEncoding("utf8")
    input.setRawMode(true)
    input.resume()
    input.on("data", onData)
  })
}

export async function confirmDelete(id, input, output) {
  if (!input.isTTY) {
    throw new CliError("Refusing to delete without confirmation. Pass --yes in a non-interactive shell.", {
      code: "confirmation_required"
    })
  }

  output.write(`Delete ${id} from SuperX? This does not delete anything from X. [y/N] `)

  const answer = await new Promise(resolve => {
    input.setEncoding("utf8")
    input.resume()
    input.once("data", chunk => {
      input.pause()
      resolve(chunk.trim().toLowerCase())
    })
  })

  return answer === "y" || answer === "yes"
}
