export async function runPreflight() {
  const res = await fetch("http://127.0.0.1:17890/handshake", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ request: "HELLO_BRIDGE" })
  })

  if (!res.ok) throw new Error("Local Bridge not found")

  const data = await res.json()

  const cap = await fetch("http://127.0.0.1:17890/capabilities")
  const caps = await cap.json()

  if (!caps.hardware.rt809f.connected) {
    throw new Error("RT809F not connected")
  }

  return {
    session_id: data.session_id,
    bridge_version: data.bridge_version
  }
}
