import { seriesRegistrationError } from './series-registration-error.ts'

Deno.test('concurrent duplicate registration returns a safe duplicate response', () => {
  const result = seriesRegistrationError({ code: '23505', message: 'duplicate key violates unique constraint secret_constraint' })
  if (result.status !== 409 || result.error.code !== 'duplicate_registration') throw new Error('expected 409 duplicate_registration')
  if (JSON.stringify(result).includes('secret_constraint')) throw new Error('database detail exposed')
})

Deno.test('capacity and membership races preserve retryable conflict responses', () => {
  for (const message of ['capacity exhausted', 'membership changed']) {
    const result = seriesRegistrationError({ code: 'P0001', message })
    if (result.status !== 409 || result.error.code !== 'registration_conflict') throw new Error('expected retryable conflict')
  }
})

Deno.test('unknown database failures are not mislabeled as duplicates', () => {
  for (const error of [null, { code: '23503', message: 'foreign key failure' }, { code: 'XX000', message: 'duplicate text alone' }]) {
    const result = seriesRegistrationError(error)
    if (result.status !== 500 || result.error.code !== 'internal_error') throw new Error('expected internal error')
  }
})
