import { deleteProviderKey } from './llm-key.ts'

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
