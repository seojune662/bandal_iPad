export const setTimeout = (delay: number, value?: unknown): Promise<unknown> => new Promise(resolve => globalThis.setTimeout(() => resolve(value), delay))
