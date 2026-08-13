const OPENROUTER_KEYS_URL = 'https://openrouter.ai/api/v1/keys'
const OPENROUTER_CURRENT_KEY_URL = 'https://openrouter.ai/api/v1/key'

type ProviderKey = {
  hash: string
  limit?: number | null
  limit_reset?: string | null
  disabled?: boolean
  usage?: number | null
  limit_remaining?: number | null
  created_at?: string | null
  updated_at?: string | null
}

export type LlmKeyMetadata = {
  provider: 'openrouter'
  provider_key_hash: string
  limit_usd: number | null
  limit_reset: string | null
  disabled: boolean
  usage_usd: number | null
  limit_remaining_usd: number | null
  provider_created_at: string | null
  provider_updated_at: string | null
}

const toBase64 = (bytes: Uint8Array) => {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
}

const fromBase64 = (value: string) => {
  const binary = atob(value)
  return Uint8Array.from(binary, (char) => char.charCodeAt(0))
}

async function encryptionKey(secret: string) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(secret))
  return crypto.subtle.importKey('raw', digest, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt'])
}

export async function encryptProviderKey(plaintext: string, secret: string) {
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const ciphertext = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv },
    await encryptionKey(secret),
    new TextEncoder().encode(plaintext),
  )
  const packed = new Uint8Array(iv.length + ciphertext.byteLength)
  packed.set(iv)
  packed.set(new Uint8Array(ciphertext), iv.length)
  return toBase64(packed)
}

export async function decryptProviderKey(ciphertext: string, secret: string) {
  const packed = fromBase64(ciphertext)
  const plaintext = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: packed.slice(0, 12) },
    await encryptionKey(secret),
    packed.slice(12),
  )
  return new TextDecoder().decode(plaintext)
}

export function metadataFromProvider(data: ProviderKey): LlmKeyMetadata {
  return {
    provider: 'openrouter',
    provider_key_hash: data.hash,
    limit_usd: data.limit ?? null,
    limit_reset: data.limit_reset ?? null,
    disabled: data.disabled ?? false,
    usage_usd: data.usage ?? null,
    limit_remaining_usd: data.limit_remaining ?? null,
    provider_created_at: data.created_at ?? null,
    provider_updated_at: data.updated_at ?? null,
  }
}

export async function createProviderKey(
  managementKey: string,
  name: string,
  limit: number,
  limitReset: string,
  workspaceId: string,
) {
  const response = await fetch(OPENROUTER_KEYS_URL, {
    method: 'POST',
    headers: { Authorization: `Bearer ${managementKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ name, limit, limit_reset: limitReset, workspace_id: workspaceId }),
  })
  const body = await response.json().catch(() => ({}))
  if (!response.ok || !body?.data?.hash || !body?.key) {
    throw new Error(`provider_create_failed:${response.status}`)
  }
  return { provider: body.data as ProviderKey, plaintext: body.key as string }
}

export async function deleteProviderKey(managementKey: string, hash: string) {
  const response = await fetch(`${OPENROUTER_KEYS_URL}/${encodeURIComponent(hash)}`, {
    method: 'DELETE',
    headers: { Authorization: `Bearer ${managementKey}` },
  })
  if (!response.ok && response.status !== 404) {
    throw new Error(`provider_delete_failed:${response.status}`)
  }
}

export async function verifyProviderKey(providerKey: string) {
  const response = await fetch(OPENROUTER_CURRENT_KEY_URL, {
    headers: { Authorization: `Bearer ${providerKey}` },
  })
  if (!response.ok) throw new Error(`provider_verify_failed:${response.status}`)
}
