import assert from "node:assert/strict"
import {mkdtemp, readFile, rm, stat} from "node:fs/promises"
import {tmpdir} from "node:os"
import {join} from "node:path"
import {Readable} from "node:stream"
import test from "node:test"

import {run} from "../src/cli.js"
import {writeConfig} from "../src/config.js"

const TOKEN = "sx_test.secret"

test("login verifies the token and stores it with owner-only permissions", async t => {
  const fixture = await commandFixture(t)
  let request

  const code = await run(["login", "--host", "https://example.test", "--json"], {
    ...fixture.dependencies,
    env: {SUPERX_FREE_TOKEN: TOKEN},
    fetchImpl: async (url, options) => {
      request = {url, options}
      return jsonResponse({
        account: {id: "account-id", handle: "owner", display_name: "Owner"},
        status: "scheduled",
        posts: []
      })
    }
  })

  assert.equal(code, 0)
  assert.equal(request.url.href, "https://example.test/api/queue")
  assert.equal(request.options.headers.Authorization, `Bearer ${TOKEN}`)
  assert.deepEqual(JSON.parse(fixture.output.text), {
    host: "https://example.test",
    account: {id: "account-id", handle: "owner", display_name: "Owner"},
    account_status: "selected"
  })
  assert.doesNotMatch(fixture.output.text, /sx_test/)
  assert.equal(fixture.errorOutput.text, "")

  const stored = JSON.parse(await readFile(fixture.configPath, "utf8"))
  assert.deepEqual(stored, {host: "https://example.test", token: TOKEN})
  assert.equal((await stat(fixture.configPath)).mode & 0o777, 0o600)
  assert.equal((await stat(join(fixture.directory, ".superx-free"))).mode & 0o777, 0o700)
})

test("a revoked token returns the API error without printing the credential", async t => {
  const fixture = await loggedInFixture(t)

  const code = await run(["whoami"], {
    ...fixture.dependencies,
    fetchImpl: async () => jsonResponse(
      {error: "Provide a valid API token as a Bearer credential."},
      {status: 401}
    )
  })

  assert.equal(code, 1)
  assert.equal(fixture.output.text, "")
  assert.match(fixture.errorOutput.text, /valid API token/)
  assert.doesNotMatch(fixture.errorOutput.text, new RegExp(TOKEN))
})

test("whoami represents a valid login with no selected account", async t => {
  const fixture = await loggedInFixture(t)

  const code = await run(["whoami", "--json"], {
    ...fixture.dependencies,
    fetchImpl: async () => jsonResponse(
      {error: "Connect an X account before using this endpoint."},
      {status: 409}
    )
  })

  assert.equal(code, 0)
  assert.deepEqual(JSON.parse(fixture.output.text), {
    host: "https://example.test",
    account: null
  })
})

test("rate limiting waits for Retry-After before retrying", async t => {
  const fixture = await loggedInFixture(t)
  const delays = []
  let calls = 0

  const code = await run(["shelf", "--json"], {
    ...fixture.dependencies,
    sleep: async delay => delays.push(delay),
    fetchImpl: async () => {
      calls += 1

      if (calls === 1) {
        return jsonResponse(
          {error: "Rate limit exceeded. Try again after 2 seconds."},
          {status: 429, headers: {"Retry-After": "2"}}
        )
      }

      return jsonResponse({
        account: {id: "account-id", handle: "owner", display_name: "Owner"},
        counts: {all: 0},
        drafts: []
      })
    }
  })

  assert.equal(code, 0)
  assert.equal(calls, 2)
  assert.deepEqual(delays, [2_000])
  assert.match(fixture.errorOutput.text, /Retrying in 2 seconds/)
  assert.equal(JSON.parse(fixture.output.text).drafts.length, 0)
})

test("an unreachable host has a specific error and does not expose the token", async t => {
  const fixture = await loggedInFixture(t)

  const code = await run(["queue"], {
    ...fixture.dependencies,
    fetchImpl: async () => {
      throw new TypeError("connection refused")
    }
  })

  assert.equal(code, 1)
  assert.match(fixture.errorOutput.text, /Could not reach https:\/\/example\.test/)
  assert.doesNotMatch(fixture.errorOutput.text, new RegExp(TOKEN))
})

test("draft sends ordered segments and tags without accepting a lifecycle status", async t => {
  const fixture = await loggedInFixture(t)
  let request

  const code = await run([
    "draft",
    "Opening",
    "--segment",
    "Second part",
    "--tag",
    "product",
    "--tag",
    "launch",
    "--json"
  ], {
    ...fixture.dependencies,
    fetchImpl: async (url, options) => {
      request = {url, options}
      return jsonResponse({
        post: {
          id: "post-id",
          status: "draft",
          segments: [
            {text: "Opening", media_ids: []},
            {text: "Second part", media_ids: []}
          ],
          tags: ["product", "launch"]
        }
      }, {status: 201})
    }
  })

  assert.equal(code, 0)
  assert.equal(request.url.href, "https://example.test/api/posts")
  assert.equal(request.options.method, "POST")
  assert.deepEqual(JSON.parse(request.options.body), {
    segments: [
      {text: "Opening", media_ids: []},
      {text: "Second part", media_ids: []}
    ],
    tags: ["product", "launch"]
  })
  assert.equal(JSON.parse(fixture.output.text).post.status, "draft")
})

test("schedule sends only the approved post id and explicit time", async t => {
  const fixture = await loggedInFixture(t)
  const at = "2030-08-02T09:30:00Z"
  let request

  const code = await run(["schedule", "post-id", "--at", at, "--json"], {
    ...fixture.dependencies,
    fetchImpl: async (url, options) => {
      request = {url, options}
      return jsonResponse({
        post: {id: "post-id", status: "scheduled", scheduled_at: at}
      })
    }
  })

  assert.equal(code, 0)
  assert.equal(request.url.href, "https://example.test/api/posts/post-id/schedule")
  assert.equal(request.options.method, "POST")
  assert.deepEqual(JSON.parse(request.options.body), {at})
  assert.equal(JSON.parse(fixture.output.text).post.status, "scheduled")
})

test("delete requires confirmation in a non-interactive shell", async t => {
  const fixture = await loggedInFixture(t)
  let called = false

  const code = await run(["delete", "post-id"], {
    ...fixture.dependencies,
    fetchImpl: async () => {
      called = true
      return new Response(null, {status: 204})
    }
  })

  assert.equal(code, 1)
  assert.equal(called, false)
  assert.match(fixture.errorOutput.text, /Refusing to delete without confirmation/)
})

test("delete --yes targets only the named post and explains its local scope", async t => {
  const fixture = await loggedInFixture(t)
  let request

  const code = await run(["delete", "post-id", "--yes"], {
    ...fixture.dependencies,
    fetchImpl: async (url, options) => {
      request = {url, options}
      return new Response(null, {status: 204})
    }
  })

  assert.equal(code, 0)
  assert.equal(request.url.href, "https://example.test/api/posts/post-id")
  assert.equal(request.options.method, "DELETE")
  assert.match(fixture.output.text, /Nothing was deleted from X/)
})

test("commands fail plainly when no login exists", async t => {
  const fixture = await commandFixture(t)

  const code = await run(["analytics"], fixture.dependencies)

  assert.equal(code, 1)
  assert.equal(fixture.output.text, "")
  assert.match(fixture.errorOutput.text, /superx-free login/)
})

async function loggedInFixture(t) {
  const fixture = await commandFixture(t)
  await writeConfig({host: "https://example.test", token: TOKEN}, fixture.configPath)
  return fixture
}

async function commandFixture(t) {
  const directory = await mkdtemp(join(tmpdir(), "superx-free-test-"))
  t.after(() => rm(directory, {recursive: true, force: true}))

  const output = new Capture()
  const errorOutput = new Capture()
  const configPath = join(directory, ".superx-free", "config.json")

  return {
    directory,
    configPath,
    output,
    errorOutput,
    dependencies: {
      configPath,
      input: Readable.from([]),
      output,
      errorOutput,
      env: {}
    }
  }
}

function jsonResponse(body, init = {}) {
  return new Response(JSON.stringify(body), {
    ...init,
    headers: {"Content-Type": "application/json", ...init.headers}
  })
}

class Capture {
  text = ""

  write(chunk) {
    this.text += chunk
    return true
  }
}
