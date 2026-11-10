// Prints the seed block of supabase/migrations/202611100002_schools.sql from the school list
// bundled with the app. To regenerate (only while that migration is unapplied; afterwards the
// output belongs in a new migration):
//   deno run --allow-read backend/scripts/seed-schools.ts
// and paste the output between the `-- seed:begin` and `-- seed:end` lines.
interface Service { id: string; kind: string; label: string; url: string; verification: string }
interface University { id: string; nameKo: string; nameEn: string; aliases: string[]; domain: string; services: Service[] }

const source = new URL('../../App/Resources/DesktopNative/universities.json', import.meta.url)
const { universities } = JSON.parse(await Deno.readTextFile(source)) as { universities: University[] }

const KINDS = new Set(['home', 'portal', 'lms', 'library', 'calendar', 'mail', 'registration', 'other'])
const text = (value: string) => `'${value.replaceAll("'", "''")}'`
function kind(value: string): string {
  const mapped = value === 'homepage' ? 'home' : value
  if (!KINDS.has(mapped)) throw new Error(`unknown service kind: ${value}`)
  return mapped
}

const schools = universities.map(u =>
  `  (${text(u.id)}, ${text(u.nameKo)}, ${text(u.nameEn)}, array[${u.aliases.map(text).join(', ')}]::text[], 'KR', ${text(u.domain)}, true, 'bundled')`)
// A link is verified only when the bundled list says so ("partial" and "unverified" are not).
const links = universities.flatMap(u => u.services.map((s, order) =>
  `  (${text(s.id)}, ${text(u.id)}, ${text(kind(s.kind))}, ${text(s.label)}, ${text(s.url)}, ${s.verification === 'verified'}, ${order})`))

console.log(`insert into public.schools(id, name, name_en, aliases, country, domain, verified, source) values\n${schools.join(',\n')};`)
console.log(`insert into public.school_links(id, school_id, kind, title, url, verified, "order") values\n${links.join(',\n')};`)
