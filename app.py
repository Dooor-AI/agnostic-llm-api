from flask import Flask, request, Response, stream_with_context, jsonify
import requests
import os
import logging
# import whisper
import tempfile
import torch
# import whisperx
import gc

app = Flask(__name__)

OLLAMA_URL = "http://localhost:11434"
API_KEY = os.environ.get('API_KEY')
HF_TOKEN = os.environ.get('HF_TOKEN')  # Add this line in setup.sh

if not API_KEY:
    raise ValueError("API_KEY environment variable not set")

if not HF_TOKEN:
    raise ValueError("HF_TOKEN environment variable not set")

logging.basicConfig(level=logging.INFO)

# Leave this list empty if you want to allow all IPs
ALLOWED_IPS = [
    # "34.82.208.207",
    # "::1",
]

def validate_ip(ip):
    return len(ALLOWED_IPS) == 0 or ip in ALLOWED_IPS

def validate_api_key(auth_header):
    return auth_header == f"Bearer {API_KEY}"

@app.route('/<path:path>', methods=['GET', 'POST', 'PUT', 'DELETE'])
def proxy(path):
    ip = request.headers.get('X-Forwarded-For', request.remote_addr)
    logging.info(f"New request received - Server called from IP: {ip}")
    
    if not validate_ip(ip):
        logging.warning(f"Invalid IP: {ip}")
        return "Unauthorized", 401
    
    if not validate_api_key(request.headers.get('Authorization')):
        logging.warning(f"Invalid API key from IP: {ip}")
        return "Unauthorized", 401

    logging.info(f"Path: {path}")

    url = f"{OLLAMA_URL}/{path}"
    headers = {key: value for (key, value) in request.headers if key != 'Host'}
    
    logging.info(f"Forwarding request to: {url}")
    
    resp = requests.request(
        method=request.method,
        url=url,
        headers=headers,
        data=request.get_data(),
        cookies=request.cookies,
        stream=True
    )

    logging.info(f"Ollama response status: {resp.status_code}")

    def generate():
        for chunk in resp.iter_content(chunk_size=1024):
            yield chunk

    return Response(stream_with_context(generate()), 
                    content_type=resp.headers.get('Content-Type'),
                    status=resp.status_code)

# Uncomment and adapt the following routes if needed:
# @app.route('/transcribe', methods=['POST'])
# def transcribe_audio():
#     # Handle audio transcription requests
#     # Detailed transcription logic
#     pass

# @app.route('/transcribe_diarize', methods=['POST'])
# def transcribe_diarize_audio():
#     # Handle audio transcription and diarization requests
#     # Detailed diarization logic
#     pass

app.config['MAX_CONTENT_LENGTH'] = 10 * 1024 * 1024  # Limit file size to 10 MB

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=True)
