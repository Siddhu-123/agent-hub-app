import Foundation

public enum OpenCodePlugin {
    public static func template(ctlPath: String, livePath: String) -> String {
        func json(_ value: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        return #"""
import { spawn } from "node:child_process"
import { existsSync, readFileSync, unlinkSync } from "node:fs"
import { join } from "node:path"

const ROOT = \#(json(livePath))
const BRIDGE = \#(json(ctlPath))

function bridge(event, payload) {
  return new Promise((resolve) => {
    if (!existsSync(BRIDGE)) return resolve(null)
    let out = ""
    const child = spawn(BRIDGE, ["hook", "opencode", event], { stdio: ["pipe", "pipe", "ignore"] })
    child.stdout.on("data", (d) => (out += d))
    child.on("error", () => resolve(null))
    child.on("close", () => {
      try { resolve(out ? JSON.parse(out) : null) } catch { resolve(null) }
    })
    child.stdin.end(JSON.stringify(payload))
  })
}

// Serialise bridge calls so a slow "busy" can never land after the "idle" that followed it.
let chain = Promise.resolve(null)
function queue(event, payload) {
  chain = chain.then(() => bridge(event, payload), () => bridge(event, payload))
  return chain
}

function detailOf(p) {
  const patterns = p.patterns || (Array.isArray(p.pattern) ? p.pattern : p.pattern ? [p.pattern] : [])
  const meta = p.metadata || {}
  return meta.command || meta.filepath || meta.filePath || patterns.join(" ") || p.title || ""
}

export const AgentHub = async ({ directory, serverUrl }) => {
  const watching = new Map()

  async function reply(permissionID, sessionID, decision) {
    const reply = decision === "deny" ? "reject" : decision === "always" ? "always" : "once"
    const base = serverUrl ? String(serverUrl) : "http://127.0.0.1:4096"
    const q = `?directory=${encodeURIComponent(directory || "")}`
    const tries = [
      [`/permission/${permissionID}/reply${q}`, { reply }],
      [`/session/${sessionID}/permissions/${permissionID}${q}`, { response: reply }],
    ]
    for (const [path, body] of tries) {
      try {
        const res = await fetch(new URL(path, base), { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) })
        if (res.ok) return true
      } catch {}
    }
    return false
  }

  function watchResponse(requestId, permissionID, sessionID) {
    const file = join(ROOT, "responses", `${requestId}.json`)
    const started = Date.now()
    const timer = setInterval(async () => {
      if (!existsSync(join(ROOT, "requests", `${requestId}.json`)) || Date.now() - started > 30 * 60 * 1000) {
        clearInterval(timer); watching.delete(permissionID); return
      }
      if (!existsSync(file)) return
      let decision = null
      try { decision = JSON.parse(readFileSync(file, "utf8")).decision } catch {}
      try { unlinkSync(file) } catch {}
      // "app" just means the user went to OpenCode; keep watching so a later Allow still works.
      if (decision !== "allow" && decision !== "always" && decision !== "deny") return
      clearInterval(timer); watching.delete(permissionID)
      await reply(permissionID, sessionID, decision)
      try { unlinkSync(join(ROOT, "requests", `${requestId}.json`)) } catch {}
    }, 200)
    watching.set(permissionID, timer)
  }

  return {
    event: async ({ event }) => {
      const t = event.type
      const p = event.properties || event.data || {}
      if (t === "session.status") {
        const s = p.status?.type
        if (s === "busy") queue("busy", { sessionID: p.sessionID, directory })
        else if (s === "retry") queue("busy", { sessionID: p.sessionID, directory, activity: `Retrying: ${p.status.message || ""}` })
      } else if (t === "session.idle") {
        await queue("idle", { sessionID: p.sessionID, directory })
      } else if (t === "session.error") {
        await queue("error", { sessionID: p.sessionID, directory, message: p.error?.data?.message || p.error?.name || "Error" })
      } else if (t === "session.updated" && p.info?.title) {
        queue("title", { sessionID: p.info.id, title: p.info.title })
      } else if (t === "permission.asked" || t === "permission.updated") {
        const id = p.id
        if (!id || watching.has(id)) return
        const res = await queue("permission", {
          id, sessionID: p.sessionID, directory,
          permission: p.permission || p.type || "continue", detail: detailOf(p),
        })
        if (res?.requestId) watchResponse(res.requestId, id, p.sessionID)
      } else if (t === "permission.replied") {
        const id = p.requestID || p.permissionID
        const timer = watching.get(id)
        if (timer) { clearInterval(timer); watching.delete(id) }
        await queue("permission-replied", { id, sessionID: p.sessionID })
      } else if (t === "question.asked") {
        const first = (p.questions && p.questions[0]) || {}
        const q = first.question || first.header || "OpenCode has a question"
        const choices = (first.options || []).map((o) => (typeof o === "string" ? o : o && o.label)).filter(Boolean)
        await queue("question", { sessionID: p.sessionID, directory, detail: q, header: first.header || "", choices })
      }
    },
    "tool.execute.before": async (input, output) => {
      queue("tool", { sessionID: input.sessionID, directory, tool: input.tool, args: output?.args })
    },
  }
}
"""#
    }
}
