/**
 * The nickname contract — shared so the renderer's inline validation and
 * main's pre-flight check cannot drift apart.
 *
 * The shape mirrors the `nickname_shape` CHECK constraint in
 * `supabase/migrations/0002` exactly (docs/phase2-community.md §2.1). All three
 * layers say the same thing on purpose: the DB is the authority, main refuses
 * before spending a round trip, and the renderer can disable the button without
 * asking anyone.
 *
 * Nicknames are GLOBALLY UNIQUE (no `#1234` discriminator) so that "닉네임으로
 * 초대" stays one field and one step — uniqueness is enforced by the DB index,
 * never here.
 */

export const NICKNAME_MIN_LENGTH = 2
export const NICKNAME_MAX_LENGTH = 16

/** 한글·영문·숫자·밑줄 2~16자. */
export const NICKNAME_SHAPE =
  /^[가-힣a-zA-Z0-9_]{2,16}$/

export const NICKNAME_RULE_TEXT =
  '닉네임은 한글·영문·숫자·밑줄 2~16자여야 해요.'

export function isValidNickname(value: string): boolean {
  return NICKNAME_SHAPE.test(value)
}

/**
 * A freshly-created profile carries the trigger-assigned `user_<8hex>` handle.
 * That placeholder — not a null column — is the signal that the student has
 * not chosen a nickname yet (`handle_new_user`, migration 0002).
 */
const PLACEHOLDER_NICKNAME = /^user_[0-9a-f]{8}$/

export function isPlaceholderNickname(value: string): boolean {
  return PLACEHOLDER_NICKNAME.test(value)
}
