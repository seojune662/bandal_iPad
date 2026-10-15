import { fileURLToPath } from 'node:url'
import { adaptSettingsChatSource } from './settingsChatPlugin.mjs'

const styles = fileURLToPath(new URL('./styles.css', import.meta.url))

/** Import last so the iPad presentation layer follows all original feature CSS. */
export function adaptIpadUISource(source, id) {
  const adapted = adaptSettingsChatSource(source, id)
  if (!id.endsWith('/src/renderer/src/main.tsx')) return adapted
  const anchor = "import './styles/base.css'"
  if (source.split(anchor).length !== 2) throw new Error('iPad UI entry point anchor changed')
  return { code: source.replace(anchor, `${anchor}\nimport ${JSON.stringify(styles)}`), map: null }
}

export default function ipadUIPlugin() {
  return { name: 'bandal-ipad-ui', enforce: 'pre', transform: adaptIpadUISource }
}
