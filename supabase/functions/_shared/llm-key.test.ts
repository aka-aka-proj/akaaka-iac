import { createProviderKey, deleteProviderKey } from './llm-key.ts'

Deno.test('provider key creation targets the configured workspace', async () => {
  const originalFetch = globalThis.fetch
  let requestBody: Record<string, unknown> | undefined
  globalThis.fetch = async (_input, init) => {
    requestBody = JSON.parse(String(init?.body))
    return Response.json({
      data: { hash: 'synthetic-hash' },
      key: 'synthetic-key',
    }, { status: 201 })
  }

  try {
    await createProviderKey(
      'synthetic-management-key',
      'synthetic-name',
      10,
      'monthly',
      '00000000-0000-0000-0000-000000000001',
    )
    if (requestBody?.workspace_id !== '00000000-0000-0000-0000-000000000001') {
      throw new Error('expected configured workspace_id')
    }
  } finally {
    globalThis.fetch = originalFetch
  }
})

Deno.test('provider delete treats an already missing key as idempotent', async () => {
  const originalFetch = globalThis.fetch
  globalThis.fetch = async () => new Response(null, { status: 404 })

  try {
    await deleteProviderKey('synthetic-management-key', 'synthetic-hash')
  } finally {
    globalThis.fetch = originalFetch
  }
})

Deno.test('provider delete reports dependency failures without hiding status', async () => {
  const originalFetch = globalThis.fetch
  globalThis.fetch = async () => new Response(null, { status: 503 })

  try {
    await deleteProviderKey('synthetic-management-key', 'synthetic-hash')
    throw new Error('expected provider deletion to fail')
  } catch (error) {
    if (!(error instanceof Error) || error.message !== 'provider_delete_failed:503') {
      throw error
    }
  } finally {
    globalThis.fetch = originalFetch
  }
})
