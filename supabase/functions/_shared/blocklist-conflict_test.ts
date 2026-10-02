import { parseBlocklistAcknowledgment, blocklistConflictResponse } from './blocklist-conflict.ts'

Deno.test('consent accepts only explicit boolean true; omission defaults to false', () => {
  if (parseBlocklistAcknowledgment(undefined) !== false || parseBlocklistAcknowledgment(false) !== false || parseBlocklistAcknowledgment(true) !== true) throw new Error('boolean consent');
  for (const value of [null, 1, 'true', {}, []]) {
    if (parseBlocklistAcknowledgment(value) !== null) throw new Error('invalid consent accepted');
  }
})
Deno.test('conflict response includes only authorized host contact metadata', () => {
  const events = [{ id: 'allowed', creator_id: 'host' }]
  const response = blocklistConflictResponse({ message: 'blocklist_confirmation_required', details: 'allowed' }, events)
  if (JSON.stringify(response) !== JSON.stringify({ error: { code: 'blocklist_confirmation_required', message: 'Confirmation is required before continuing.', details: { warning_event_id: 'allowed', host_profile_id: 'host' } } })) throw new Error('unexpected warning');
  const hidden = blocklistConflictResponse({ message: 'blocklist_confirmation_required', details: 'private-id' }, events)
  if (hidden !== null) throw new Error('unauthorized metadata');
  if (blocklistConflictResponse({ message: 'database failure', details: 'allowed' }, events) !== null) throw new Error('database failure mislabeled');
})
