/**
 * The type of a zustand store built with the immer middleware.
 *
 * Why this exists: `create<T>()(immer(...))` infers a type that mentions
 * immer's `Draft`, and under `"composite": true` TypeScript must be able to
 * *write that type down* in a declaration file. With pnpm, immer physically
 * lives at `node_modules/.pnpm/immer@x.y.z/node_modules/immer`, which is not a
 * name any import statement could produce — so tsc raises TS2742 and asks for
 * an explicit annotation.
 *
 * Naming the type here fixes it once for every store instead of at each call
 * site, and it stops the error from reappearing whenever the pnpm layout
 * shifts (a dependency moving between `dependencies` and `devDependencies` is
 * enough to change it).
 */

import type { Mutate, StoreApi, UseBoundStore } from 'zustand'

export type ImmerStore<T> = UseBoundStore<
  Mutate<StoreApi<T>, [['zustand/immer', never]]>
>
