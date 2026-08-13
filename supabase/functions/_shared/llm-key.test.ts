import { createProviderKey, deleteProviderKey, verifyProviderKey } from './llm-key.ts'

Deno.test('provider key creation targets the configured workspace', async () => {
  const originalFetch = globalThis.fetch
  let requestBody: Record<string, unknown> | undefined
  globalThis.fetch = async (_input, init) => {
    requestBody = JSON.parse(String(init?.body))
    return Response.json({ data: { hash: 'synthetic-hash' }, key: 'synthetic-key' }, { status: 201 })
  }
  try {
    await createProviderKey('management', 'name', 1, 'monthly', '00000000-0000-0000-0000-000000000001')
    if (requestBody?.workspace_id !== '00000000-0000-0000-0000-000000000001') {
      throw new Error('expected workspace_id')
    }
  } finally {
    globalThis.fetch = originalFetch
  }
})

Deno.test('provider delete treats 404 as idempotent', async () => {
  const originalFetch = globalThis.fetch
  globalThis.fetch = async () => new Response(null, { status: 404 })
  try {
    await deleteProviderKey('management', 'hash')
  } finally {
    globalThis.fetch = originalFetch
  }
})

Deno.test('provider verification accepts a valid provider key', async () => {
  const originalFetch = globalThis.fetch
  globalThis.fetch = async () => new Response(JSON.stringify({ data: {} }), { status: 200 })
  try {
    await verifyProviderKey('provider-key')
  } finally {
    globalThis.fetch = originalFetch
  }
})
