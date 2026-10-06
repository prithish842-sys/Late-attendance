/**
 * The Sankara College crest - navy shield, maroon outline/band, cream star
 * (drawn to match the Flutter CustomPainter sankara_crest.dart). Small and
 * top-left, never centered or hero-sized (DESIGN.md §3.1).
 */
export function Crest({ size = 40 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 40 40" aria-hidden="true" focusable="false">
      <path
        d="M20 0 L34.4 2 C38.4 4.8 40 14 31.2 24.8 C27.2 30.4 23.2 36.8 20 40 C16.8 36.8 12.8 30.4 8.8 24.8 C0 14 1.6 4.8 5.6 2 Z"
        fill="#1B2A4A"
        stroke="#A82B2B"
        strokeWidth="0.8"
      />
      <rect x="10.4" y="12" width="19.2" height="6.4" rx="0.4" fill="#A82B2B" />
      <path
        d="M20 10.4 L21.53 14.7 L26.09 14.82 L22.47 17.6 L23.76 21.98 L20 19.4 L16.24 21.98 L17.53 17.6 L13.91 14.82 L18.47 14.7 Z"
        fill="#FAF8F5"
      />
    </svg>
  );
}