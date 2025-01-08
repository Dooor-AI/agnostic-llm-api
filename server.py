from flask import Flask, request, jsonify
import logging
import time
from functools import wraps

app = Flask(__name__)

user_credits = {"user1": 100, "user2": 200}  # example
usage_metrics = {"requests": 0, "errors": 0, "models_loaded": []}
logs = []

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(message)s')
log_handler = logging.StreamHandler()
app.logger.addHandler(log_handler)

def log_request(func):
    """Decorator to log API requests."""
    @wraps(func)
    def wrapper(*args, **kwargs):
        user = request.headers.get("X-User", "anonymous")
        log_entry = {
            "timestamp": time.time(),
            "endpoint": request.path,
            "user": user,
            "method": request.method,
        }
        logs.append(log_entry)
        usage_metrics["requests"] += 1
        return func(*args, **kwargs)

    return wrapper

def rate_limit(func):
    """Decorator to enforce API rate limiting based on user credits."""
    @wraps(func)
    def wrapper(*args, **kwargs):
        user = request.headers.get("X-User")
        if not user or user not in user_credits:
            return jsonify({"error": "Unauthorized or user not found"}), 401

        if user_credits[user] <= 0:
            return jsonify({"error": "Insufficient credits"}), 403

        user_credits[user] -= 1
        return func(*args, **kwargs)

    return wrapper

def error_handler(func):
    """Decorator to handle errors and log them."""
    @wraps(func)
    def wrapper(*args, **kwargs):
        try:
            return func(*args, **kwargs)
        except Exception as e:
            usage_metrics["errors"] += 1
            app.logger.error(f"Error in {func.__name__}: {str(e)}")
            return jsonify({"error": "An unexpected error occurred."}), 500

    return wrapper

@app.route("/api/metrics", methods=["GET"])
@log_request
@error_handler
def get_metrics():
    """Return usage metrics."""
    return jsonify(usage_metrics)

@app.route("/api/logs", methods=["GET"])
@log_request
@rate_limit
@error_handler
def get_logs():
    """Return application logs."""
    return jsonify(logs[-100:])

@app.route("/api/models", methods=["POST", "GET", "DELETE"])
@log_request
@rate_limit
@error_handler
def manage_models():
    """Load, list, or delete models dynamically."""
    if request.method == "POST":
        data = request.json
        model_name = data.get("model_name")

        if not model_name:
            return jsonify({"error": "Model name is required"}), 400

        usage_metrics["models_loaded"].append(model_name)
        return jsonify({"message": f"Model {model_name} loaded successfully"})

    elif request.method == "GET":
        return jsonify({"models": usage_metrics["models_loaded"]})

    elif request.method == "DELETE":
        data = request.json
        model_name = data.get("model_name")

        if model_name not in usage_metrics["models_loaded"]:
            return jsonify({"error": "Model not found"}), 404

        usage_metrics["models_loaded"].remove(model_name)
        return jsonify({"message": f"Model {model_name} deleted successfully"})

@app.route("/api/users/<username>", methods=["GET"])
@log_request
@error_handler
def get_user_credits(username):
    """Return user credits."""
    if username not in user_credits:
        return jsonify({"error": "User not found"}), 404

    return jsonify({"credits": user_credits[username]})

@app.route("/api/users/<username>", methods=["POST"])
@log_request
@error_handler
def add_user_credits(username):
    """Add credits to a user."""
    data = request.json
    credits = data.get("credits")

    if credits is None or not isinstance(credits, int):
        return jsonify({"error": "Invalid credits value"}), 400

    if username not in user_credits:
        user_credits[username] = 0

    user_credits[username] += credits
    return jsonify({"message": f"Credits updated for {username}", "credits": user_credits[username]})

@app.route("/api/users", methods=["GET"])
@log_request
@rate_limit
@error_handler
def list_users():
    """List all users and their credits."""
    return jsonify(user_credits)

@app.route("/api/reset", methods=["POST"])
@log_request
@error_handler
def reset_credits():
    """Reset all user credits to a default value."""
    data = request.json
    default_credits = data.get("default_credits", 100)

    for user in user_credits:
        user_credits[user] = default_credits

    return jsonify({"message": "All user credits reset successfully."})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=True)
