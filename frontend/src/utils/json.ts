export interface JsonValidationResult {
  valid: boolean
  error?: string
}

export function validateJson(value: string): JsonValidationResult {
  try {
    JSON.parse(value || '{}')
    return {valid: true}
  } catch (error) {
    return {
      valid: false,
      error: error instanceof Error ? error.message : 'Invalid JSON request body.',
    }
  }
}

export function formatJson(value: unknown): string {
  return JSON.stringify(value, null, 2)
}
