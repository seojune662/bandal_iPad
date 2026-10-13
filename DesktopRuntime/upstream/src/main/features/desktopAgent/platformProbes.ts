const PROBE_TIMEOUT_MS = 3_000

export interface FrontmostApp {
  appName: string
  windowTitle: string | null
  pid: number | null
}

type ProbeExec = (cmd: string, args: string[]) => Promise<string>

function integerOrNull(value: unknown): number | null {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0
    ? value
    : null
}

/** Parses the `lsappinfo info -only name,pid` record. */
export function parseLsappinfo(
  output: string
): { appName: string; pid: number | null } | null {
  const name = output.match(/^\s*"name"\s*=\s*"([^"]+)"\s*$/imu)?.[1]
  if (name === undefined || name.trim() === '') return null

  const rawPid = output.match(/^\s*"pid"\s*=\s*(-?\d+)\s*$/imu)?.[1]
  const parsedPid = rawPid === undefined ? Number.NaN : Number(rawPid)
  return {
    appName: name,
    pid: Number.isSafeInteger(parsedPid) && parsedPid >= 0 ? parsedPid : null
  }
}

export function parseForegroundWindowJson(output: string): FrontmostApp | null {
  try {
    const parsed: unknown = JSON.parse(output.trim())
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      return null
    }

    const row = parsed as Record<string, unknown>
    if (typeof row['appName'] !== 'string' || row['appName'].trim() === '') {
      return null
    }
    if (
      row['windowTitle'] !== undefined &&
      row['windowTitle'] !== null &&
      typeof row['windowTitle'] !== 'string'
    ) {
      return null
    }

    return {
      appName: row['appName'],
      windowTitle:
        typeof row['windowTitle'] === 'string' && row['windowTitle'] !== ''
          ? row['windowTitle']
          : null,
      pid: integerOrNull(row['pid'])
    }
  } catch {
    return null
  }
}

function foregroundAsn(output: string): string | null {
  return output.match(/\b(ASN:0x[0-9a-f]+-0x[0-9a-f]+:)/iu)?.[1] ?? null
}

function execWithTimeout(
  exec: ProbeExec,
  cmd: string,
  args: string[]
): Promise<string> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`desktop probe timed out: ${cmd}`)),
      PROBE_TIMEOUT_MS
    )
    timer.unref()

    void exec(cmd, args).then(
      (output) => {
        clearTimeout(timer)
        resolve(output)
      },
      (error: unknown) => {
        clearTimeout(timer)
        reject(error)
      }
    )
  })
}

export async function frontmostMac(exec: ProbeExec): Promise<FrontmostApp | null> {
  try {
    const front = await execWithTimeout(exec, 'lsappinfo', ['front'])
    const asn = foregroundAsn(front)
    if (asn === null) return null

    const info = await execWithTimeout(exec, 'lsappinfo', [
      'info',
      '-only',
      'name,pid',
      asn
    ])
    const parsed = parseLsappinfo(info)
    return parsed === null ? null : { ...parsed, windowTitle: null }
  } catch {
    return null
  }
}

const FOREGROUND_WINDOW_SCRIPT = String.raw`
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class BandalForegroundWindow {
  [DllImport("user32.dll")]
  public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetWindowTextW(IntPtr handle, StringBuilder text, int count);
  [DllImport("user32.dll")]
  public static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
}
"@
$handle = [BandalForegroundWindow]::GetForegroundWindow()
if ($handle -eq [IntPtr]::Zero) { return }
$text = New-Object System.Text.StringBuilder 32768
[void][BandalForegroundWindow]::GetWindowTextW($handle, $text, $text.Capacity)
[uint32]$processId = 0
[void][BandalForegroundWindow]::GetWindowThreadProcessId($handle, [ref]$processId)
$process = [System.Diagnostics.Process]::GetProcessById([int]$processId)
$title = $text.ToString()
if ([string]::IsNullOrWhiteSpace($title)) { $title = $null }
[PSCustomObject]@{
  appName = $process.ProcessName
  windowTitle = $title
  pid = [int]$processId
} | ConvertTo-Json -Compress
`.trim()

export async function frontmostWin(exec: ProbeExec): Promise<FrontmostApp | null> {
  try {
    const output = await execWithTimeout(exec, 'powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      FOREGROUND_WINDOW_SCRIPT
    ])
    return parseForegroundWindowJson(output)
  } catch {
    return null
  }
}
