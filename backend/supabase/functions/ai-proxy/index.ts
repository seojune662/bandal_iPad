import { runtime } from '../_shared/ai/runtime.ts'
const handle = runtime(key => Deno.env.get(key))
Deno.serve(handle)
