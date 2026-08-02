# SuperX XChat worker

The encryption boundary for XChat. It loads X's official Chat XDK and keeps
cryptography outside the Elixir application. The worker makes no HTTP calls;
OAuth tokens stay in `SuperX.X`.

## Contract

Line-delimited JSON on stdin and stdout. One request produces one response,
correlated by `id`.

```text
→ {"id":"req-1","op":"decrypt_events","params":{...}}
← {"id":"req-1","type":"done","data":{"events":[...],"errors":{}}}
```

On startup it emits a handshake before reading requests:

```text
← {"type":"ready","data":{"contract":"superx.xchat/v1","ops":["register_keys","decrypt_events","encrypt_message"],"configured":true}}
```

Errors are per request and never echo request parameters:

```text
← {"id":"req-1","type":"error","message":"private key blob is invalid"}
```

| Operation | Purpose |
|---|---|
| `register_keys` | Generate identity and signing keys. Returns the public registration payload and an opaque private-key blob. |
| `decrypt_events` | Import an identity, verify signatures, recover conversation keys from the batch, and return plaintext message events. |
| `encrypt_message` | Recover the current conversation key from the supplied history, then encrypt and sign one message. |

Private-key blobs cross the Port only for the duration of one operation. They
must never be logged. Elixir stores them through `SuperX.Vault.EncryptedBinary`.

## Why the lower-level WASM entry is used

The package's public JavaScript wrapper is aimed at UI applications and hides
raw key import and export. The official package still ships those methods on
its WASM crypto engine, and X's own blob-backed headless example uses that
engine directly. SuperX follows that example because it is a self-hosted server
case, not a hosted UI collecting other people's keys. The dependency is pinned
because this lower-level entry is not part of the package's public JavaScript
surface.

## Install

```bash
cd xchat
npm ci
```

Node 18 or newer is required. Missing Node or `node_modules` disables XChat
with a debug log; legacy DMs and the rest of SuperX continue to work.
