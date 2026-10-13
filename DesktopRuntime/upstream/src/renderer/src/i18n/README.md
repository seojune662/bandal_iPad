# Renderer i18n

## Adding UI copy

1. Add a flat, dot-separated key to `messages/ko-KR.ts`. Use the UI location as
   the prefix, for example `settings.general.language.label`.
2. Add the same key to `messages/en-US.ts`. Its `Record<keyof typeof koKR,
   string>` type makes missing or extra English keys a compile error.
3. Read the message in a component with `const t = useT()` and `t(key)`. Simple
   placeholders use `{name}` and are passed as `t(key, { name })`.

Keep keys about meaning and location, not the Korean wording. Use `Intl` at the
call site for dates; numeric interpolation is locale-formatted automatically.

## Migration still to do

The remaining renderer feature folders are `assistant`, `board`, `browser`,
`chat`, `courses`, `group`, `materials`, `notes`, `onboarding`, `pdf`,
`university`, `updates`, and `workspace`, plus the app shell and shared
renderer components.

Only `features/settings` was migrated in this change. Several workers are
editing the other feature folders concurrently, so migrating everything at
once would create avoidable merge conflicts. Those folders should move to this
foundation in follow-up, owner-scoped changes.
