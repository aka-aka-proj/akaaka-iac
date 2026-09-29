export function seriesRegistrationError(error: { code?: string; message?: string } | null) {
  if (error?.code === '23505') {
    return {
      status: 409,
      error: { code: 'duplicate_registration', message: 'You are already registered for this series' },
    }
  }
  const retryable = error?.message?.includes('capacity') || error?.message?.includes('membership changed')
  return {
    status: retryable ? 409 : 500,
    error: {
      code: retryable ? 'registration_conflict' : 'internal_error',
      message: retryable ? 'The series changed while you were registering. Please try again.' : 'Failed to register for every member event',
    },
  }
}
