import { runtime } from '../_shared/referral/runtime.ts'
const handle = runtime(key => Deno.env.get(key))
Deno.serve(handle)
