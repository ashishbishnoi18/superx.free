import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { webcrypto } from "node:crypto";
import { createInterface } from "node:readline";

if (typeof globalThis.crypto === "undefined") {
  globalThis.crypto = webcrypto;
}

// The BEAM closes the pipe during an orderly shutdown. Node would otherwise
// report that normal lifecycle event as an uncaught exception.
process.stdout.on("error", (error) => {
  if (error.code === "EPIPE") process.exit(0);
  throw error;
});

const contract = "superx.xchat/v1";
const operations = ["register_keys", "decrypt_events", "encrypt_message"];

function write(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

async function loadXdk() {
  const require = createRequire(import.meta.url);
  const packageEntry = require.resolve("@xdevplatform/chat-xdk");
  const wasmModuleUrl = new URL("./pkg/chat_xdk_wasm.js", `file://${packageEntry}`);
  const wasmBinaryUrl = new URL("./pkg/chat_xdk_wasm_bg.wasm", `file://${packageEntry}`);
  const xdk = await import(wasmModuleUrl.href);
  const init = xdk.default || xdk.init || xdk.__wbindgen_init;

  if (typeof init !== "function" || typeof xdk.Chat !== "function") {
    throw new Error("Chat XDK WASM engine is unavailable");
  }

  const wasm = await readFile(wasmBinaryUrl);
  await init({ module_or_path: wasm });
  return xdk;
}

function privateKeyBytes(xdk, value) {
  const bytes = typeof value === "string" ? xdk.base64ToBytes(value) : undefined;

  if (!bytes || bytes.length === 0) {
    throw new Error("private key blob is invalid");
  }

  return bytes;
}

function withIdentity(xdk, params, operation) {
  const chat = new xdk.Chat();
  const privateKey = privateKeyBytes(xdk, params.private_key);

  try {
    chat.importKeys(privateKey, params.key_version);
    chat.setIdentity(params.user_id, params.key_version);
    return operation(chat);
  } finally {
    privateKey.fill(0);
    chat.lock();
    chat.free();
  }
}

function registration(xdk) {
  const chat = new xdk.Chat();
  let privateKey;

  try {
    const generated = chat.generateKeypairs();
    privateKey = chat.exportKeys();
    const publicKey = generated.publicKey;
    const keyVersion = String(generated.version || "1");

    return {
      private_key: xdk.bytesToBase64(privateKey),
      key_version: keyVersion,
      registration: {
        public_key: {
          identity_public_key_signature: publicKey.identityPublicKeySignature,
          public_key: publicKey.publicKey,
          public_key_fingerprint: publicKey.publicKeyFingerprint,
          registration_method: publicKey.registrationMethod,
          signing_public_key: publicKey.signingPublicKey,
          signing_public_key_signature: publicKey.signingPublicKeySignature,
        },
        version: keyVersion,
        generate_version: generated.generateVersion,
      },
    };
  } finally {
    if (privateKey) privateKey.fill(0);
    chat.lock();
    chat.free();
  }
}

function decryptEvents(xdk, params) {
  return withIdentity(xdk, params, (chat) => {
    const decrypted = chat.decryptEvents(params.events, params.signing_keys);

    return {
      events: decrypted.messages.map((message) => message.event),
      errors: decrypted.errors,
    };
  });
}

function encryptMessage(xdk, params) {
  return withIdentity(xdk, params, (chat) => {
    chat.setCacheKeys(true);
    chat.decryptEvents(params.events, params.signing_keys);

    const encrypted = chat.encryptMessage({
      conversationId: params.conversation_id,
      text: params.text,
    });

    return {
      message_id: encrypted.messageId,
      encoded_message_create_event: encrypted.encryptedContent,
      encoded_message_event_signature: encrypted.encodedEventSignature,
    };
  });
}

function perform(xdk, op, params) {
  switch (op) {
    case "register_keys":
      return registration(xdk);
    case "decrypt_events":
      return decryptEvents(xdk, params);
    case "encrypt_message":
      return encryptMessage(xdk, params);
    default:
      throw new Error("unknown operation");
  }
}

function errorMessage(error, params) {
  let message = error instanceof Error ? error.message : "operation failed";

  for (const sensitive of [params?.private_key, params?.text]) {
    if (typeof sensitive === "string" && sensitive !== "") {
      message = message.replaceAll(sensitive, "[redacted]");
    }
  }

  return message.slice(0, 300);
}

let xdk;

try {
  xdk = await loadXdk();
} catch {
  xdk = undefined;
}

write({
  type: "ready",
  data: { contract, ops: operations, configured: xdk !== undefined },
});

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });

for await (const line of input) {
  let request;

  try {
    request = JSON.parse(line);

    if (!xdk) {
      throw new Error("Chat XDK is unavailable");
    }

    const data = perform(xdk, request.op, request.params || {});
    write({ id: request.id, type: "done", data });
  } catch (error) {
    write({
      id: request?.id,
      type: "error",
      message: errorMessage(error, request?.params),
    });
  }
}
