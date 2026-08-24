import { createUserMessage } from "@deepseek-ai/dsh-llm";
//#region src/index.ts
const name = "dsh-bridge";
const inject = [
	"agents",
	"webServer",
	"sessions"
];
/**
* Latest assistant text in one session's current transcript, newest-first.
* Reads the derived view (not the raw event log) so compaction-replaced
* history stays hidden; assistant turns with no text (tool-call-only steps)
* fall through to the previous one.
*/
function latestAssistantText(agent) {
	const messages = agent.session.deriveMessages();
	for (let i = messages.length - 1; i >= 0; i -= 1) {
		const message = messages[i];
		if (message.role !== "assistant") continue;
		const text = message.content.filter((block) => block.type === "text").map((block) => block.text).join("");
		if (text !== "") return text;
	}
	return "";
}
const MAX_BODY_BYTES = 1024 * 1024;
/** Read a bounded JSON request body; rejects on oversize or malformed input. */
function readJson(req) {
	return new Promise((resolve, reject) => {
		let body = "";
		req.setEncoding("utf8");
		req.on("data", (chunk) => {
			body += chunk;
			if (Buffer.byteLength(body) > MAX_BODY_BYTES) {
				reject(/* @__PURE__ */ new Error("request body too large"));
				req.destroy();
			}
		});
		req.on("end", () => {
			try {
				resolve(body === "" ? void 0 : JSON.parse(body));
			} catch (error) {
				reject(/* @__PURE__ */ new Error(`invalid JSON: ${error instanceof Error ? error.message : String(error)}`));
			}
		});
		req.on("error", reject);
	});
}
/** Write one JSON response. */
function sendJson(res, status, value) {
	const payload = JSON.stringify(value);
	res.writeHead(status, { "content-type": "application/json" });
	res.end(payload);
}
function apply(ctx) {
	const webServer = ctx.get("webServer");
	const sessions = ctx.get("sessions");
	/**
	* The live session to target: the most recently active one. Subagent child
	* sessions are ignored so the bridge follows the top-level conversation the
	* user is driving, never a background child it spawned. The session's agent
	* must be live — there is nothing to drive for a session without one.
	*
	* @returns the target, or undefined when no live agent-backed top-level
	*   session exists.
	*/
	function lastActiveSession() {
		let best;
		let bestTime = -Infinity;
		for (const session of sessions.list()) {
			if (session.header.origin === "subagent") continue;
			const agent = ctx.agents.get(session.id);
			if (agent === void 0) continue;
			const time = session.events.at(-1)?.time ?? session.header.createdAt;
			if (time > bestTime) {
				bestTime = time;
				best = {
					session,
					agent
				};
			}
		}
		return best;
	}
	ctx.effect(() => webServer.register({
		kind: "prefix",
		path: "/dsh-bridge",
		handler: async (req, res) => {
			const pathname = new URL(req.url ?? "/", "http://localhost").pathname;
			if (req.method === "POST" && pathname === "/dsh-bridge/send") {
				try {
					const body = await readJson(req);
					const text = typeof body?.text === "string" ? body.text : "";
					if (text.trim() === "") {
						sendJson(res, 400, { error: "text is required" });
						return;
					}
					const target = lastActiveSession();
					if (target === void 0) {
						sendJson(res, 409, { error: "no active session" });
						return;
					}
					target.agent.followup(createUserMessage({
						content: [{
							type: "text",
							text
						}],
						source: { kind: "user" }
					}));
					sendJson(res, 200, {
						ok: true,
						sessionId: String(target.session.id)
					});
				} catch (error) {
					sendJson(res, 500, { error: error instanceof Error ? error.message : String(error) });
				}
				return;
			}
			if (req.method === "GET" && pathname === "/dsh-bridge/output") {
				const target = lastActiveSession();
				if (target === void 0) {
					sendJson(res, 404, { error: "no active session" });
					return;
				}
				sendJson(res, 200, {
					sessionId: String(target.session.id),
					text: latestAssistantText(target.agent)
				});
				return;
			}
			sendJson(res, 404, { error: "not found" });
		}
	}));
}
//#endregion
export { apply, inject, name };
