from flask import Flask, request, jsonify
from rt809f_driver import RT809F
from security import verify_session, generate_nonce
import uuid, time

app = Flask(__name__)
bridge_id = "TD-LB-9F23A"
sessions = {}

@app.route("/handshake", methods=["POST"])
def handshake():
    data = request.json
    session_id = str(uuid.uuid4())

    sessions[session_id] = {
        "created": time.time(),
        "locked": False
    }

    return jsonify({
        "bridge_id": bridge_id,
        "bridge_version": "1.0.0",
        "session_id": session_id,
        "bridge_nonce": generate_nonce(),
        "hardware_supported": ["RT809F"],
        "status": "READY"
    })

@app.route("/capabilities", methods=["GET"])
def capabilities():
    rt = RT809F.detect()
    return jsonify({
        "hardware": {
            "rt809f": {
                "connected": rt,
                "modes": ["ISP", "I2C"] if rt else []
            }
        },
        "features": {
            "read": True,
            "write": True,
            "dry_run": True,
            "crc_verify": True
        }
    })

@app.route("/execute", methods=["POST"])
def execute():
    data = request.json
    verify_session(data.get("session_id"), sessions)

    cmd = data.get("command")
    mode = data.get("mode", "DRY_RUN")

    if cmd == "READ_REGISTER":
        value = RT809F.read(
            address=data["address"],
            length=data["length"],
            simulate=(mode == "DRY_RUN")
        )
        return jsonify({"status": "OK", "value": value})

    if cmd == "WRITE_REGISTER":
        if data.get("confirm_token") != "I_KNOW_WHAT_I_AM_DOING":
            return jsonify({"error": "CONFIRMATION_REQUIRED"}), 403

        RT809F.write(
            address=data["address"],
            value=data["value"]
        )
        return jsonify({"status": "SUCCESS"})

    return jsonify({"error": "UNKNOWN_COMMAND"}), 400

app.run(port=17890)
