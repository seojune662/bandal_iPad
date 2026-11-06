import { runtime } from '../_shared/store/runtime.ts'
const store = runtime(key => Deno.env.get(key))
Deno.serve(store.notifications)
