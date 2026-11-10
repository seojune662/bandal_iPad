import { runtime } from '../_shared/schools/runtime.ts'
const handle = runtime(key => Deno.env.get(key))
Deno.serve(handle)
