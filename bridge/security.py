import secrets

def generate_nonce():
    return secrets.token_hex(16)

def verify_session(session_id, sessions):
    if session_id not in sessions:
        raise Exception("INVALID_SESSION")
