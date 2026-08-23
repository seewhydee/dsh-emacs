import { installModelSelection } from "@deepseek-ai/dsh-agent";
import { createUserMessage } from "@deepseek-ai/dsh-llm";
import { SessionId } from "@deepseek-ai/dsh-session";
//#region src/index.ts
const name = "dsh-bridge";
const inject = ["agents", "webServer"];
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
function apply(ctx, config = {}) {
	const webServer = ctx.get("webServer");
	const sessionId = SessionId(config.sessionId ?? "dsh-emacs");
	const cwd = config.cwd ?? process.cwd();
	const ownedAgents = /* @__PURE__ */ new Set();
	/** Compose a fresh agent exactly the way the Web gateway does. */
	async function createAgent() {
		const defaultModel = ctx.get("agentDefaultModel");
		if (defaultModel === void 0) throw new Error("dsh-bridge: ctx.agentDefaultModel is unavailable");
		const selection = defaultModel.currentSelection();
		const presets = ctx.get("agentPresets");
		const installSelection = (agentCtx) => {
			installModelSelection(agentCtx, {
				current: {
					provider: selection.provider,
					model: selection.model
				},
				assembled: void 0
			});
		};
		let agentPreset;
		let setup;
		if (presets === void 0) setup = async (agentCtx) => {
			installSelection(agentCtx);
		};
		else {
			const resolvedId = (await presets.resolve(config.presetId)).id;
			agentPreset = resolvedId;
			setup = async (agentCtx) => {
				installSelection(agentCtx);
				await presets.mount(agentCtx, resolvedId);
			};
		}
		const handle = await ctx.agents.create({
			sessionId,
			agentOptions: {
				provider: selection.provider,
				model: selection.model
			},
			meta: {
				cwd,
				...agentPreset === void 0 ? {} : { agentPreset }
			},
			setup
		});
		ownedAgents.add(handle);
		return handle;
	}
	/** In-flight creation, so concurrent sends share one agent. */
	let creating;
	/** The live agent for `sessionId`, creating it on first use. */
	async function ensureAgent() {
		const live = ctx.agents.get(sessionId);
		if (live !== void 0) return live;
		creating ??= createAgent().finally(() => {
			creating = void 0;
		});
		return (await creating).agent;
	}
	ctx.effect(() => async () => {
		const handles = [...ownedAgents];
		ownedAgents.clear();
		await Promise.all(handles.map((handle) => handle.dispose()));
	});
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
					(await ensureAgent()).followup(createUserMessage({
						content: [{
							type: "text",
							text
						}],
						source: { kind: "user" }
					}));
					sendJson(res, 200, {
						ok: true,
						sessionId: String(sessionId)
					});
				} catch (error) {
					sendJson(res, 500, { error: error instanceof Error ? error.message : String(error) });
				}
				return;
			}
			if (req.method === "GET" && pathname === "/dsh-bridge/output") {
				const agent = ctx.agents.get(sessionId);
				if (agent === void 0) {
					sendJson(res, 404, {
						error: "no live session",
						sessionId: String(sessionId)
					});
					return;
				}
				sendJson(res, 200, {
					sessionId: String(sessionId),
					text: latestAssistantText(agent)
				});
				return;
			}
			sendJson(res, 404, { error: "not found" });
		}
	}));
}
//#endregion
export { apply, inject, name };
