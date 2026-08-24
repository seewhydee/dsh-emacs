// dsh-emacs-bridge — DSH client plugin (browser half). Cordis plugin id comes
// from the bundle row; this entry only declares the body. Phase 3 spike: prove
// the out-of-tree client artifact loads and activates, nothing more.
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

import type { ClientContext } from '@deepseek-ai/dsh-client-runtime/client'

export const inject = []

export function apply(_ctx: ClientContext): void {
  // eslint-disable-next-line no-console
  console.log('[dsh-bridge] client up')
}
