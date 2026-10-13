interface ProgressRingProps {
  progress: number
  label: string
  compact?: boolean
}

export function clampProgress(progress: number): number {
  if (!Number.isFinite(progress)) return 0
  return Math.min(100, Math.max(0, Math.round(progress)))
}

export function ProgressRing({
  progress,
  label,
  compact = false
}: ProgressRingProps): JSX.Element {
  const value = clampProgress(progress)
  return (
    <svg
      className={`help-progress-ring${compact ? ' help-progress-ring--compact' : ''}`}
      viewBox="0 0 36 36"
      role="img"
      aria-label={`${label} ${value}%`}
    >
      <circle className="help-progress-ring__track" cx="18" cy="18" r="15" />
      <circle
        className="help-progress-ring__value"
        cx="18"
        cy="18"
        r="15"
        pathLength="100"
        strokeDasharray="100"
        strokeDashoffset={100 - value}
      />
      {!compact && (
        <text className="help-progress-ring__text" x="18" y="18">
          {value}%
        </text>
      )}
    </svg>
  )
}
