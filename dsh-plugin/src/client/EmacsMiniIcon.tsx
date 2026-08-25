// dsh-emacs-bridge — "Emacs" icon for the Send-to-Emacs action. Extracted from
// the GNU Emacs logo (emacs-mini-icon.svg, GPL; see the FSF copyright there) and
// rendered as a single-color @currentColor 16px glyph so it matches the row's
// other icon actions. Font/tint and gradients from the source SVG are dropped:
// they do not survive a 512->16px downscale and would need unique ids per
// instance.
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

/** Emacs mini icon: the GNU Emacs mark (circle + E) at @currentColor. */
export function EmacsMiniIcon({ size = 16, className }: { size?: number; className?: string }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0.171 0.201 512 512"
      className={className}
      aria-hidden="true"
    >
      <path
        d="m 488.23812,256.89456 c 0,130.06121 -104.3692,235.49665 -233.1151,235.49665 -128.7459,0 -233.115201,-105.43544 -233.115201,-235.49665 0,-130.06123 104.369301,-235.49666 233.115201,-235.49666 128.7459,0 233.1151,105.43543 233.1151,235.49666 z"
        fill="none"
        stroke="currentColor"
        strokeWidth={24.19}
      />
      <path
        d="m 165.99428,444.05949 c 0,0 22.27253,1.5756 50.92514,-0.94963 11.60359,-1.02265 55.65926,-5.34998 88.5969,-12.57342 0,0 40.15894,-8.59452 61.64351,-16.51198 22.48016,-8.2844 34.71304,-15.31554 40.21919,-25.27845 -0.24011,-2.04132 1.69528,-9.28023 -8.67159,-13.62844 -26.50419,-11.1168 -57.24273,-9.10601 -118.0667,-10.39559 -67.45139,-2.3176 -89.8898,-13.60794 -101.84261,-22.70119 -11.46197,-9.22472 -5.69832,-34.74568 43.41352,-57.22578 24.73906,-11.97095 121.71892,-34.06238 121.71892,-34.06238 -32.66108,-16.14402 -93.56369,-44.52467 -106.08285,-50.65324 -10.98003,-5.37502 -28.5514,-13.46828 -32.36024,-23.26006 -4.31843,-9.40041 10.19864,-17.49809 18.30774,-19.81702 26.11613,-7.53309 62.98414,-12.21514 96.53832,-12.74079 16.86613,-0.26422 19.6038,-1.34938 19.6038,-1.34938 23.27205,-3.86038 38.59217,-19.78248 32.20915,-44.998395 -5.73024,-25.73887 -35.95209,-40.862761 -64.67174,-35.627033 -27.04523,4.930525 -92.2313,23.865317 -92.2313,23.865317 80.5748,-0.697373 94.06085,0.647441 100.08392,9.068516 3.557,4.973245 -1.61629,11.792345 -23.10527,15.301955 -23.3947,3.82087 -72.02586,8.42222 -72.02586,8.42222 -46.65275,2.77062 -79.51489,2.95606 -89.37107,23.82364 -6.4391,13.63304 6.86664,25.68565 12.69856,33.23001 24.64461,27.40727 60.24218,42.18876 83.15574,53.07394 8.62138,4.09561 33.91752,11.83002 33.91752,11.83002 -74.33564,-4.08852 -127.95862,18.73731 -159.41346,45.01809 -35.57647,32.90651 -19.838507,72.13005 53.04785,96.28106 43.04962,14.26453 64.39947,20.97314 128.61444,15.19061 37.8233,-2.03868 43.78577,-0.82546 44.16288,2.27811 0.5309,4.36956 -42.01083,15.22371 -53.62513,18.57381 -29.54697,8.52272 -107.00156,25.73202 -107.38928,25.81548 z"
        fill="currentColor"
        stroke="currentColor"
        strokeWidth={9.11}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}
