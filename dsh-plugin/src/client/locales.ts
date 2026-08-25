// dsh-emacs-bridge — `dsh-emacs-bridge` locale dictionaries. The Simplified
// Chinese dictionary is the key-set source of truth; English is checked
// complete against it (bilingual balance is enforced at registration).
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

/** Simplified Chinese dictionary (the key-set source of truth). */
export const zh = {
  'sendToEmacs': '发送到 Emacs',
  'sentToEmacs': '已发送到 Emacs',
} satisfies Record<string, string>

/** The dsh-emacs-bridge namespace key union. */
export type DshBridgeKey = keyof typeof zh

declare module '@deepseek-ai/dsh-client-ui-slots' {
  interface LocaleNamespaceMap {
    /** The dsh-emacs bridge "Send to Emacs" action copy. */
    'dsh-emacs-bridge': DshBridgeKey
  }
}

/** English dictionary, checked complete against the zh key set. */
export const en = {
  'sendToEmacs': 'Send to Emacs',
  'sentToEmacs': 'Sent to Emacs',
} satisfies Record<DshBridgeKey, string>
